#!/usr/bin/env node
/**
 * setup-provider.mjs — DeepSeek Harness Desktop 首次运行配置向导。
 *
 * 让 LLM 提供商成为可选项（DeepSeek 官方 / Agnes AI / 自定义 OpenAI 兼容端点），
 * 并完成一次性收尾：
 *   1. 交互（或 flags）选择 provider 并收集 API Key（DeepSeek 无 OAuth——
 *      “登录”即帮用户打开 platform.deepseek.com 建 key 后粘贴）
 *   2. key 写入 dsh 凭据层（$DSH_HOME/.credentials.yaml, 0600，行级合并不动其他 key）
 *   3. agnes/custom：在 $DSH_HOME/cordis.patch.yml 写入 llm-pi-ai 路由 patch
 *      （带标记注释，可安全重写/移除；deepseek-official 为 dsh 内置，无需声明）
 *   4. 写 $DSH_HOME/paseo-bridge/provider.json（ACP 桥读取的 provider/模型清单）
 *   5. 把 DeepSeek Harness 注册为 Paseo provider（$PASEO_HOME/config.json，备份 .bak）
 *
 * 用法：
 *   setup-provider.mjs                                  # 交互向导
 *   setup-provider.mjs --provider deepseek --key sk-... --yes
 *   setup-provider.mjs --provider custom --base-url https://x/v1 --model m --key sk-... --yes
 *   setup-provider.mjs --skip-auth --yes                # 只写 provider 选择，不碰凭据
 *   setup-provider.mjs --uninstall                      # 移除桥/provider 注册/路由 patch
 * flags: --provider --key --base-url --model --provider-id --env-name --display-name
 *        --yes --skip-auth --skip-paseo --uninstall --help
 * 环境：DSH_HOME（默认 ~/.dsh）、PASEO_HOME（默认 ~/.paseo）。
 * 交互输入优先读 /dev/tty（兼容 curl | bash 管道安装）。
 */
import {
  existsSync,
  readFileSync,
  writeFileSync,
  mkdirSync,
  chmodSync,
  copyFileSync,
  rmSync,
  readdirSync,
  rmdirSync,
  openSync,
  createReadStream,
} from "node:fs";
import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline/promises";

const DSH_HOME = process.env.DSH_HOME ?? join(homedir(), ".dsh");
const PASEO_HOME = process.env.PASEO_HOME ?? join(homedir(), ".paseo");
const PASEO_CONFIG = join(PASEO_HOME, "config.json");
const CRED_PATH = join(DSH_HOME, ".credentials.yaml");
const PATCH_PATH = join(DSH_HOME, "cordis.patch.yml");
const BRIDGE_DIR = join(DSH_HOME, "paseo-bridge");
const BRIDGE_PATH = join(BRIDGE_DIR, "dsh-acp-bridge.mjs");
const PROVIDER_JSON = join(BRIDGE_DIR, "provider.json");

const MARK_BEGIN = "# >>> deepseek-harness-desktop provider route — 由 setup-provider 维护，勿手改 >>>";
const MARK_END = "# <<< deepseek-harness-desktop <<<";
const MARK_RE = /# >>> deepseek-harness-desktop[\s\S]*?# <<< deepseek-harness-desktop <<<\n?/;

