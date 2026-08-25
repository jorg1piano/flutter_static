# flutter_static

A Storybook-like catalog for Flutter widgets, built for AI agents as much as humans.
Renders stories to PNG plus structured data (semantics, diagnostics) instead of an
opaque Flutter web canvas.

## Core idea

Stories are Dart functions returning widgets, with named variants instead of knobs.
A live harness renders each variant offscreen and exposes the result three ways:
a browser gallery for humans, HTTP endpoints and MCP tools for agents.

## Components

### Story registry
- `Story('button/primary', (ctx) => PrimaryButton(...))` with enumerated variants.
- Single source of truth shared by all harnesses and servers.

### Render pipeline
- Builds each widget into its own offscreen render tree (own `BuildOwner`/`PipelineOwner`),
  fixed size and device pixel ratio, independent of any window.
- Per variant emits:
  - PNG via `toImage()`
  - semantics tree JSON (labels, roles, actions, bounds)
  - diagnostics JSON (widget types, properties, constraints)
  - entry in a catalog `index.json`

### Harness: macOS desktop app (primary)
- Real embedder: Impeller on Metal, real fonts and fallback, real shadows, plugins work.
- Window is a status panel only; all rendering is offscreen.
- Debug mode with hot reload; `reassemble` is the single change event that re-renders
  dirty stories and fans out to all consumers.

### Harness: flutter_tester (CI, later)
- Same stories, same capture code, headless software rendering.
- Runs on cheap Linux runners. Minor pixel differences vs GPU are acceptable there.

### HTTP server (in-app, shelf)
- `GET /` plain HTML/JS gallery. Real DOM, agent-readable, no Flutter web canvas.
- `GET /story/<id>.png`, `GET /story/<id>/semantics.json`, `GET /index.json`
- SSE endpoint for gallery live reload.
- Later: `POST /story/<id>/tap?node=N` for interactive stories.

### MCP server (in-app, package:dart_mcp)
- Tools: `list_stories`, `render_story`, `get_semantics`, `wait_for_changes(timeout)`.
- `wait_for_changes` long-polls and returns changed story IDs; works with every client.
- Stories also exposed as subscribable resources emitting `resources/updated`
  for clients that honor notifications.

## Agent loop

1. Agent edits widget code.
2. Hot reload (via the official `dart mcp-server`, or the file watcher).
3. `reassemble` re-renders changed stories.
4. Agent's pending `wait_for_changes` returns the diff.
5. Agent fetches new PNGs and semantics for exactly those stories.

Save-to-updated-render, measured 2026-08-25 via `flutter_static render` right
after a save: 0.28 to 0.45 s on both a 773-library test app and a 1511-library
app. The VM reload phase (100 to 250 ms) is the floor and grows with heap size,
which is why the catalog prewarms only the hot set after a reload.

## Non-goals (v1)

- Knobs on plain stories (variants are enumerated instead). Storylines do get
  knobs, one per mock the flow can run on, because a flow's screens share the
  data behind them and a variant per data set would multiply every cell.
- Pixel parity with Android devices
- Flutter web build of the catalog
