/**
 * dsh-sessions.mjs — 读取 dsh 本地会话存储（$DSH_HOME/sessions/）。
 *
 * 存储格式：sessions/<cwd-slug>/session-<uuid>/session.jsonl.zstd
 * 文件由多个独立 zstd 帧顺序拼接而成（每条 JSONL 记录一个帧）。
 * Node 自带的 zstdDecompressSync 只解第一帧，这里按魔数 0x28B52FFD 切帧逐段解压。
 *
 * 供 dsh-acp-bridge（ACP session/list、session/load 回放）与
 * scripts/sync-dsh-sessions.mjs（自动导入镜像 agent）共用。零依赖。
 */
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { zstdDecompressSync } from "node:zlib";

const ZSTD_MAGIC = [0x28, 0xb5, 0x2f, 0xfd];

/** 解压多帧 zstd 文件为字符串（帧间无分隔，内容为 JSONL） */
export function decompressZstdFrames(filePath) {
  const buf = readFileSync(filePath);
  const offsets = [];
  for (let i = 0; i + 4 <= buf.length; i++) {
    if (
      buf[i] === ZSTD_MAGIC[0] &&
      buf[i + 1] === ZSTD_MAGIC[1] &&
      buf[i + 2] === ZSTD_MAGIC[2] &&
      buf[i + 3] === ZSTD_MAGIC[3]
    ) {
      offsets.push(i);
    }
  }
  if (offsets.length === 0) return "";
  let out = "";
  for (let k = 0; k < offsets.length; k++) {
    const end = k + 1 < offsets.length ? offsets[k + 1] : buf.length;
    out += zstdDecompressSync(buf.subarray(offsets[k], end)).toString("utf8");
  }
  return out;
}

/** 解析会话文件为 JSONL 条目数组（坏行跳过） */
export function readSessionEntries(filePath) {
  const text = decompressZstdFrames(filePath);
  const entries = [];
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    try {
      entries.push(JSON.parse(line));
    } catch {
      // 半写入行/损坏帧：跳过
    }
  }
  return entries;
}

/** 从条目里提取给 LLM 的文本块 */
function blocksToText(content, kind) {
  if (!Array.isArray(content)) return "";
  return content
    .filter((b) => b && b.type === kind && typeof b.text === "string")
    .map((b) => b.text)
    .join("");
}

/**
 * 提取会话摘要：{ id, cwd, createdAt, title, userCount, mtime }
 * filePath 指向 session.jsonl.zstd，id 取目录名（session-<uuid>）。
 */
export function summarizeSession(filePath) {
  const entries = readSessionEntries(filePath);
  const header = entries.find((e) => e.type === "session");
  if (!header?.id) return null;
  const titleEntry = entries.find((e) => e.type === "session/title");
  const userCount = entries.reduce((n, e) => n + (e.type === "user/message" ? 1 : 0), 0);
  let mtime = 0;
  try {
    mtime = statSync(filePath).mtimeMs;
  } catch {
    // 忽略
  }
  return {
    id: header.id,
    cwd: header.cwd ?? "",
    createdAt: header.createdAt ?? 0,
    title: titleEntry?.data?.title ?? null,
    userCount,
    mtime,
  };
}

/** 扫描 $DSH_HOME/sessions 下全部会话摘要（按 mtime 倒序） */
export function listDshSessions(dshHome) {
  const root = join(dshHome, "sessions");
  if (!existsSync(root)) return [];
  const out = [];
  for (const slug of readdirSync(root)) {
    const slugDir = join(root, slug);
    let dirs;
    try {
      dirs = readdirSync(slugDir);
    } catch {
      continue;
    }
    for (const dir of dirs) {
      const file = join(slugDir, dir, "session.jsonl.zstd");
      if (!existsSync(file)) continue;
      try {
        const summary = summarizeSession(file);
        if (summary) out.push(summary);
      } catch {
        // 单个会话损坏不影响整体
      }
    }
  }
  out.sort((a, b) => b.mtime - a.mtime);
  return out;
}

// dsh 注入的上下文包装消息（运行时上下文/系统提醒），镜像时过滤
const NOISE_PREFIXES = ["Current runtime context", "<system-reminder>", "<system>"];

/**
 * 提取会话正文为统一消息序列：
 *   [{ role: "user"|"assistant"|"thought", text, messageId? }]
 * user/message → user；assistant/message 里的 text 块 → assistant、reasoning 块 → thought。
 * 跳过工具调用/流式分片/注入上下文等噪音，镜像视图保持干净。
 */
export function extractConversation(filePath) {
  const entries = readSessionEntries(filePath);
  const messages = [];
  for (const e of entries) {
    if (e.type === "user/message") {
      const text = blocksToText(e.data?.content, "text").trim();
      if (text && !NOISE_PREFIXES.some((p) => text.startsWith(p))) {
        messages.push({ role: "user", text, messageId: e.data?.id ?? undefined });
      }
    } else if (e.type === "assistant/message") {
      const content = e.data?.message?.content;
      const thought = blocksToText(content, "reasoning").trim();
      if (thought) messages.push({ role: "thought", text: thought });
      const text = blocksToText(content, "text").trim();
      if (text) messages.push({ role: "assistant", text });
    }
  }
  return messages;
}

/**
 * 增量提取：只取 seq 大于 afterSeq 的会话消息（user/message 与 assistant/message
 * 均有 seq）。返回 { messages, lastSeq }。供镜像会话的实时增量推送用。
 */
export function extractConversationAfter(filePath, afterSeq) {
  const entries = readSessionEntries(filePath);
  const messages = [];
  let lastSeq = afterSeq;
  for (const e of entries) {
    const seq = typeof e.seq === "number" ? e.seq : null;
    if (seq !== null && seq <= afterSeq) continue;
    if (seq !== null) lastSeq = Math.max(lastSeq, seq);
    if (e.type === "user/message") {
      const text = blocksToText(e.data?.content, "text").trim();
      if (text && !NOISE_PREFIXES.some((p) => text.startsWith(p))) {
        messages.push({ role: "user", text, messageId: e.data?.id ?? undefined });
      }
    } else if (e.type === "assistant/message") {
      const content = e.data?.message?.content;
      const thought = blocksToText(content, "reasoning").trim();
      if (thought) messages.push({ role: "thought", text: thought });
      const text = blocksToText(content, "text").trim();
      if (text) messages.push({ role: "assistant", text });
    }
  }
  return { messages, lastSeq };
}

/** 会话文件里当前最大的 seq（回放终点水位线） */
export function maxSeqOf(filePath) {
  let max = 0;
  for (const e of readSessionEntries(filePath)) {
    if (typeof e.seq === "number" && e.seq > max) max = e.seq;
  }
  return max;
}

/** 按 handle（session-<uuid> 目录名）定位会话文件；找不到返回 null */
export function findSessionFile(dshHome, handle) {
  const root = join(dshHome, "sessions");
  if (!existsSync(root)) return null;
  for (const slug of readdirSync(root)) {
    const candidate = join(root, slug, handle, "session.jsonl.zstd");
    if (existsSync(candidate)) return candidate;
  }
  return null;
}