// ---------------------------------------------------------------------------
// provider 目录
// ---------------------------------------------------------------------------
const PROVIDERS = {
  deepseek: {
    key: "deepseek",
    providerId: "deepseek-official",
    label: "DeepSeek 官方",
    keyEnv: "DEEPSEEK_API_KEY",
    keyPage: "https://platform.deepseek.com/api_keys",
    baseURL: "https://api.deepseek.com",
    route: null, // dsh 内置路由，无需声明
    models: [
      { modelId: "deepseek-v4-flash", name: "DeepSeek V4 Flash", description: "默认，快" },
      { modelId: "deepseek-v4-pro", name: "DeepSeek V4 Pro", description: "更强，慢" },
    ],
  },
  agnes: {
    key: "agnes",
    providerId: "agnes",
    label: "Agnes AI",
    keyEnv: "AGNES_API_KEY",
    keyPage: "https://platform.agnes-ai.com",
    baseURL: "https://apihub.agnes-ai.com/v1",
    route: {
      displayName: "Agnes AI",
      api: "openai-completions",
      reasoning: "low",
      models: [
        { id: "agnes-2.5-flash", name: "Agnes 2.5 Flash", contextWindow: 262144, maxTokens: 32768 },
        { id: "agnes-2.5-pro", name: "Agnes 2.5 Pro", contextWindow: 262144, maxTokens: 32768 },
        { id: "agnes-2.0-flash", name: "Agnes 2.0 Flash", contextWindow: 131072, maxTokens: 8192 },
      ],
    },
    models: [
      { modelId: "agnes-2.5-flash", name: "Agnes 2.5 Flash", description: "默认，快" },
      { modelId: "agnes-2.5-pro", name: "Agnes 2.5 Pro", description: "更强，慢" },
      { modelId: "agnes-2.0-flash", name: "Agnes 2.0 Flash", description: "上一代" },
    ],
  },
};

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------
const ok = (msg) => console.log(`✔ ${msg}`);
const warn = (msg) => console.log(`! ${msg}`);
const die = (msg) => {
  console.error(`✘ ${msg}`);
  process.exit(1);
};

const args = process.argv.slice(2);
const flag = (name) => args.includes(name);
const opt = (name) => {
  const i = args.indexOf(name);
  return i !== -1 ? args[i + 1] : undefined;
};

if (flag("--help") || flag("-h")) {
  console.log(`setup-provider.mjs — DeepSeek Harness Desktop 首次配置向导

  交互模式（默认）      node setup-provider.mjs
  非交互                --provider deepseek|agnes|custom --yes [--key sk-...]
                        [--base-url URL --model ID --provider-id ID --env-name NAME --display-name NAME]
  其他                  --skip-auth（不碰凭据）  --skip-paseo（不注册 Paseo）  --uninstall`);
  process.exit(0);
}

/** 交互输入：优先 /dev/tty（curl | bash 时 stdin 被脚本占用） */
function ttyPrompt() {
  try {
    if (process.stdin.isTTY) {
      return createInterface({ input: process.stdin, output: process.stdout });
    }
    const fd = openSync("/dev/tty", "r");
    return createInterface({ input: createReadStream("/dev/tty", { fd }), output: process.stdout });
  } catch {
    return null;
  }
}

/** 读取凭据文件中某个 key（只返回布尔/值，绝不打印） */
function readCredential(keyEnv) {
  if (!existsSync(CRED_PATH)) return undefined;
  const line = readFileSync(CRED_PATH, "utf8")
    .split("\n")
    .find((l) => l.startsWith(`${keyEnv}:`));
  return line ? line.slice(keyEnv.length + 1).trim() || undefined : undefined;
}

function writeCredential(keyEnv, key) {
  mkdirSync(DSH_HOME, { recursive: true, mode: 0o700 });
  chmodSync(DSH_HOME, 0o700);
  let lines = [];
  if (existsSync(CRED_PATH)) {
    lines = readFileSync(CRED_PATH, "utf8").split("\n");
    if (!lines.at(-1)?.trim()) lines.pop();
  }
  const entry = `${keyEnv}: ${key.trim()}`;
  const idx = lines.findIndex((l) => l.startsWith(`${keyEnv}:`));
  if (idx !== -1) lines[idx] = entry;
  else lines.push(entry);
  writeFileSync(CRED_PATH, lines.join("\n") + "\n", { mode: 0o600 });
  chmodSync(CRED_PATH, 0o600);
  ok(`凭据已写入 ${CRED_PATH}（${keyEnv}）`);
}

/** 渲染 llm-pi-ai 路由 patch（固定结构的 YAML writer，字符串一律双引号转义） */
function renderRoutePatch(p) {
  const q = (s) => JSON.stringify(String(s));
  const lines = [
    MARK_BEGIN,
    "- id: llm-pi-ai",
    "  config:",
    "    providers:",
    `      ${p.providerId}:`,
    `        displayName: ${q(p.route.displayName)}`,
    `        apiKeyEnv: ${p.keyEnv}`,
    `        api: ${p.route.api}`,
    `        baseURL: ${q(p.baseURL)}`,
  ];
  if (p.route.reasoning) lines.push(`        reasoning: ${p.route.reasoning}`);
  lines.push("        models:");
  for (const m of p.route.models) {
    lines.push(
      `          - id: ${q(m.id)}`,
      `            name: ${q(m.name)}`,
      `            contextWindow: ${m.contextWindow}`,
      `            maxTokens: ${m.maxTokens}`,
      "            reasoningEfforts:",
      "              off:",
      "              low: low",
      "              high: high",
    );
  }
  lines.push(MARK_END);
  return lines.join("\n") + "\n";
}

