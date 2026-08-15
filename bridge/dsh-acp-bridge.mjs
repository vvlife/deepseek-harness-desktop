#!/usr/bin/env node
/**
 * dsh-acp-bridge — 把 DeepSeek Harness (dsh) 包装成 ACP agent，供 Paseo 调用。
 * （DeepSeek Harness Desktop 组件）
 *
 * dsh 本身没有 ACP 模式，本桥在 stdio 上讲 ACP（ndjson + JSON-RPC 2.0，
 * 零依赖）：每个 session/prompt 回合 spawn 一次
 *   dsh --profile headless --patch <临时模型 overlay> "<task>"
 * 把 stdout 以 agent_message_chunk 流回客户端。
 *
 * LLM provider 是可选项：启动时读取 $DSH_HOME/paseo-bridge/provider.json
 * （由 scripts/setup-provider.mjs 写入）：
 *   { "provider": "deepseek-official", "keyEnv": "DEEPSEEK_API_KEY",
 *     "defaultModel": "deepseek-v4-flash",
 *     "models": [{ "modelId": "...", "name": "...", "description": "..." }] }
 * 文件缺失/损坏时回落到 DeepSeek 官方默认（deepseek-official + v4-flash/v4-pro）。
 * per-session 选模型通过临时 --patch overlay 覆盖 agent-default-model 实现。
 *
 * 每回合是独立的 dsh headless 运行，回合间不保留对话上下文。
 */
