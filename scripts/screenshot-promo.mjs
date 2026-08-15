#!/usr/bin/env node
/**
 * 为 README / 宣传站截取实时界面图（亮色主题）。
 * 前提：DeepSeek Harness Desktop 正在运行（Paseo :6868、dsh web :3180）。
 * playwright 依赖复用 whalehub-dsh 仓库的 node_modules：
 *   node scripts/screenshot-promo.mjs
 */
import { mkdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createRequire } from 'node:module'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const OUT = join(ROOT, 'docs', 'images')
const require = createRequire(new URL('file:///Users/nxhuang/Documents/Project/kimi%20with%20paseo/whalehub-dsh/package.json'))
const { chromium } = require('playwright')

const PASEO = process.env.PASEO_URL ?? 'http://127.0.0.1:6868'
const WEB = process.env.WEB_URL ?? 'http://127.0.0.1:3180'
const VIEW = { viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2, colorScheme: 'light' }

async function newPage(browser, url) {
  const ctx = await browser.newContext(VIEW)
  const page = await ctx.newPage()
  await page.goto(url, { waitUntil: 'networkidle', timeout: 30000 })
  await page.waitForTimeout(2000)
  return { ctx, page }
}

async function main() {
  mkdirSync(OUT, { recursive: true })
  const browser = await chromium.launch()
  try {
    // Paseo（Mobile 界面）：首页
    {
      const { ctx, page } = await newPage(browser, PASEO)
      await page.mouse.move(720, 500)
      await page.screenshot({ path: join(OUT, 'shot-paseo.png') })
      console.log('✓ shot-paseo.png')
      await ctx.close()
    }
    // dsh web（Web 界面）：关 Explorer → 展开会话侧栏 → 首页 / 真实会话
    {
      const { ctx, page } = await newPage(browser, WEB)
      try { await page.locator('xpath=//*[contains(text(),"Explorer")]/following-sibling::*[1]').first().click({ timeout: 1500 }) } catch {}
      await page.waitForTimeout(600)
      await page.mouse.click(1412, 23) // 折叠右面板、展开左侧会话栏
      await page.waitForTimeout(800)
      await page.mouse.move(720, 500)
      await page.waitForTimeout(400)
      await page.screenshot({ path: join(OUT, 'shot-harness-web.png') })
      console.log('✓ shot-harness-web.png')
      await page.locator('text=用户打招呼').first().click().catch(() => {})
      await page.waitForTimeout(2500)
      await page.mouse.move(720, 500)
      await page.screenshot({ path: join(OUT, 'shot-session.png') })
      console.log('✓ shot-session.png')
      await ctx.close()
    }
  } finally {
    await browser.close()
  }
}

main().catch((e) => { console.error(e); process.exit(1) })