/** 写/换/删 $DSH_HOME/cordis.patch.yml 中我们的路由块（routeYaml 为 null 时删除） */
function writeRoutePatch(routeYaml) {
  const existed = existsSync(PATCH_PATH);
  const current = existed ? readFileSync(PATCH_PATH, "utf8") : "";
  let next;
  if (MARK_RE.test(current)) {
    next = current.replace(MARK_RE, routeYaml ?? "");
  } else if (routeYaml) {
    next = current.trimEnd() ? current.trimEnd() + "\n\n" + routeYaml : routeYaml;
  } else {
    return; // 无标记块且无需写入
  }
  if (!next.trim()) {
    if (existed) rmSync(PATCH_PATH);
    ok(`已移除 ${PATCH_PATH}（无其他内容）`);
    return;
  }
  writeFileSync(PATCH_PATH, next);
  ok(routeYaml ? `路由已写入 ${PATCH_PATH}` : `已清理 ${PATCH_PATH} 中的路由块`);
}

function writeProviderJson(p) {
  mkdirSync(BRIDGE_DIR, { recursive: true });
  writeFileSync(
    PROVIDER_JSON,
    JSON.stringify(
      {
        provider: p.providerId,
        label: p.label,
        keyEnv: p.keyEnv,
        defaultModel: p.models[0].modelId,
        models: p.models,
      },
      null,
      2,
    ) + "\n",
  );
  ok(`provider 配置已写入 ${PROVIDER_JSON}（${p.label} / ${p.models[0].modelId}）`);
}

function registerPaseo() {
  if (flag("--skip-paseo")) return;
  if (!existsSync(PASEO_HOME)) {
    warn(`未发现 ${PASEO_HOME}（Paseo 未安装？），跳过 provider 注册`);
    return;
  }
  if (!existsSync(BRIDGE_PATH)) {
    warn(`桥文件 ${BRIDGE_PATH} 尚不存在（install.sh 会先复制）；仍写入注册信息`);
  }
  let config = {};
  if (existsSync(PASEO_CONFIG)) {
    config = JSON.parse(readFileSync(PASEO_CONFIG, "utf8"));
    copyFileSync(PASEO_CONFIG, PASEO_CONFIG + ".bak");
  }
  config.agents ??= {};
  config.agents.providers ??= {};
  config.agents.providers.deepseek = {
    extends: "acp",
    label: "DeepSeek Harness",
    description: "dsh headless（DeepSeek Harness Desktop 的 ACP 桥）",
    command: [BRIDGE_PATH],
  };
  writeFileSync(PASEO_CONFIG, JSON.stringify(config, null, 2) + "\n");
  ok(`Paseo provider "deepseek" 已写入 ${PASEO_CONFIG}（原配置备份为 .bak）`);
}

function detectLegacy() {
  const profilesDir = join(DSH_HOME, "profiles");
  if (!existsSync(profilesDir)) return;
  for (const name of readdirSync(profilesDir)) {
    const patch = join(profilesDir, name, "cordis.patch.yml");
    try {
      const text = readFileSync(patch, "utf8");
      if (/dsh-agnes-paseo|provider:\s*agnes/.test(text)) {
        warn(
          `检测到旧插件 dsh-agnes-paseo 残留（${patch}）。如已切换 provider，可手动清理：\n` +
            `  dsh plugin --profile ${name} remove dsh-agnes-paseo`,
        );
      }
    } catch {
      // 非文件/不可读：忽略
    }
  }
}

/** 廉价校验 key：GET {baseURL}/models（Bearer）。返回 true 或错误描述。 */
async function validateKey(baseURL, key) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 10_000);
  try {
    const res = await fetch(`${baseURL.replace(/\/+$/, "")}/models`, {
      headers: { authorization: `Bearer ${key.trim()}` },
      signal: ctrl.signal,
    });
    return res.ok ? true : `HTTP ${res.status}`;
  } catch (err) {
    return err?.name === "AbortError" ? "请求超时（10s）" : String(err?.message ?? err);
  } finally {
    clearTimeout(timer);
  }
}

