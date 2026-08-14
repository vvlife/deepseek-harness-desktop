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
import { existsSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";

const BRIDGE_VERSION = "0.2.0";
const PROTOCOL_VERSION = 1;

const DSH_HOME = process.env.DSH_HOME ?? join(homedir(), ".dsh");
const PROVIDER_CONFIG = join(DSH_HOME, "paseo-bridge", "provider.json");

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
        loadSession: false,
        promptCapabilities: { image: false, audio: false, embeddedContext: false },
      },
      authMethods: [],
    };
  },

  async authenticate(_params) {
    return {};
  },

  async "session/new"(params) {
    const sessionId = Array.from(crypto.getRandomValues(new Uint8Array(16)))
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");
    sessions.set(sessionId, {
      cwd: params?.cwd || process.cwd(),
      modelId: DEFAULT_MODEL,
      child: null,
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
    sessions.delete(params?.sessionId);
    return {};
  },

  async "session/prompt"(params) {
    const session = sessions.get(params?.sessionId);
    if (!session) throw rpcError(-32602, `Session ${params?.sessionId} not found`);

    const task = promptToText(params?.prompt);
    if (!task) return { stopReason: "end_turn" };

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
    }
  },
};

function rpcError(code, message) {
  return Object.assign(new Error(message), { code });
}

function runDsh(sessionId, session, task, patchPath) {
  return new Promise((resolve) => {
    const child = spawn(
      DSH_BIN,
      ["--profile", "headless", "--patch", patchPath, task],
      { cwd: session.cwd, env: childEnv(), stdio: ["ignore", "pipe", "pipe"] },
    );
    session.child = child;

    let started = false;
    let pending = "";
    let stderrText = "";
    const safeChunk = (text) => sendChunk(sessionId, text).catch(() => {});

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
