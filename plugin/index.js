// dsh-web-search-free — 免 API Key 的 web_search provider。
//
// dsh 内置的 web_search 走 deepseek-official provider：每次搜索消耗一次模型调用、
// 需要 DEEPSEEK_API_KEY。本插件注册一个零凭据的备选 provider（id: `free`），
// 直接用公开搜索页取结果，装进 profile 即接管 web seam（见 cordis.patch.yml）。
//
// 通道链：DuckDuckGo（html 端点）与 Bing 并行竞速——搜索是幂等 GET，
// 哪边先出有效结果用哪边；部分地区 DDG 不可达时 Bing 立刻顶上，反之亦然。
// 两家都失败才报错。遵循 dsh 零依赖传统：只用 Node 自带 fetch，不引包。

export const name = 'dsh-web-search-free'
export const inject = ['web']

const PROVIDER_ID = 'free'
const ENGINE_TIMEOUT_MS = 12000
const MAX_SOURCES = 20 // 抓取侧硬上限；maxResults 由 web seam 统一截断
const USER_AGENT =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'

// ---------------------------------------------------------------------------
// HTML 解析小工具

/** 解码常见 HTML 实体（命名 + 十/十六进制数字）。 */
function decodeEntities(text) {
  return String(text)
    .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n)))
    .replace(/&#x([0-9a-f]+);/gi, (_, n) => String.fromCodePoint(parseInt(n, 16)))
    .replace(/&(amp|lt|gt|quot|nbsp|#39);/g, (_, name) => {
      switch (name) {
        case 'amp': return '&'
        case 'lt': return '<'
        case 'gt': return '>'
        case 'quot': return '"'
        case 'nbsp': return ' '
        case '#39': return "'"
        default: return _
      }
    })
}

/** 剥掉 HTML 标签并解码实体，压缩空白。 */
function textOf(html) {
  return decodeEntities(String(html).replace(/<[^>]+>/g, ' ')).replace(/\s+/g, ' ').trim()
}

/** 从 href 属性值还原真实 URL：处理 DDG 跳转链与 Bing ck/a 跳转链。 */
function resolveUrl(href) {
  if (!href) return null
  let url = decodeEntities(href)
  if (url.startsWith('//')) url = 'https:' + url
  // DuckDuckGo: //duckduckgo.com/l/?uddg=<urlencoded>&rut=...
  const uddg = /[?&]uddg=([^&]+)/.exec(url)
  if (uddg) {
    try { return decodeURIComponent(uddg[1]) } catch { return null }
  }
  // Bing: https://www.bing.com/ck/a?...&u=a1<base64url>&...
  if (/\/ck\/a[?&!]/.test(url)) {
    const u = /[?&]u=([^&]+)/.exec(url)
    if (u) {
      try {
        let payload = u[1]
        if (payload.startsWith('a1')) payload = payload.slice(2)
        return Buffer.from(payload.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8')
      } catch { return null }
    }
    return null
  }
  return /^https?:\/\//.test(url) ? url : null
}

/** 提取标签的 href 属性。 */
function hrefOf(tag) {
  const m = /\bhref\s*=\s*"([^"]*)"/i.exec(tag) || /\bhref\s*=\s*'([^']*)'/i.exec(tag)
  return m ? m[1] : null
}

// ---------------------------------------------------------------------------
// 搜索引擎通道。约定：解析函数返回 sources 数组（可为空 = 真没有结果）；
// 被反爬拦 / 网络失败 / 页面结构不符 → 抛错，交给竞速逻辑换通道。
// parse* 为纯函数并导出，供离线 fixture 测试。

/** DuckDuckGo html 端点解析：result__a 标题链 + result__snippet 摘要。 */
export function parseDuckDuckGo(html) {
  // 反爬挑战页（anomaly modal / vqd 校验）按失败处理，让 Bing 接手
  if (/anomaly|challenge-modal|not a robot/i.test(html) && !/result__a/.test(html)) {
    throw new Error('DuckDuckGo 返回人机校验页')
  }
  const anchors = [...html.matchAll(/<a\b[^>]*class="result__a"[^>]*>/gi)]
  const sources = []
  for (let i = 0; i < anchors.length && sources.length < MAX_SOURCES; i++) {
    const tag = anchors[i][0]
    const start = anchors[i].index + tag.length
    const end = i + 1 < anchors.length ? anchors[i + 1].index : Math.min(html.length, start + 4000)
    const block = html.slice(start, end)
    const url = resolveUrl(hrefOf(tag))
    if (!url) continue
    const close = block.indexOf('</a>')
    const title = textOf(close >= 0 ? block.slice(0, close + 4) : '')
    const snip = /class="result__snippet"[^>]*>([\s\S]*?)<\/a>/i.exec(block)
    sources.push({
      url,
      ...(title ? { title } : {}),
      ...(snip && textOf(snip[1]) ? { snippet: textOf(snip[1]) } : {}),
    })
  }
  return sources
}

