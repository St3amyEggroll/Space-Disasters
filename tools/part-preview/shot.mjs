// node shot.mjs page.html out.png "#part=all&view=current&spin=0" [width] [height]
import { createRequire } from 'module';
import { execSync } from 'child_process';
const require = createRequire(import.meta.url);
const root = execSync('npm root -g').toString().trim();
const { chromium } = require(root + '/playwright');
const [page_, out, hash = '', w = '1600', h = '1000'] = process.argv.slice(2);
const browser = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] });
const page = await browser.newPage({ viewport: { width: +w, height: +h } });
page.on('console', m => { if (m.type() === 'error') console.log('console:', m.text()); });
page.on('pageerror', e => console.log('pageerror:', e.message));
const path = require('path');
await page.goto('file://' + path.resolve(page_) + hash);
await page.waitForFunction(() => window.__ready === true, null, { timeout: 30000 });
await page.waitForTimeout(1500);
await page.screenshot({ path: out });
await browser.close();
console.log('saved', out);
