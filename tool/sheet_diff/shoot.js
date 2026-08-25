// Screenshots every widget on a design sheet at 2x, one PNG each, so a
// decomposed sheet becomes one reference per story.
//
// Usage: NODE_PATH=<a node_modules with playwright> node shoot.js <sheet.html> <outdir> [options]
//   --labels CSS    each match is a label; its next sibling is the widget,
//                   named by the label text (default: span[style*="ui-monospace"],
//                   the annotation style Claude Design's decomposed sheets use)
//   --targets CSS   shoot the matched elements themselves, named by
//                   data-story, then id, then index
//   --extra CSS     shoot one more element on its own (repeatable), e.g. a
//                   popover that overflows its card; named by id
//   --skip a,b      label texts / names to skip
//   --wait ms       settle time after fonts are ready (default 1500)
//   --dpr N         device scale factor (default 2)
//   --viewport WxH  (default 1700x1400)
//
// Writes <outdir>/<slug>.png and <outdir>/report.json ({name, file, w, h}).
// Every element is nudged onto a whole pixel before shooting: Playwright
// rounds a fractional offset outward and returns a blurred, 1px taller image.
const path = require('path');
const fs = require('fs');

let chromium;
try {
  ({ chromium } = require('playwright'));
} catch (e) {
  console.error('playwright not found: set NODE_PATH to a node_modules that has it, e.g.\n' +
    '  NODE_PATH=$(npm root -g) or NODE_PATH=<project>/node_modules');
  process.exit(2);
}

const argv = process.argv.slice(2);
const positional = [];
const opt = { labels: 'span[style*="ui-monospace"]', targets: null, extra: [], skip: [], wait: 1500, dpr: 2, viewport: '1700x1400' };
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (!a.startsWith('--')) { positional.push(a); continue; }
  const k = a.slice(2), v = argv[++i];
  if (k === 'extra') opt.extra.push(v);
  else if (k === 'skip') opt.skip.push(...v.split(','));
  else if (k === 'wait' || k === 'dpr') opt[k] = Number(v);
  else opt[k] = v;
}
const [sheet, outdir] = positional;
if (!sheet || !outdir) {
  console.error('usage: node shoot.js <sheet.html> <outdir> [--labels CSS | --targets CSS] [--extra CSS]... [--skip a,b] [--wait ms] [--dpr N] [--viewport WxH]');
  process.exit(2);
}
fs.mkdirSync(outdir, { recursive: true });

const slug = (s) =>
  s.toLowerCase()
    .replace(/[·()]/g, ' ')
    .replace(/å/g, 'a').replace(/ø/g, 'o').replace(/æ/g, 'ae')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '');

const nudge = (el) => {
  const y = el.getBoundingClientRect().top;
  const frac = y - Math.floor(y);
  if (frac) el.style.marginTop = (-frac) + 'px';
};

(async () => {
  const [w, h] = opt.viewport.split('x').map(Number);
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: w, height: h }, deviceScaleFactor: opt.dpr });
  const url = /^https?:/.test(sheet) ? sheet : 'file://' + path.resolve(sheet);
  await page.goto(url);
  await page.evaluate(() => document.fonts.ready);
  await page.waitForTimeout(opt.wait);

  const report = [];
  const shoot = async (name, handle) => {
    if (opt.skip.includes(name)) return;
    await handle.evaluate(nudge);
    const box = await handle.boundingBox();
    const file = slug(name) + '.png';
    await handle.screenshot({ path: path.join(outdir, file) });
    const frac = box.height % 1 || box.width % 1;
    report.push({ name, file, w: box.width, h: box.height });
    if (frac) console.error(`  ! ${name}: fractional size ${box.width}x${box.height}, the PNG is rounded outward; give the element an integer size`);
  };

  if (opt.targets) {
    const els = await page.$$(opt.targets);
    for (let i = 0; i < els.length; i++) {
      const name = await els[i].evaluate((el, i) => el.dataset.story || el.id || String(i), i);
      await shoot(name, els[i]);
    }
  } else {
    for (const label of await page.$$(opt.labels)) {
      const name = (await label.textContent()).trim();
      const widget = await label.evaluateHandle((el) => el.nextElementSibling);
      if (!(await widget.evaluate((el) => !!el))) continue;
      await shoot(name, widget.asElement());
    }
  }
  for (const sel of opt.extra) {
    const el = await page.$(sel);
    if (!el) { console.error(`--extra ${sel}: not found`); continue; }
    const name = await el.evaluate((e) => e.id || e.dataset.story || 'extra');
    await shoot(name, el);
  }

  fs.writeFileSync(path.join(outdir, 'report.json'), JSON.stringify(report, null, 2));
  for (const r of report) console.log(`${r.w}x${r.h}  ${r.name}  -> ${r.file}`);
  await browser.close();
})();
