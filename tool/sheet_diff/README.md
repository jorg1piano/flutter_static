# sheet_diff

The numeric half of the flutter_static loop: reference screenshots of
every widget on a design sheet, a diff sweep against the catalog's
renders, and small probes for "which word is off" and "what does Chrome
actually do here". Generalized from the loop that made
`mobile_elixir/.../owner_card.dart` match the "Na Matrise Eier -
decomposed" sheet (23 widgets, means 0.1–2.6/255). The findings from that
loop are in `docs/design-iteration-notes.md`, round 6.

The flutter-static skill links this directory as
`~/.claude/skills/flutter-static/scripts/` and describes when to run what.

| file | job |
| --- | --- |
| `shoot.js` | Playwright: opens a sheet at 2x, shoots every labelled widget (or `--targets CSS`) into `<outdir>/<slug>.png` plus `report.json`. Nudges each element onto a whole pixel first and warns on fractional sizes. |
| `diff.py` | fetches each story from the running catalog (or `--renders DIR`), compares with its reference, prints mean diff and the worst 16 px band, writes `<story>.cmp.png` (reference \| render \| x4 heatmap). Pairs come from `--pairs FILE` (JSON) or `--pair ID=REF`. |
| `segs.py`, `rows.py` | ink runs along x (words) or y (lines) in a band of two images, side by side. |
| `calib.py` | tracking calibration: one sample line per text style, emitted as HTML (`html`) and as a Dart story (`dart`), then measured band by band (`measure`). Styles come from a JSON list. Flags the ~3% case that means `letterSpacing: null`. |
| `probe.js` | asks Chrome which faces of a family loaded, a string's width under a CSS font, and the line boxes it gives icon-font spans and text spans. |

Needs `numpy` and `Pillow` for the Python scripts, and Playwright on
`NODE_PATH` for the Node ones:

```sh
export NODE_PATH=<any node_modules that has playwright>
node tool/sheet_diff/shoot.js sheet.html /tmp/ref --extra '#row-menu'
echo '{"owner/shell": "kortskall.png"}' > pairs.json
python3 tool/sheet_diff/diff.py --ref /tmp/ref --out /tmp/cmp --pairs pairs.json
python3 tool/sheet_diff/segs.py /tmp/ref/kortskall.png /tmp/cmp/owner_shell.render.png 40 80
node tool/sheet_diff/probe.js sheet.html --text "Ingen svar ennå" --font "700 12.5px Inter"
```

Every script prints usage with no arguments or `--help`.

Not carried over from the original: `decode_assets.py` and
`make_standin.py` (turning DesignSync's base64 into asset files, drawing a
stand-in for an image the export truncated) and `sheets/`, the sheet
itself.
