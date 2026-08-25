# Flutter Static Studio: agent handoff

State of the Studio work, so a new session can continue. Read
`docs/studio.md` for what Studio is and how it is put together; this
file is about where things are and what was verified.

## Where

- Package and Studio host: this checkout (branch `macos-canvas`).
- Playground project: `/Users/jorgen/github/studio_playground`, a fresh
  Flutter app whose design system is `packages/app_ui`. Its pubspec
  points `flutter_static` at `../worktree-macos-canvas`; repoint it if
  the branch lands somewhere else.
- An older Studio MVP (two-pane, stub prompt) lives uncommitted on the
  `engine_approach` worktree in `lib/studio_main.dart`; this branch
  replaces it and nothing from there is needed.

## What exists

In flutter_static:

- `lib/src/tokens.dart`: token discovery, parsing, write-back.
- `lib/src/specimens.dart`: `ColorSwatches`, `TypeSpecimen`,
  `SpacingScale`, `RadiusScale`.
- `lib/src/server_io.dart`: `GET /tokens.json`, `POST /tokens`, and
  `rows` under each storyline in `/index.json`.
- `bin/flutter_static.dart`: `studio` and `tokens list|set`.
- `lib/studio_main.dart` + `lib/src/studio/`: the Studio app
  (controller, model, canvas, inspector, tokens_panel, sidebar).
- `macos/Runner/*.entitlements`: sandbox off; `MainFlutterWindow.swift`
  opens larger.

In the playground:

- `packages/app_ui/lib/src/tokens/{colors,spacing,radii,typography}.dart`
- `packages/app_ui/lib/src/layout.dart`: `VStack`, `HStack`, `Gap`,
  `Inset` taking spacing tokens.
- Components: `AppText`, `AppButton`, `AppCard`, `AppBadge`,
  `AppAvatar`, `AppTextField`, `AppListItem`.
- Screens: `WelcomeScreen`, `SignInScreen`, `HomeScreen` (data and
  callbacks in, no logic).
- `story/stories/{tokens,text,buttons,cards,inputs}.dart`,
  `story/lines/onboarding.dart` (two rows, four cells, a data knob).

## Verified

- `flutter analyze` clean in both projects.
- `flutter_static up` in the playground: 22 stories, renders correct
  (tokens sheets, components, the three screens in phone mockups, the
  knob switching the home screen's data).
- `/tokens.json` lists the four groups; `tokens set` rewrites a value
  and the catalog hot reloads it.
- Studio launches against the playground, shows pages and tokens, and
  a colour drag in the `AppColors` panel rewrites `colors.dart` and
  refreshes the canvas.

## Next

1. A story's source location in `/index.json` (the `Story` could carry
   it, or the CLI's `add story` could register it), so the inspector
   can open the file and an agent can be pointed at it.
2. Token references in components ("this button uses `Radii.md`") for
   a Figma-like "where is this used" panel. A grep over `lib/` for
   `Group.name` is enough for a first version.
3. A prompt box that writes the request plus the selected story id and
   render command to a file or MCP call for an agent to pick up.
4. Multi-select and side-by-side device comparison on the canvas.
