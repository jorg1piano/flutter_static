# Flutter Static Studio

A macOS workbench for a Flutter project's design system. Think Figma, but
the artboards are real widgets and the source of truth is Dart on disk.

```text
flutter_static studio --project /path/to/app
```

Studio opens with the project's pages on a canvas, its design tokens in
the sidebar, and the project's own catalog running underneath. Edit a
token in Studio and the Dart file changes; the catalog hot reloads; every
render that uses the token updates. Edit the Dart file from an editor or
an agent and Studio updates the same way.

## What it is for

The output of a Studio session is a UI package with tokens, components
and screens, each on a story, that an agent can implement application
logic against without touching the design. The loop:

1. Tokens in `lib/**/tokens/*.dart` (or `tokens.dart`): colours,
   spacing, radii, type styles as `static const` members of classes.
2. Layout primitives built on the tokens: a `VStack`/`HStack` with a
   `gap` from the spacing scale, `Inset` for padding, `Gap` for space.
   Change `Space.md` and every stack that uses it moves.
3. Components (`AppButton`, `AppCard`, ...) built from the primitives
   and tokens, each with a story per state.
4. Screens composed from the components, taking data and callbacks,
   each a cell in a storyline with variants for its states.
5. The app wires screens to logic. Studio never runs the app.

The playground at `../studio_playground` (`packages/app_ui`) is a
complete example of this shape.

## Architecture

```text
Studio host (macOS, this package: lib/studio_main.dart)
  ├─ sidebar: pages, token groups, process controls
  ├─ canvas: rows of renders, pan/zoom (InteractiveViewer)
  ├─ inspector: device, status bar, knobs, selected story
  ├─ token editors: write the project's Dart files (src/tokens.dart)
  ├─ child process: dart <this package>/bin/flutter_static.dart up
  └─ HTTP client: /index.json, /story/<id>.png, /events (SSE)

User project catalog (child, `flutter run --machine -d macos -t story/main.dart`)
  ├─ the project's stories, tokens and packages, hot reloaded on save
  └─ the flutter_static HTTP API
```

The project's code is never compiled into Studio. Studio is generic; it
runs the project as a child and talks HTTP. That is what makes one
Studio binary work on any project, and what keeps Studio's own hot reload
(`r` in the terminal that launched it) separate from the project's.

`flutter_static studio` runs `flutter run -d macos -t lib/studio_main.dart`
in this package with three dart-defines: `FLUTTER_STATIC_ROOT` (this
checkout, so Studio can run the CLI from source),
`FLUTTER_STATIC_STUDIO_PROJECT` and `FLUTTER_STATIC_STUDIO_PORT` (the
project's registered port from `~/.flutter_static/ports.jsonl`).

This package's `macos/Runner/*.entitlements` set
`com.apple.security.app-sandbox` to false: a sandboxed app cannot spawn
`dart` or read the project's files.

## Pages and the canvas

Pages come from `/index.json`:

- Each storyline is a page. Its `rows` (new in the index) become rows on
  the canvas, each cell a column with its variants stacked under the
  cell's title, in a phone mockup as the row's frame builder decides.
- Every other id prefix is a page: `buttons/*` is the "buttons" page with
  one card per story. Three-deep ids (`cards/list/empty`) group into rows
  by the middle segment.

Renders are fetched at `?v=<version>` so the catalog's cache serves
repeats, and re-fetched when `/events` reports a new version after a
hot reload. A card keeps its last image while the new one loads, so the
canvas never blanks. A save that does not compile shows the compiler's
message in a drawer under the canvas and leaves the renders alone.

The canvas is a render target: nothing on it is draggable. Arrangement
is the storyline's rows and cells in Dart, which is what the agent reads.

## Tokens

`lib/src/tokens.dart` (pure Dart) parses token files by convention:

- under `lib/` of the project and each path dependency,
- a file named `tokens.dart`, or any Dart file in a `tokens/` directory,
- `static const name = <expression>;` members of classes, with `///`
  comments as descriptions.

Recognised expressions and what Studio offers for them:

| Expression | Kind | Editor |
| --- | --- | --- |
| `Color(0xAARRGGBB)` | color | swatch, HSV picker, alpha, hex field |
| `12`, `12.0` | number | field + slider |
| `BorderRadius.circular(n)`, `Radius.circular(n)` | radius | field + slider |
| `Duration(milliseconds: n)` | duration | field + slider |
| `TextStyle(...)` | text | size, weight, height, letterSpacing, family |
| anything else | other | shown read-only |

A write replaces only the expression's span (or one named argument of a
`TextStyle`), re-reads the file first so concurrent edits survive, and
keeps the literal's style (`12` stays an int, `12.0` a double).

Same parser, three doors:

```text
flutter_static tokens list [--json]                # in the project
flutter_static tokens set AppColors.primary "#E85D2C"
flutter_static tokens set Space.md 16
flutter_static tokens set AppTextStyles.title --arg fontSize 28
GET  http://localhost:<port>/tokens.json           # from the catalog
POST http://localhost:<port>/tokens  {"id": "Space.md", "value": "16"}
```

The catalog's endpoints need the project's runner unsandboxed too
(`macos/Runner/DebugProfile.entitlements`), the same requirement as live
views.

## Specimen widgets

`package:flutter_static/flutter_static.dart` exports story widgets for
putting tokens on the canvas next to the components that use them:

```dart
ColorSwatches(title: 'Colors', colors: {'primary': AppColors.primary, ...})
TypeSpecimen(styles: {'title': AppTextStyles.title, ...})
SpacingScale(values: {'md': Space.md, ...})
RadiusScale(radii: {'lg': Radii.lg, ...})
```

They take the runtime values, so they follow a token edit through hot
reload like any component. `SpecimenStyle.dark` for dark sheets.

## Storyline rows in the index

`/index.json` `lines[].rows[]` now lists each row's title, its cells
(id, title) and each cell's variants with their full story id, so a
client can lay a flow out without re-deriving it from ids.

## Running it on the playground

```text
cd ../studio_playground
flutter_static up                 # or let Studio do it
cd ../flutter_static
dart run flutter_static studio --project ../studio_playground
```

Then open `AppColors` in the sidebar, click `primary`, drag the hue.
`packages/app_ui/lib/src/tokens/colors.dart` changes on every drag
step, the buttons, badges and screens follow within half a second.

## Not yet

- No prompt box. The agent loop is `flutter_static render` / `tokens`
  from a terminal or MCP; Studio is the human's view of the same files.
- Studio shows one project per window.
- The inspector does not show a story's source file: `/index.json` has
  no source locations.
- Editing a text token's colour, or tokens declared outside a class.