import { spawn } from "node:child_process";
import {
  existsSync,
  readFileSync,
  writeFileSync,
  rmSync,
  mkdirSync,
  appendFileSync,
  readdirSync,
  watchFile,
  unwatchFile,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import {
  listDshSessions,
  findSessionFile,
  extractConversation,
  extractConversationAfter,
  maxSeqOf,
} from "./dsh-sessions.mjs";

const BRIDGE_VERSION = "0.3.0";
const PROTOCOL_VERSION = 1;

const DSH_HOME = process.env.DSH_HOME ?? join(homedir(), ".dsh");
const PROVIDER_CONFIG = join(DSH_HOME, "paseo-bridge", "provider.json");
const SELF_SESSIONS_FILE = join(DSH_HOME, "paseo-bridge", "self-sessions.txt");
const OVERLAY_DIR = join(DSH_HOME, "paseo-bridge", "mirror-overlay");

// dsh 可执行文件：优先常见绝对路径（GUI daemon 的 PATH 可能很窄）
const DSH_BIN =
  process.env.DSH_BIN ??
  ["/opt/homebrew/bin/dsh", "/usr/local/bin/dsh"].find((p) => existsSync(p)) ??
  "dsh";

// DeepSeek 官方内置路由（dsh 自带，无需任何声明）作为兜底
const FALLBACK = {
  provider: "deepseek-official",
  keyEnv: "DEEPSEEK_API_KEY",
  defaultModel: "deepseek-v4-flash",
  models: [
    { modelId: "deepseek-v4-flash", name: "DeepSeek V4 Flash", description: "默认，快" },
    { modelId: "deepseek-v4-pro", name: "DeepSeek V4 Pro", description: "更强，慢" },
  ],
};

function loadProvider() {
  try {
    const raw = JSON.parse(readFileSync(PROVIDER_CONFIG, "utf8"));
    if (
      typeof raw?.provider === "string" &&
      Array.isArray(raw?.models) &&
      raw.models.length > 0 &&
      raw.models.every((m) => typeof m?.modelId === "string")
    ) {
      return {
        provider: raw.provider,
        keyEnv: typeof raw.keyEnv === "string" ? raw.keyEnv : FALLBACK.keyEnv,
        defaultModel:
          typeof raw.defaultModel === "string" &&
          raw.models.some((m) => m.modelId === raw.defaultModel)
            ? raw.defaultModel
            : raw.models[0].modelId,
        models: raw.models,
      };
    }
  } catch {
    // 缺失或损坏：静默回落（Paseo 侧仍可用 DeepSeek 官方默认启动）
  }
  return FALLBACK;
}

const PROVIDER = loadProvider();
const MODELS = PROVIDER.models;
const DEFAULT_MODEL = PROVIDER.defaultModel;

if (process.argv.includes("--version") || process.argv.includes("-v")) {
  process.stdout.write(`dsh-acp-bridge ${BRIDGE_VERSION}\n`);
  process.exit(0);
}

// ---------------------------------------------------------------------------
// ndjson JSON-RPC 2.0 传输层
// ---------------------------------------------------------------------------
let writeChain = Promise.resolve();
function send(message) {
  const line = JSON.stringify(message) + "\n";
  writeChain = writeChain.then(
    () =>
      new Promise((resolve, reject) => {
        process.stdout.write(line, (err) => (err ? reject(err) : resolve()));
      }),
  );
  return writeChain;
}

function respond(id, result) {
  return send({ jsonrpc: "2.0", id, result });
}

function respondError(id, code, message) {
  return send({ jsonrpc: "2.0", id, error: { code, message } });
}

function notify(method, params) {
  return send({ jsonrpc: "2.0", method, params });
}

// ---------------------------------------------------------------------------
// Agent 状态与方法
// ---------------------------------------------------------------------------
const sessions = new Map();

function childEnv() {
  const env = { ...process.env };
  const extra = ["/opt/homebrew/bin", "/usr/local/bin"];
  env.PATH = [...extra, ...(env.PATH ?? "").split(":").filter(Boolean)].join(":");
  return env;
}

/** 把 ACP prompt 内容块拍平成纯文本任务 */
function promptToText(blocks) {
  const parts = [];
  for (const block of blocks ?? []) {
    if (block?.type === "text") {
      parts.push(block.text ?? "");
    } else if (block?.type === "resource_link") {
      parts.push(`[${block.name ?? "link"}](${block.uri ?? ""})`);
    } else if (block?.type === "resource" && block.resource?.text) {
      parts.push(block.resource.text);
    }
  }
  return parts.join("\n").trim();
}

async function sendChunk(sessionId, text) {
  if (!text) return;
  await notify("session/update", {
    sessionId,
    update: {
      sessionUpdate: "agent_message_chunk",
      content: { type: "text", text },
    },
  });
}

const handlers = {
  async initialize(_params) {
    return {
      protocolVersion: PROTOCOL_VERSION,
      agentInfo: {
        name: "deepseek-harness",
        title: "DeepSeek Harness",
        version: BRIDGE_VERSION,
      },
      agentCapabilities: {
        // 支持加载/列出 dsh 本地会话：dsh web（Harness Web）里的对话经此
        // 镜像为 Paseo agent，手机端可见。找不到对应 transcript 的 id
        // （本桥自己 spawn 的 live 会话）回放为空，行为同旧版。
        loadSession: true,
        sessionCapabilities: { list: true },
        promptCapabilities: { image: false, audio: false, embeddedContext: false },
      },
      authMethods: [],
    };
  },

  async authenticate(_params) {
    return {};
  },

  /// 列出可导入的 dsh 本地会话（dsh web 产生的；本桥自建的已排除）
  async "session/list"(_params) {
    const self = readSelfSessions();
    const sessions = listDshSessions(DSH_HOME)
      .filter((s) => s.userCount > 0 && !self.has(s.id))
      .map((s) => ({
        sessionId: s.id,
        cwd: s.cwd || process.cwd(),
        title: s.title ?? undefined,
        updatedAt: new Date(s.mtime || Date.now()).toISOString(),
      }));
    return { sessions, nextCursor: null };
  },

  /// 加载 dsh 会话并回放时间线（含手机端续聊的 overlay 追加），
  /// 之后盯文件变化把新回合实时推给已打开的客户端（手机/桌面同步）
  async "session/load"(params) {
    const handle = params?.sessionId;
    const file = handle ? findSessionFile(DSH_HOME, handle) : null;
    const state = {
      cwd: params?.cwd || process.cwd(),
      modelId: DEFAULT_MODEL,
      child: null,
      mirrored: Boolean(file),
      handle: file ? handle : null,
      lastSeq: 0,
    };
    if (file) {
      // daemon 在 loadSession 前已把会话键设为 handle，回放通知必须带 handle
      sessions.set(handle, state);
      const transcript = extractConversation(file);
      const overlay = readOverlay(handle);
      for (const msg of [...transcript, ...overlay]) {
        await replayMessage(handle, msg);
      }
      state.lastSeq = maxSeqOf(file);
      startTranscriptWatch(handle, file, state);
      return {
        models: { availableModels: MODELS, currentModelId: DEFAULT_MODEL },
      };
    }
    // 无对应 transcript（本桥自建的 live 会话）：空回放，行为同旧版
    const sessionId = newSessionId();
    sessions.set(sessionId, state);
    return {
      models: { availableModels: MODELS, currentModelId: DEFAULT_MODEL },
    };
  },

  async "session/new"(params) {
    const sessionId = newSessionId();
    sessions.set(sessionId, {
      cwd: params?.cwd || process.cwd(),
      modelId: DEFAULT_MODEL,
      child: null,
      mirrored: false,
      handle: null,
    });
    return {
      sessionId,
      models: { availableModels: MODELS, currentModelId: DEFAULT_MODEL },
    };
  },

  async "session/set_model"(params) {
    const session = sessions.get(params?.sessionId);
    if (!session) throw rpcError(-32602, `Session ${params?.sessionId} not found`);
    if (!MODELS.some((m) => m.modelId === params?.modelId)) {
      throw rpcError(-32602, `Unknown model ${params?.modelId}`);
    }
    session.modelId = params.modelId;
    return {};
  },

  async "session/set_mode"(_params) {
    return {};
  },

  async "session/close"(params) {
    const session = sessions.get(params?.sessionId);
    session?.child?.kill("SIGTERM");
    if (session?.watchFile) {
      unwatchFile(session.watchFile);
    }
    sessions.delete(params?.sessionId);
    return {};
  },

  async "session/prompt"(params) {
    const session = sessions.get(params?.sessionId);
    if (!session) throw rpcError(-32602, `Session ${params?.sessionId} not found`);

    let task = promptToText(params?.prompt);
    if (!task) return { stopReason: "end_turn" };

    // 镜像会话（来自 dsh web 的 transcript）：dsh headless 不支持 resume，
    // 把此前对话压缩成上下文前缀，让手机端的追问能接续原对话
    if (session.mirrored && session.handle) {
      const history = readTranscriptMessages(session.handle);
      const overlay = readOverlay(session.handle);
      const context = buildContextPrefix([...history, ...overlay]);
      appendOverlay(session.handle, { role: "user", text: task });
      if (context) task = `${context}\n${task}`;
      session.pendingOverlayReply = "";
    }

    // per-session 选模型：生成临时 patch overlay 覆盖 agent-default-model
    const patchPath = join(tmpdir(), `dsh-acp-${params.sessionId}.yml`);
    writeFileSync(
      patchPath,
      [
        "- id: agent-default-model",
        "  config:",
        `    provider: ${PROVIDER.provider}`,
        `    model: ${session.modelId}`,
        "",
      ].join("\n"),
      { mode: 0o600 },
    );

    try {
      return await runDsh(params.sessionId, session, task, patchPath);
    } finally {
      rmSync(patchPath, { force: true });
      if (session.mirrored && session.handle && session.pendingOverlayReply?.trim()) {
        appendOverlay(session.handle, { role: "assistant", text: session.pendingOverlayReply.trim() });
      }
      session.pendingOverlayReply = undefined;
    }
  },
};

function rpcError(code, message) {
  return Object.assign(new Error(message), { code });
}

// ---------------------------------------------------------------------------
// 镜像会话工具（dsh web 会话 → Paseo 可见）
// ---------------------------------------------------------------------------

function newSessionId() {
  return Array.from(crypto.getRandomValues(new Uint8Array(16)))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function readSelfSessions() {
  try {
    return new Set(
      readFileSync(SELF_SESSIONS_FILE, "utf8").split("\n").map((s) => s.trim()).filter(Boolean),
    );
  } catch {
    return new Set();
  }
}

/** spawn 前后快照会话目录，新增的标记为「本桥自建」，不做镜像（避免重复导入） */
function snapshotSessionDirs() {
  const root = join(DSH_HOME, "sessions");
  const out = new Set();
  try {
    for (const slug of readdirSync(root)) {
      for (const dir of readdirSync(join(root, slug))) out.add(dir);
    }
  } catch {
    // sessions 目录尚不存在
  }
  return out;
}

function markNewSessionsAsSelf(before) {
  const root = join(DSH_HOME, "sessions");
  try {
    mkdirSync(join(DSH_HOME, "paseo-bridge"), { recursive: true });
    for (const slug of readdirSync(root)) {
      for (const dir of readdirSync(join(root, slug))) {
        if (!before.has(dir)) appendFileSync(SELF_SESSIONS_FILE, dir + "\n");
      }
    }
  } catch {
    // 忽略：标记失败只是多一个镜像，不影响主流程
  }
}

function overlayPath(handle) {
  return join(OVERLAY_DIR, `${handle}.jsonl`);
}

function readOverlay(handle) {
  try {
    return readFileSync(overlayPath(handle), "utf8")
      .split("\n")
      .filter((l) => l.trim())
      .map((l) => {
        try {
          return JSON.parse(l);
        } catch {
          return null;
        }
      })
      .filter((m) => m && typeof m.text === "string");
  } catch {
    return [];
  }
}

function appendOverlay(handle, msg) {
  try {
    mkdirSync(OVERLAY_DIR, { recursive: true });
    appendFileSync(overlayPath(handle), JSON.stringify(msg) + "\n");
  } catch {
    // 忽略
  }
}

function readTranscriptMessages(handle) {
  const file = findSessionFile(DSH_HOME, handle);
  return file ? extractConversation(file) : [];
}

/** 把对话历史压缩成有限长的上下文前缀（接续用，非逐字 transcript） */
function buildContextPrefix(messages) {
  const recent = messages.filter((m) => m.role !== "thought").slice(-12);
  if (recent.length === 0) return "";
  const lines = recent.map((m) => {
    const who = m.role === "user" ? "用户" : "助手";
    const text = m.text.length > 2000 ? m.text.slice(0, 2000) + "…" : m.text;
    return `${who}：${text}`;
  });
  return [
    "以下是该会话此前的对话记录（仅供接续上下文）：",
    "<对话记录>",
    ...lines,
    "</对话记录>",
    "",
    "用户的新消息：",
  ].join("\n");
}

/** 回放一条消息为 ACP session/update 通知 */
async function replayMessage(sessionId, msg) {
  const update =
    msg.role === "user"
      ? {
          sessionUpdate: "user_message_chunk",
          content: { type: "text", text: msg.text },
          ...(msg.messageId ? { messageId: msg.messageId } : {}),
        }
      : {
          sessionUpdate: msg.role === "thought" ? "agent_thought_chunk" : "agent_message_chunk",
          content: { type: "text", text: msg.text },
        };
  await notify("session/update", { sessionId, update });
}

/**
 * 镜像会话的实时增量推送：盯 dsh 会话文件，新回合（seq 大于回放水位线）
 * 立刻推给已打开该 agent 的客户端（手机/桌面）。watchFile 轮询 1.5s，
 * 带 800ms 防抖，等 dsh 把一个回合写完整。
 */
function startTranscriptWatch(handle, file, state) {
  state.watchFile = file;
  let timer = null;
  watchFile(file, { interval: 1500 }, () => {
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => {
      timer = null;
      if (!sessions.has(handle)) {
        unwatchFile(file);
        return;
      }
      let delta;
      try {
        delta = extractConversationAfter(file, state.lastSeq);
      } catch {
        return; // 写入中途读失败：下轮再试
      }
      if (delta.lastSeq === state.lastSeq) return;
      state.lastSeq = delta.lastSeq;
      for (const msg of delta.messages) {
        replayMessage(handle, msg).catch(() => {});
      }
    }, 800);
  });
}

function runDsh(sessionId, session, task, patchPath) {
  return new Promise((resolve) => {
    // 记录本桥自建的 dsh 会话，避免被镜像器当成 dsh web 会话重复导入
    const beforeSpawn = snapshotSessionDirs();
    const child = spawn(
      DSH_BIN,
      ["--profile", "headless", "--patch", patchPath, task],
      { cwd: session.cwd, env: childEnv(), stdio: ["ignore", "pipe", "pipe"] },
    );
    session.child = child;

    let started = false;
    let pending = "";
    let stderrText = "";
    let replyText = "";
    const safeChunk = (text) => {
      replyText += text;
      return sendChunk(sessionId, text).catch(() => {});
    };

    child.stdout.on("data", (data) => {
      const s = data.toString();
      if (!started) {
        pending += s;
        const trimmed = pending.replace(/^\s+/, "");
        if (trimmed) {
          started = true;
          void safeChunk(trimmed);
          pending = "";
        }
      } else {
        void safeChunk(s);
      }
    });
    child.stderr.on("data", (data) => {
      stderrText += data.toString();
    });

    child.on("error", (err) => {
      session.child = null;
      void safeChunk(`\n[bridge] 无法启动 dsh: ${err.message}`).finally(() =>
        resolve({ stopReason: "end_turn" }),
      );
    });

    child.on("close", (code, signal) => {
      session.child = null;
      markNewSessionsAsSelf(beforeSpawn);
      if (session.mirrored) session.pendingOverlayReply = replyText;
      void (async () => {
        if (signal === "SIGTERM" || signal === "SIGKILL") {
          resolve({ stopReason: "cancelled" });
          return;
        }
        if (!started && pending.trim()) {
          started = true;
          await safeChunk(pending.trim());
        }
        if (code !== 0) {
          const detail = stderrText.trim();
          await safeChunk(
            `\n[dsh 退出码 ${code}]${detail ? `\n${detail.slice(-2000)}` : ""}`,
          );
        }
        resolve({ stopReason: "end_turn" });
      })();
    });
  });
}

// session/cancel 是通知：杀掉正在跑的 dsh 子进程
const notifiers = {
  "session/cancel"(params) {
    sessions.get(params?.sessionId)?.child?.kill("SIGTERM");
  },
};

// ---------------------------------------------------------------------------
// 入口：逐行读 stdin，分发
// ---------------------------------------------------------------------------
let buffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buffer += chunk;
  for (;;) {
    const nl = buffer.indexOf("\n");
    if (nl === -1) break;
    const line = buffer.slice(0, nl).trim();
    buffer = buffer.slice(nl + 1);
    if (line) void dispatch(line);
  }
});

async function dispatch(line) {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    await respondError(null, -32700, "Parse error");
    return;
  }
  const { id, method, params } = msg;
  if (typeof method !== "string") return;

  if (id === undefined || id === null) {
    notifiers[method]?.(params);
    return;
  }
  const handler = handlers[method];
  if (!handler) {
    await respondError(id, -32601, `Method not found: ${method}`);
    return;
  }
  try {
    await respond(id, (await handler(params)) ?? null);
  } catch (err) {
    await respondError(id, err?.code ?? -32603, err?.message ?? "Internal error");
  }
}
