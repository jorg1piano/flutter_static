// Asks Chrome how it lays out text on a page: which faces of a font
// family loaded, a probe string's width under a style, and the line box
// heights it gives icon-font spans and text spans. The numbers a Flutter
// type scale has to reproduce (naturalHeight, iconLineBox).
//
// Usage: NODE_PATH=<node_modules with playwright> node probe.js <page.html|url> [options]
//   --text T --font "700 12.5px Inter"   width of T set in that CSS font shorthand
//   --family Inter                       font family to report faces and line boxes for (default Inter)
//   --symbols "Material Symbols"         icon font family substring (default Material Symbols)
//   --wait ms                            settle time after fonts are ready (default 1500)
const path = require('path');

let chromium;
try {
  ({ chromium } = require('playwright'));
} catch (e) {
  console.error('playwright not found: set NODE_PATH to a node_modules that has it');
  process.exit(2);
}

const argv = process.argv.slice(2);
const opt = { family: 'Inter', symbols: 'Material Symbols', wait: 1500, text: null, font: null };
let page_ = null;
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (!a.startsWith('--')) { page_ = a; continue; }
  const k = a.slice(2), v = argv[++i];
  opt[k] = k === 'wait' ? Number(v) : v;
}
if (!page_) {
  console.error('usage: node probe.js <page.html|url> [--text T --font "700 12.5px Inter"] [--family F] [--symbols S] [--wait ms]');
  process.exit(2);
}

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1700, height: 1400 }, deviceScaleFactor: 2 });
  await page.goto(/^https?:/.test(page_) ? page_ : 'file://' + path.resolve(page_));
  await page.evaluate(() => document.fonts.ready);
  await page.waitForTimeout(opt.wait);

  const out = await page.evaluate((opt) => {
    const r = { fonts: [], probe: null, symbols: {}, texts: {} };
    // Google Fonts splits each face into unicode-range subsets; collapse to one line per face.
    const faces = {};
    for (const f of document.fonts) {
      if (f.family.replace(/"/g, '') !== opt.family) continue;
      const k = `${f.weight} ${f.style}`;
      faces[k] ||= { loaded: 0, total: 0 };
      faces[k].total++;
      if (f.status === 'loaded') faces[k].loaded++;
    }
    r.fonts = Object.entries(faces).sort().map(([k, v]) => `${k} (${v.loaded}/${v.total} subsets loaded)`);
    if (opt.text) {
      const probe = document.createElement('span');
      probe.style.cssText = `font:${opt.font};white-space:nowrap;position:absolute`;
      probe.textContent = opt.text;
      document.body.appendChild(probe);
      r.probe = { width: probe.getBoundingClientRect().width, fontFamily: getComputedStyle(probe).fontFamily };
      probe.remove();
    }
    for (const el of document.querySelectorAll('span,button,div,i')) {
      const cs = getComputedStyle(el);
      if (cs.fontFamily.includes(opt.symbols)) {
        const b = el.getBoundingClientRect();
        (r.symbols[cs.fontSize] ||= new Set()).add(`${b.height.toFixed(2)}x${b.width.toFixed(2)}`);
      }
    }
    for (const k in r.symbols) r.symbols[k] = [...r.symbols[k]];
    for (const el of document.querySelectorAll('span,div,p,button,a,h1,h2,h3')) {
      if (el.children.length || !el.textContent.trim()) continue;
      const cs = getComputedStyle(el);
      if (!cs.fontFamily.replace(/"/g, '').startsWith(opt.family)) continue;
      const k = `${cs.fontSize} w${cs.fontWeight} lh:${cs.lineHeight}`;
      if (r.texts[k]) continue;
      r.texts[k] = { box: +el.getBoundingClientRect().height.toFixed(2), sample: el.textContent.trim().slice(0, 24) };
    }
    return r;
  }, opt);

  console.log(`${opt.family} faces: ${out.fonts.join(' | ') || '(none loaded)'}`);
  if (out.probe) console.log(`probe "${opt.text}" in ${opt.font}: ${out.probe.width.toFixed(2)} px (${out.probe.fontFamily})`);
  const sym = Object.entries(out.symbols);
  if (sym.length) {
    console.log(`${opt.symbols} line boxes (h x w):`);
    for (const [size, boxes] of sym) console.log(`  ${size.padEnd(8)} ${boxes.join(', ')}`);
  }
  const texts = Object.entries(out.texts).sort();
  if (texts.length) {
    console.log(`${opt.family} line boxes:`);
    for (const [k, v] of texts) console.log(`  ${k.padEnd(28)} ${String(v.box).padStart(6)}   ${v.sample}`);
  }
  await browser.close();
})();