function openKeyPage(url) {
  try {
    spawn("open", [url], { stdio: "ignore", detached: true }).unref();
  } catch {
    // 无法打开浏览器：忽略，用户可自行访问
  }
}

// ---------------------------------------------------------------------------
// 自定义 provider 收集
// ---------------------------------------------------------------------------
async function collectCustom(rl) {
  const ask = async (question, def) => {
    const suffix = def ? `（默认 ${def}）` : "";
    const answer = (await rl.question(`${question}${suffix}: `)).trim();
    return answer || def;
  };
  const providerId = (await ask("provider id（小写字母/数字/连字符）", "custom")) ?? "custom";
  if (!/^[a-z][a-z0-9-]*$/.test(providerId)) die(`非法 provider id：${providerId}`);
  const displayName = (await ask("显示名", providerId)) ?? providerId;
  const baseURL = await ask("baseURL（OpenAI 兼容，如 https://api.example.com/v1）");
  if (!baseURL || !/^https?:\/\//.test(baseURL)) die("baseURL 必填且需为 http(s) URL");
  const envDef = providerId.toUpperCase().replace(/[^A-Z0-9]+/g, "_") + "_API_KEY";
  const keyEnv = (await ask("凭据环境变量名", envDef)) ?? envDef;
  const modelId = await ask("模型 id（如 gpt-4o-mini）");
  if (!modelId) die("模型 id 必填");
  const modelName = (await ask("模型显示名", modelId)) ?? modelId;
  const contextWindow = Number((await ask("contextWindow", "131072")) ?? "131072");
  const maxTokens = Number((await ask("maxTokens", "8192")) ?? "8192");
  return buildCustom({ providerId, displayName, baseURL, keyEnv, modelId, modelName, contextWindow, maxTokens });
}

function buildCustom({ providerId, displayName, baseURL, keyEnv, modelId, modelName, contextWindow, maxTokens }) {
  return {
    key: "custom",
    providerId,
    label: displayName,
    keyEnv,
    keyPage: undefined,
    baseURL,
    route: {
      displayName,
      api: "openai-completions",
      models: [{ id: modelId, name: modelName, contextWindow, maxTokens }],
    },
    models: [{ modelId, name: modelName, description: "自定义模型" }],
  };
}

// ---------------------------------------------------------------------------
// 卸载
// ---------------------------------------------------------------------------
function uninstall() {
  writeRoutePatch(null);
  rmSync(PROVIDER_JSON, { force: true });
  rmSync(BRIDGE_PATH, { force: true });
  try {
    rmdirSync(BRIDGE_DIR);
  } catch {
    // 目录非空：保留
  }
  ok(`已移除桥与 provider 配置（${BRIDGE_DIR}）`);
  if (existsSync(PASEO_CONFIG)) {
    const config = JSON.parse(readFileSync(PASEO_CONFIG, "utf8"));
    const entry = config?.agents?.providers?.deepseek;
    if (entry && Array.isArray(entry.command) && entry.command[0] === BRIDGE_PATH) {
      copyFileSync(PASEO_CONFIG, PASEO_CONFIG + ".bak");
      delete config.agents.providers.deepseek;
      writeFileSync(PASEO_CONFIG, JSON.stringify(config, null, 2) + "\n");
      ok(`已从 ${PASEO_CONFIG} 移除 provider "deepseek"（备份为 .bak）`);
    }
  }
  console.log(`
卸载完成。未动的部分：
  - 凭据 ${CRED_PATH}（如需删除对应行请手动编辑）
  - dsh 本体（npm uninstall -g @deepseek-ai/dsh）与 Paseo 本体（brew uninstall --cask paseo）
  - 重启 Paseo daemon 使移除生效：paseo daemon restart`);
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------
async function main() {
  if (flag("--uninstall")) {
    uninstall();
    return;
  }

  const nonInteractive = flag("--yes");
  const skipAuth = flag("--skip-auth");
  let rl = null;
  const ask = async (question) => (rl ? (await rl.question(question)).trim() : "");

  // --- 1. 选择 provider -----------------------------------------------------
  let p;
  const providerArg = opt("--provider");
  if (providerArg) {
    if (providerArg === "custom") {
      const baseURL = opt("--base-url");
      const modelId = opt("--model");
      if (!baseURL || !modelId) die("--provider custom 需要 --base-url 与 --model");
      const providerId = opt("--provider-id") ?? "custom";
      if (!/^[a-z][a-z0-9-]*$/.test(providerId)) die(`非法 provider id：${providerId}`);
      p = buildCustom({
        providerId,
        displayName: opt("--display-name") ?? providerId,
        baseURL,
        keyEnv: opt("--env-name") ?? providerId.toUpperCase().replace(/[^A-Z0-9]+/g, "_") + "_API_KEY",
        modelId,
        modelName: opt("--display-name") ?? modelId,
        contextWindow: 131072,
        maxTokens: 8192,
      });
    } else if (PROVIDERS[providerArg]) {
      p = PROVIDERS[providerArg];
    } else {
      die(`未知 provider：${providerArg}（可选 deepseek / agnes / custom）`);
    }
  } else {
    rl = ttyPrompt();
    if (!rl) die("非交互终端且未指定 --provider；请使用 flags（见 --help）");
    console.log(`\nDeepSeek Harness Desktop — LLM 提供商选择\n`);
    console.log("  1) DeepSeek 官方（推荐）— platform.deepseek.com");
    console.log("  2) Agnes AI — platform.agnes-ai.com");
    console.log("  3) 自定义 OpenAI 兼容端点");
    const choice = (await ask("请选择 [1]: ")) || "1";
    if (choice === "1") p = PROVIDERS.deepseek;
    else if (choice === "2") p = PROVIDERS.agnes;
    else if (choice === "3") p = await collectCustom(rl);
    else die(`无效选择：${choice}`);
  }
  ok(`已选择 ${p.label}（provider: ${p.providerId}，模型: ${p.models.map((m) => m.modelId).join(" / ")}）`);

  // --- 2. 凭据 ---------------------------------------------------------------
  if (!skipAuth) {
    let key = opt("--key") ?? process.env[p.keyEnv] ?? readCredential(p.keyEnv);
    if (key && !opt("--key")) {
      ok(`复用已有 ${p.keyEnv}（凭据层/环境变量中已存在）`);
    }
    if (!key && !nonInteractive) {
      rl ??= ttyPrompt();
      if (rl && p.keyPage) {
        const go = await ask(`按回车打开 ${p.keyPage} 登录平台创建 API Key（输入 n 跳过）: `);
        if (go.toLowerCase() !== "n") openKeyPage(p.keyPage);
      }
      if (rl) key = await ask(`请粘贴 ${p.label} 的 API Key（sk-...）: `);
    }
    if (!key) {
      if (nonInteractive) die(`未提供 key：--key / 环境变量 ${p.keyEnv} / 凭据层均无（或用 --skip-auth 跳过）`);
      warn("未输入 key，跳过凭据写入（稍后可重跑本向导）");
    } else {
      const verdict = await validateKey(p.baseURL, key);
      if (verdict === true) {
        ok("API Key 校验通过");
      } else {
        warn(`API Key 校验未通过（${verdict}）；仍继续写入，如无法使用请检查 key/网络`);
      }
      writeCredential(p.keyEnv, key);
    }
  }

  // --- 3. 路由 patch（agnes/custom）与 provider.json --------------------------
  writeRoutePatch(p.route ? renderRoutePatch(p) : null);
  writeProviderJson(p);

  // --- 4. 注册 Paseo provider -------------------------------------------------
  registerPaseo();

  rl?.close();
  detectLegacy();

  console.log(`
完成。接下来：
  1. 重启 Paseo daemon 使配置生效：  paseo daemon restart
  2. 确认 provider 状态：            paseo provider ls
  3. 打开 Paseo，新建 agent 时选择 "DeepSeek Harness" 即可
${skipAuth ? `  ※ 本次跳过了凭据配置；也可在 dsh web（dsh web → 127.0.0.1:3080）的模型设置里补填 ${p.keyEnv}\n` : ""}`);
}

await main();
