# flutter_static

A story catalog for Flutter widgets that renders to PNG over HTTP, built
for agents as much as for people, and a macOS Studio on top of it for
design work whose output is real widgets.

- `ARCHITECTURE.md`: the catalog, the render pipeline, the HTTP API.
- `docs/studio.md`: Studio, design tokens, specimen widgets.
- `docs/studio-agent-handoff.md`: where the Studio work stands.
- `docs/design-iteration-notes.md`: what pixel-matching designs taught us.

Static PNG rendering via a custom Flutter engine embedder is being explored on
branch `engine_approach`; the current MVP renders 50 offscreen pages in one
resident engine process.

```bash
git fetch && git switch engine_approach
```

```text
flutter_static up                       # catalog for the project in cwd
flutter_static render buttons/kinds -o out.png
flutter_static inspect buttons/kinds --at 240,80   # which widget is there, which line made it
flutter_static tokens list              # design tokens from source
flutter_static studio --project <dir>   # the macOS Studio
```

Package split:

- `packages/flutter_static_story`: pure Flutter story primitives and generic
  composition widgets (`Story`, `Stories`, storylines, device mockups,
  specimens). App repositories can depend on this from their `story/` files
  without pulling in Studio/macOS plugin dependencies.
- `flutter_static`: CLI, catalog server, Studio runtime and macOS tooling.
  This package still owns dependencies such as `speech_to_text` and
  `flutter_pty`.
