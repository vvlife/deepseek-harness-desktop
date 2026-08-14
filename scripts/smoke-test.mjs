#!/usr/bin/env node
/**
 * smoke-test.mjs — DeepSeek Harness Desktop 安装自检（默认不发起真实 LLM 调用）。
 *
 *   node smoke-test.mjs [--require-paseo] [--bridge <path>] [--e2e]
 *
 * 检查项：
 *   1. ACP 协议握手：spawn 桥，initialize / session/new / session/set_model / session/close
 *   2. provider.json 存在且结构合法
 *   3. Paseo 注册：config.json 含 agents.providers.deepseek 且 command 文件可执行
 *      （--require-paseo 时缺失视为失败，否则跳过并提示）
 *   4. 凭据：.credentials.yaml 存在时为 0600 且含 provider.json 的 keyEnv（只断言存在性）
 *   5. dsh --profile headless --dump-config 退出码 0（dsh 不在 PATH 时跳过）
 *   --e2e：额外真实跑一次 dsh headless（需要有效凭据，可能产生少量 API 费用）
 * 环境：DSH_HOME（默认 ~/.dsh）、PASEO_HOME（默认 ~/.paseo）、DSH_BIN。
 */
import { spawn, spawnSync } from "node:child_process";
import { existsSync, readFileSync, statSync, accessSync, constants, writeFileSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";

const DSH_HOME = process.env.DSH_HOME ?? join(homedir(), ".dsh");
const PASEO_HOME = process.env.PASEO_HOME ?? join(homedir(), ".paseo");
const args = process.argv.slice(2);
const flag = (name) => args.includes(name);
const opt = (name) => {
  const i = args.indexOf(name);
  return i !== -1 ? args[i + 1] : undefined;
};

const BRIDGE = opt("--bridge") ?? join(DSH_HOME, "paseo-bridge", "dsh-acp-bridge.mjs");

let failures = 0;
const pass = (name) => console.log(`✔ ${name}`);
const fail = (name, detail = "") => {
  failures += 1;
  console.log(`✘ ${name}${detail ? ` — ${detail}` : ""}`);
};
const skip = (name, why) => console.log(`- ${name}（跳过：${why}）`);
const check = (name, cond, detail = "") => (cond ? pass(name) : fail(name, detail));

// ---------------------------------------------------------------------------
// 极简 ACP 客户端（ndjson JSON-RPC）
// ---------------------------------------------------------------------------
class AcpClient {
  constructor(child) {
    this.child = child;
    this.nextId = 1;
    this.pending = new Map();
    this.buffer = "";
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      this.buffer += chunk;
      for (;;) {
        const nl = this.buffer.indexOf("\n");
        if (nl === -1) break;
        const line = this.buffer.slice(0, nl).trim();
        this.buffer = this.buffer.slice(nl + 1);
        if (!line) continue;
        let msg;
        try {
          msg = JSON.parse(line);
        } catch {
          continue;
        }
        if (msg.id !== undefined && this.pending.has(msg.id)) {
          const { resolve, timer } = this.pending.get(msg.id);
          clearTimeout(timer);
          this.pending.delete(msg.id);
          resolve(msg);
        }
      }
    });
  }
  request(method, params, timeoutMs = 10_000) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${method} 超时（${timeoutMs / 1000}s）`));
      }, timeoutMs);
      this.pending.set(id, { resolve, timer });
      this.child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params: params ?? {} }) + "\n");
    });
  }
}

async function testBridge() {
  if (!existsSync(BRIDGE)) {
    fail("ACP 桥存在", `${BRIDGE} 不存在（先跑 install.sh）`);
    return;
  }
  const child = spawn(BRIDGE, [], { stdio: ["pipe", "pipe", "pipe"] });
  const client = new AcpClient(child);
  let stderr = "";
  child.stderr.on("data", (d) => (stderr += d.toString()));
  try {
    const init = await client.request("initialize", { protocolVersion: 1, clientCapabilities: {} });
    check(
      "initialize 握手",
      init.result?.protocolVersion === 1 && init.result?.agentInfo?.name === "deepseek-harness",
      JSON.stringify(init).slice(0, 200),
    );

    const created = await client.request("session/new", { cwd: process.cwd(), mcpServers: [] });
    const models = created.result?.models?.availableModels;
    const sessionId = created.result?.sessionId;
    check("session/new 返回会话与非空模型列表", typeof sessionId === "string" && Array.isArray(models) && models.length > 0);
    if (sessionId && Array.isArray(models) && models.length > 0) {
      const target = models.length > 1 ? models[1].modelId : models[0].modelId;
      const switched = await client.request("session/set_model", { sessionId, modelId: target });
      check("session/set_model 切模型", !switched.error, JSON.stringify(switched).slice(0, 200));
      const closed = await client.request("session/close", { sessionId });
      check("session/close", !closed.error, JSON.stringify(closed).slice(0, 200));
    }
  } catch (err) {
    fail("ACP 协议握手", `${err.message}${stderr ? `；stderr: ${stderr.slice(0, 200)}` : ""}`);
  } finally {
    child.kill("SIGTERM");
  }
}

function testProviderJson() {
  const path = join(DSH_HOME, "paseo-bridge", "provider.json");
  if (!existsSync(path)) return skip("provider.json 结构", "未配置过 provider（桥将用 DeepSeek 官方默认）");
  try {
    const raw = JSON.parse(readFileSync(path, "utf8"));
    check(
      "provider.json 结构",
      typeof raw.provider === "string" && Array.isArray(raw.models) && raw.models.length > 0,
    );
    return raw;
  } catch (err) {
    fail("provider.json 结构", err.message);
    return undefined;
  }
}

function testPaseo() {
  const configPath = join(PASEO_HOME, "config.json");
  if (!existsSync(configPath)) {
    return flag("--require-paseo")
      ? fail("Paseo provider 注册", `${configPath} 不存在`)
      : skip("Paseo provider 注册", "Paseo 未安装（--skip-paseo？）");
  }
  try {
    const entry = JSON.parse(readFileSync(configPath, "utf8"))?.agents?.providers?.deepseek;
    check("Paseo provider 注册", entry?.extends === "acp" && Array.isArray(entry?.command));
    if (Array.isArray(entry?.command)) {
      let executable = false;
      try {
        accessSync(entry.command[0], constants.X_OK);
        executable = true;
      } catch {}
      check("桥文件可执行", executable, entry.command[0]);
    }
  } catch (err) {
    fail("Paseo provider 注册", err.message);
  }
}

function testCredentials(providerJson) {
  const credPath = join(DSH_HOME, ".credentials.yaml");
  if (!existsSync(credPath)) return skip("凭据文件", "未配置凭据（--skip-auth？）");
  const mode = statSync(credPath).mode & 0o777;
  check("凭据文件权限 0600", mode === 0o600, `实际 ${mode.toString(8)}`);
  if (flag("--skip-auth")) return skip(`凭据包含 ${providerJson?.keyEnv ?? "keyEnv"}`, "--skip-auth");
  if (providerJson?.keyEnv) {
    const has = readFileSync(credPath, "utf8").split("\n").some((l) => l.startsWith(`${providerJson.keyEnv}:`));
    check(`凭据包含 ${providerJson.keyEnv}（仅断言存在）`, has);
  }
}

function resolveDsh() {
  if (process.env.DSH_BIN && existsSync(process.env.DSH_BIN)) return process.env.DSH_BIN;
  for (const p of ["/opt/homebrew/bin/dsh", "/usr/local/bin/dsh"]) if (existsSync(p)) return p;
  const which = spawnSync("dsh", ["--version"], { stdio: "pipe" });
  return which.status === 0 ? "dsh" : undefined;
}

function testDsh() {
  const dsh = resolveDsh();
  if (!dsh) return skip("dsh --dump-config", "dsh 未安装");
  const res = spawnSync(dsh, ["--profile", "headless", "--dump-config"], {
    stdio: "pipe",
    timeout: 90_000,
    env: process.env,
  });
  check("dsh --profile headless --dump-config", res.status === 0, (res.stderr ?? "").toString().slice(0, 200));
  return dsh;
}

function testE2e(dsh, providerJson) {
  if (!flag("--e2e")) return;
  if (!dsh) return fail("e2e 真实调用", "dsh 未安装");
  const provider = providerJson?.provider ?? "deepseek-official";
  const model = providerJson?.defaultModel ?? providerJson?.models?.[0]?.modelId ?? "deepseek-v4-flash";
  const patchPath = join(tmpdir(), `dsh-smoke-${process.pid}.yml`);
  writeFileSync(patchPath, `- id: agent-default-model\n  config:\n    provider: ${provider}\n    model: ${model}\n`, { mode: 0o600 });
  const started = Date.now();
  try {
    const res = spawnSync(dsh, ["--profile", "headless", "--patch", patchPath, "只回复两个字：OK"], {
      stdio: "pipe",
      timeout: 180_000,
      env: process.env,
    });
    const out = (res.stdout ?? "").toString().trim();
    check(
      `e2e 真实调用（${provider}/${model}，${((Date.now() - started) / 1000).toFixed(1)}s）`,
      res.status === 0 && out.length > 0,
      (res.stderr ?? "").toString().slice(-300),
    );
  } finally {
    rmSync(patchPath, { force: true });
  }
}

console.log("DeepSeek Harness Desktop — 冒烟自检\n");
await testBridge();
const providerJson = testProviderJson();
testPaseo();
testCredentials(providerJson);
const dsh = testDsh();
testE2e(dsh, providerJson);

console.log(failures === 0 ? "\n全部通过 ✔" : `\n${failures} 项失败 ✘`);
process.exit(failures === 0 ? 0 : 1);
