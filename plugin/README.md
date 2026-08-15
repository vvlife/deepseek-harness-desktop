# dsh-web-search-free

**免 API Key 的 `web_search` 备选 provider**：DuckDuckGo 与 Bing 公开搜索页双通道竞速，
零凭据、零配置、零依赖（只用 Node 自带 `fetch`）。

## 为什么

dsh 内置的 `web_search` 默认走 `@deepseek-ai/dsh-web-search-deepseek`：每次搜索是一次
模型调用，需要 `DEEPSEEK_API_KEY` 且消耗 API 额度。本插件向 web seam（`ctx.web`）
注册一个 `available()` 恒真的 provider（id：`free`），搜索直接取公开搜索页结果，
不花一分钱额度。

## 安装

```sh
dsh plugin --profile web add "github:vvlife/deepseek-harness-desktop#main&path:/plugin"
```

装上即接管 `web_search`：bundle patch（`cordis.patch.yml`）把 web seam 的
`searchProvider` 从 `deepseek-official` 指向 `free`。

**改回官方搜索**：`dsh plugin --profile web remove dsh-web-search-free`；
或在自己 profile 的 `cordis.patch.yml` 里加：

```yaml
- id: web
  config:
    searchProvider: deepseek-official
```

## 工作方式

- **双通道竞速**：DuckDuckGo html 端点与 Bing 结果页并行请求（搜索是幂等 GET），
  先返回有效结果的通道胜出；一家被反爬拦 / 网络不可达时自动落到另一家，两家都失败才报错。
  某些地区 DDG 不可达时 Bing 立刻顶上，反之亦然。
- **解析**：DDG 的 `result__a` / `result__snippet` 与 Bing 的 `b_algo` 列表项；
  `uddg` 与 `ck/a`（`u=a1` + base64url）跳转链还原为真实 URL；HTML 实体解码。
- **结果**：归一化为 web seam 的 `WebSearchSource[]`（url/title/snippet），
  `maxResults` 由 seam 统一截断。

## 测试

```sh
node plugin/test.mjs            # 离线 fixture 单测 + 在线实测
node plugin/test.mjs --offline  # 只跑离线 fixture（CI / 无网环境）
```

离线 fixture 覆盖：双引擎解析、`uddg` / `ck/a` 跳转链还原、实体解码、反爬页识别。
在线实测经插件注册路径真跑一次搜索并断言结果结构。

已在 dsh web / headless profile 实测：`dsh plugin add` 后 `--dump-config` 可见
`searchProvider: free`，headless agent 的 `web_search` 调用实际命中本 provider
（session 日志无 deepseek provider 的请求记录）。
