#!/usr/bin/env node
/**
 * sync-dsh-sessions.mjs — 把 dsh 本地会话（Harness Web / dsh web 里的对话）
 * 自动导入为 Paseo 镜像 agent，让 Paseo 手机端可以看到。
 *
 * 一次性扫描（由 APP 定时调用）：
 *   1. 枚举 $DSH_HOME/sessions 下的会话（跳过空会话与桥自建的会话）
 *   2. 对未导入的会话执行 `paseo agent import --provider deepseek <id> --cwd <cwd>`
 *   3. 已导入/失败状态记录在 $DSH_HOME/paseo-bridge/imported-sessions.json
 *
 * 用法：node sync-dsh-sessions.mjs --paseo-cli <@getpaseo/cli dist/index.js 路径>
 * 环境：DSH_HOME、PASEO_HOME（由 APP 注入）。
 */
import { existsSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { homedir } from "node:os";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { listDshSessions } from "../bridge/dsh-sessions.mjs";

const DSH_HOME = process.env.DSH_HOME ?? join(homedir(), ".dsh");
const BRIDGE_DIR = join(DSH_HOME, "paseo-bridge");
const STATE_FILE = join(BRIDGE_DIR, "imported-sessions.json");
const SELF_FILE = join(BRIDGE_DIR, "self-sessions.txt");

const args = process.argv.slice(2);
const opt = (name) => {
  const i = args.indexOf(name);
  return i !== -1 ? args[i + 1] : undefined;
};
const paseoCli = opt("--paseo-cli");
if (!paseoCli || !existsSync(paseoCli)) {
  console.error("✘ 需要 --paseo-cli 指向 @getpaseo/cli 的 dist/index.js");
  process.exit(1);
}

const RETRY_MS = 10 * 60 * 1000; // 失败 10 分钟后重试
// 太新的会话可能还在写入，默认跳过本轮；自测场景可 --min-age-ms 0
const MIN_AGE_MS = Number(opt("--min-age-ms") ?? 5_000);

function loadState() {
  try {
    return JSON.parse(readFileSync(STATE_FILE, "utf8"));
  } catch {
    return {};
  }
}

function saveState(state) {
  mkdirSync(dirname(STATE_FILE), { recursive: true });
  writeFileSync(STATE_FILE, JSON.stringify(state, null, 2) + "\n");
}

function loadSelfSessions() {
  try {
    return new Set(
      readFileSync(SELF_FILE, "utf8").split("\n").map((s) => s.trim()).filter(Boolean),
    );
  } catch {
    return new Set();
  }
}

function importSession(id, cwd) {
  const res = spawnSync(
    process.execPath,
    [paseoCli, "agent", "import", "--provider", "deepseek", id, "--cwd", cwd || process.cwd()],
    { env: process.env, encoding: "utf8", timeout: 60_000 },
  );
  const out = `${res.stdout ?? ""}${res.stderr ?? ""}`;
  return { ok: res.status === 0, out };
}

const state = loadState();
const self = loadSelfSessions();
const now = Date.now();
let imported = 0;
let skipped = 0;
let failed = 0;

for (const s of listDshSessions(DSH_HOME)) {
  if (s.userCount === 0 || self.has(s.id)) continue;
  const prev = state[s.id];
  if (prev?.ok) continue;
  if (prev?.nextRetryAt && prev.nextRetryAt > now) continue;
  if (now - s.mtime < MIN_AGE_MS) continue; // 还在写

  const { ok, out } = importSession(s.id, s.cwd);
  if (ok) {
    state[s.id] = { ok: true, at: now, title: s.title, cwd: s.cwd };
    imported++;
  } else if (/already imported/i.test(out)) {
    state[s.id] = { ok: true, at: now, title: s.title, cwd: s.cwd, note: "already" };
    skipped++;
  } else {
    state[s.id] = { ok: false, error: out.slice(-300), nextRetryAt: now + RETRY_MS };
    failed++;
  }
}

saveState(state);
console.log(`dsh 会话同步：新导入 ${imported}，已在库 ${skipped}，失败 ${failed}`);
