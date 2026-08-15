// dsh-web-search-free 自测：node plugin/test.mjs
// 1) 离线 fixture：DDG / Bing 两个解析器（含跳转链还原、实体解码、反爬页识别）
// 2) 在线：经 provider 真跑一次搜索（DDG 不可达的网络会自动落到 Bing）

import assert from 'node:assert/strict'
import { parseDuckDuckGo, parseBing } from './index.js'

// --- DDG fixture：两个结果，uddg 跳转链 + HTML 实体 -------------------------
const DDG_HTML = `
<html><body>
<div class="result results_links results_links_deep web-result">
  <h2 class="result__title">
    <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fkimi-k2&amp;rut=abc123">Kimi K2 &amp; 开源模型</a>
  </h2>
  <a class="result__snippet" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fkimi-k2&amp;rut=abc123">Kimi K2 是 Moonshot 的万亿参数模型&#8230;&amp;lt;详情&amp;gt;</a>
</div>
<div class="result results_links results_links_deep web-result">
  <h2 class="result__title">
    <a rel="nofollow" class="result__a" href="https://direct.example.org/post">直接链接标题</a>
  </h2>
  <a class="result__snippet" href="https://direct.example.org/post">第二条摘要</a>
</div>
</body></html>`

const ddg = parseDuckDuckGo(DDG_HTML)
assert.equal(ddg.length, 2, 'DDG 应解析出 2 条')
assert.equal(ddg[0].url, 'https://example.com/kimi-k2', 'uddg 跳转链应还原')
assert.equal(ddg[0].title, 'Kimi K2 & 开源模型', '标题实体解码')
assert.ok(ddg[0].snippet.includes('Kimi K2 是 Moonshot'), '摘要应存在')
assert.equal(ddg[1].url, 'https://direct.example.org/post', '直链保留')
assert.equal(ddg[1].snippet, '第二条摘要')

// DDG 反爬页应抛错
assert.throws(() => parseDuckDuckGo('<html><body><div id="anomaly-modal">not a robot</div></body></html>'), /人机校验/)

// --- Bing fixture：b_algo 结果，直链 + ck/a 跳转链（u=a1+base64url）---------
const b64url = (s) => Buffer.from(s, 'utf8').toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
const BING_HTML = `
<html><body><ol id="b_results">
<li class="b_algo" data-id="1">
  <h2><a href="https://www.bing.com/ck/a?!&&p=xyz&amp;u=a1${b64url('https://news.example.com/ai')}&#38;ntb=1" h="ID=SERP,1">AI 新闻 &amp; 摘要</a></h2>
  <div class="b_caption"><p class="b_lineclamp4">这是第一条的摘要内容。</p></div>
</li>
<li class="b_algo" data-id="2">
  <h2><a href="https://plain.example.net/doc" h="ID=SERP,2">直链文档</a></h2>
  <div class="b_caption"><p>第二条摘要</p></div>
</li>
</ol></body></html>`

const bing = parseBing(BING_HTML)
assert.equal(bing.length, 2, 'Bing 应解析出 2 条')
assert.equal(bing[0].url, 'https://news.example.com/ai', 'ck/a 跳转链应 base64url 还原')
assert.equal(bing[0].title, 'AI 新闻 & 摘要')
assert.equal(bing[0].snippet, '这是第一条的摘要内容。')
assert.equal(bing[1].url, 'https://plain.example.net/doc')

// 非结果页应抛错
assert.throws(() => parseBing('<html><body>consent</body></html>'), /非结果页/)

console.log('✓ 离线 fixture 测试全部通过（DDG ×3 断言组 / Bing ×2 断言组）')

// CI 或离线环境可只跑 fixture：node plugin/test.mjs --offline
if (process.argv.includes('--offline')) {
  console.log('(--offline：跳过在线实测)')
  process.exit(0)
}

// --- 在线：经 provider 真跑一次 ---------------------------------------------
// 动态构造一个最小 ctx.web 桩，走插件注册路径，验证 seam 交互形状。
const { apply } = await import('./index.js')
let registered = null
apply({ web: { registerSearchProvider: (p) => (registered = p) } })
assert.ok(registered, 'provider 应注册到 ctx.web')
assert.equal(registered.id, 'free')
assert.equal(registered.available(), true, '免 Key provider 恒可用')

const started = Date.now()
const result = await registered.search({ query: 'deepseek v4 发布', maxResults: 5 })
assert.ok(Array.isArray(result.sources), 'sources 应为数组')
assert.ok(result.sources.length > 0, '在线搜索应返回至少 1 条结果')
assert.ok(result.sources.length <= 5, 'maxResults 应生效')
for (const s of result.sources) {
  assert.ok(/^https?:\/\//.test(s.url), `source url 合法: ${s.url}`)
}
console.log(`✓ 在线搜索通过：${result.sources.length} 条结果（${Date.now() - started}ms）`)
for (const s of result.sources.slice(0, 3)) {
  console.log(`  - ${s.title ?? '(无标题)'}\n    ${s.url}`)
}
