# flutter_static

A story catalog for Flutter widgets that renders to PNG over HTTP, built
for agents as much as for people, and a macOS Studio on top of it for
design work whose output is real widgets.

- `ARCHITECTURE.md`: the catalog, the render pipeline, the HTTP API.
- `docs/studio.md`: Studio, design tokens, specimen widgets.
- `docs/studio-agent-handoff.md`: where the Studio work stands.
- `docs/design-iteration-notes.md`: what pixel-matching designs taught us.

```text
flutter_static up                       # catalog for the project in cwd
flutter_static render buttons/kinds -o out.png
flutter_static tokens list              # design tokens from source
flutter_static studio --project <dir>   # the macOS Studio
```