/** Bing 结果页解析：b_algo 列表项，h2 链接 + 块内首个 <p> 摘要。 */
export function parseBing(html) {
  if (!html.includes('b_results')) throw new Error('Bing 返回了非结果页（可能触发验证）')
  const blocks = html.split('<li class="b_algo"').slice(1)
  const sources = []
  for (const block of blocks) {
    if (sources.length >= MAX_SOURCES) break
    const head = /<h2[^>]*>\s*<a\b([^>]*)>([\s\S]*?)<\/a>\s*<\/h2>/i.exec(block)
    if (!head) continue
    const url = resolveUrl(hrefOf('<a' + head[1] + '>'))
    if (!url) continue
    const title = textOf(head[2])
    const rest = block.slice(head.index + head[0].length)
    const snip = /<p\b[^>]*>([\s\S]*?)<\/p>/i.exec(rest)
    sources.push({
      url,
      ...(title ? { title } : {}),
      ...(snip && textOf(snip[1]) ? { snippet: textOf(snip[1]) } : {}),
    })
  }
  return sources
}

const ENGINE_HEADERS = { 'user-agent': USER_AGENT, 'accept': 'text/html' }

async function searchDuckDuckGo(query, signal) {
  const res = await fetch('https://html.duckduckgo.com/html/?q=' + encodeURIComponent(query), {
    headers: ENGINE_HEADERS,
    redirect: 'follow',
    signal,
  })
  if (!res.ok) throw new Error(`DuckDuckGo HTTP ${res.status}`)
  return parseDuckDuckGo(await res.text())
}

async function searchBing(query, signal) {
  const res = await fetch(
    'https://www.bing.com/search?q=' + encodeURIComponent(query) + '&count=' + MAX_SOURCES,
    { headers: ENGINE_HEADERS, redirect: 'follow', signal },
  )
  if (!res.ok) throw new Error(`Bing HTTP ${res.status}`)
  return parseBing(await res.text())
}

const ENGINES = [
  { name: 'duckduckgo', run: searchDuckDuckGo },
  { name: 'bing', run: searchBing },
]

/** 竞速：先拿到非空结果的通道胜出；一家为空则等另一家；全空按空结果返回，全失败抛错。 */
function raceEngines(query, signal) {
  return new Promise((resolve, reject) => {
    let pending = ENGINES.length
    let empty = null
    const failures = []
    let settled = false
    const done = (fn, value) => {
      if (settled) return
      settled = true
      fn(value)
    }
    for (const engine of ENGINES) {
      engine
        .run(query, signal)
        .then((sources) => {
          if (sources.length > 0) return done(resolve, { engine: engine.name, sources })
          empty ??= { engine: engine.name, sources }
        })
        .catch((error) => {
          failures.push(`${engine.name}: ${String((error && error.message) || error)}`)
        })
        .finally(() => {
          if (--pending === 0 && !settled) {
            if (empty) resolve(empty)
            else reject(new Error('所有免 Key 搜索通道都不可用：' + failures.join('；')))
          }
        })
    }
  })
}

// ---------------------------------------------------------------------------
// ctx.web seam 的 WebSearchProvider 实现（零凭据，available 恒真）。

class FreeSearchProvider {
  id = PROVIDER_ID

  /** 无需 Key、无需配置：本地可用性恒为真（seam 要求此处不发网络请求）。 */
  available() {
    return true
  }

  async search(request, signal) {
    if (signal?.aborted) throw new Error('free search aborted')
    const query = String(request?.query ?? '').trim()
    if (!query) throw new Error('free search 需要非空 query')
    const engineSignal = AbortSignal.any(
      [AbortSignal.timeout(ENGINE_TIMEOUT_MS), ...(signal ? [signal] : [])].filter(Boolean),
    )
    const { sources } = await raceEngines(query, engineSignal)
    const capped =
      Number.isInteger(request.maxResults) && request.maxResults > 0
        ? sources.slice(0, request.maxResults)
        : sources
    return { sources: capped, truncated: false }
  }
}

/** 把免 Key provider 注册进 web seam；选择逻辑由 seam 的 searchProvider 配置接管。 */
export function apply(ctx) {
  ctx.web.registerSearchProvider(new FreeSearchProvider())
}
