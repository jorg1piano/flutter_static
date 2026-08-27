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

Studio runs inside the project's own catalog process. `flutter_static
studio` runs `story/studio_main.dart` the way `run` runs
`story/main.dart`: the same macOS runner, the same file watcher and hot
reload, the same HTTP API on the same port. The only difference is what
the window shows.

```text
The project's catalog process (story/studio_main.dart)
  ├─ runFlutterStudio(const MyStories())
  ├─ the flutter_static HTTP API (renders for agents, /tokens.json, ...)
  ├─ offscreen render pipeline (PNG per story, unchanged)
  └─ the window: Studio
       ├─ sidebar: pages, token groups, live/interact switches
       ├─ canvas: rows of cells, each variant mounted live (or its PNG)
       ├─ inspector: device, status bar, knobs, selected story
       └─ token editors: write the project's Dart files (src/tokens.dart)
```

`story/studio_main.dart` is one line, scaffolded on first use:

```dart
void main() => runFlutterStudio(const MyStories());
```

Because the stories are in-process, the canvas mounts `story.builder()`
directly: animations run, InkWells ripple, lists scroll, fields take
text. A save hot reloads the widgets, the tokens they read and Studio's
chrome together. Nothing goes over HTTP inside Studio; the API stays up
for `flutter_static render` and the browser gallery.

The first `studio` run makes two one-time edits to the project's runner
and says so: the app sandbox off in `macos/Runner/*.entitlements` (Studio
reads and writes the project's source), and a larger default window when
`MainFlutterWindow.swift` is still the template. A catalog runner started
by `up` is stopped first; Studio serves the same port.

## Pages and the canvas

Pages come from the same index the server publishes:

- Each storyline is a page. Its rows become rows on the canvas, each cell
  a column with its variants stacked under the cell's title, in a phone
  mockup as the row's frame builder decides.
- Every other id prefix is a page: `buttons/*` is the "buttons" page with
  one card per story. Three-deep ids (`cards/list/empty`) group into rows
  by the middle segment.

Each card mounts its story live inside the catalog's story environment
(phone-sized media query, default theme, transparent Material), in the
shell the story's first offscreen capture found it needs: at its natural
size, in a phone-sized box, or not at all. A story that only renders in a
real window (`StoryShell.window`) shows its PNG instead; so does any
story while its first capture is pending, and any story switched to
"Render" in the inspector or with the live switch off. Renders keep the
last image while a new one captures, so the canvas never blanks.

Plain clicks on a live card inspect the widget under the pointer and
select it in the widget tree. Hold Option while clicking to interact
with the live widget inside the mockup. Arrangement is the storyline's
rows and cells in Dart, which is what the agent reads; dragging cells
around on the canvas is a Studio-only layout that is not written back.

A storyline page shows an empty slot at each end of every row and an
empty row under the last. Clicking one, or the plus between two
screens, writes a placeholder cell into the storyline's source
(`story/lines/*.dart`, whichever file declares `Storyline('<id>')`):
`Cell('screen-N', title: 'Screen N', variants: [Story('default', () =>
const Placeholder())])`, before the cell in the next occupied slot or
at the row's end, in a new `StorylineRow` for the empty row. The slot
shows the new story once hot reload lands; from there it is a story
like any other, for the agent to fill in. Rows built by a helper
instead of a `StorylineRow(...)` literal are left alone with a note in
the logs. On a plain page the plus appends a `Story('<page>/screen-N',
...)` to `story/stories/<page>.dart`.

## Search

Cmd+K opens a search over pages, screens (storyline cells), stories,
token groups and tokens; the magnifier in the sidebar header does the
same. Type words in any order, arrows move, Enter opens: a page shows,
a story is selected and scrolled to the centre of the canvas, a token
or its group opens in the inspector. Words matching the title rank
above words matching only the id or the location.

## Finding a widget in the source

Click a widget on a live card and the inspector lists the project's
widgets from that one outward, each with the file, line and column it is
constructed at: `Text "Primary"` at
`packages/app_ui/lib/src/button.dart:57:9`, inside `AppButton` at
`story/stories/buttons.dart:13:11`, inside `HStack` at `:10:7`. The
outermost story-file entry is inside the `Story(...)` that defines the
story. The nearest one is selected and outlined on the card; a row
selects another, and so do the arrow keys: the canvas takes focus on a
pick, Up moves to the parent, Down to the child, Escape clears it.
"Copy location" copies `file:line:column`; "Open in
editor" runs `code -g file:line:column`, or whatever
`FLUTTER_STATIC_EDITOR` names, with `{file}`, `{line}` and `{column}`
placeholders. Hold Option while clicking when you want the click to
reach the live widget instead. With a shell running in the terminal, the
pick also types its location at the cursor in backticks, the way a
render-only card click types the story id, and the Claude launch context
says what such a token means.

The lines come from the widgets themselves. Every debug build compiles
with `--track-widget-creation`, which stamps each widget constructor
call with its source position for the widget inspector; Studio hit
tests the mounted render tree the way the inspector does, walks up the
element chain, and reads the stamps back through the inspector's JSON
(`lib/src/widget_pick.dart`). Nothing in the project has to change, and
the stamps follow hot reload. Widgets built by a helper function land in
the helper's file, which is what the chain shows.

The same walk runs on the offscreen render tree for agents, which see a
PNG and measure pixels on it:

```text
flutter_static inspect buttons/kinds --at 240,80    # widgets under a PNG pixel, nearest first
flutter_static inspect buttons/kinds                # the project's widgets in the render, nested
GET /story/<id>/at.json?x=240&y=80                  # same, as JSON
GET /story/<id>/tree.json
```

Coordinates and bounds are pixels of the 2x PNG `render` writes.
Both take `device`, `status` and `k.<knob>` like the PNG, and wait for
the latest save the same way.

A save that does not compile shows the compiler's message in a drawer
under the canvas and leaves the last good code running.

## Sending the selection to Herdr

Studio is not the only terminal in the room. With Herdr running, the
inspector's "Herdr" section lists its panes and sends the selection into
one. The list is `herdr pane list` filtered to panes with an agent plus
shells in the project, agents in the project first; the refresh icon
re-reads it, and the chosen pane is remembered in
`.dart_tool/flutter_static_studio.json`.

"Type into pane" runs `herdr pane send-text` with one line that stands
on its own, since that terminal has none of Studio's launch context: the
project path, the story, the selected widget with its text and source
line, the project widgets around it, and the render command to check
with. It ends in a space and no Enter, so the request gets typed after
it in the pane. "Prompt agent" runs `herdr agent prompt` instead, which
submits: the same line, with the prompt panel's text appended as
"User request: ..." when there is any. With no widget picked, the line
names the story alone.

The `herdr` binary is `FLUTTER_STATIC_HERDR` when set, else the one on
the PATH, else `~/.local/bin/herdr`. The section reports the CLI's error
when the server is down.

If you want automatic checkpoints while you work, run Studio with
`--snapshots jj` or set `FLUTTER_STATIC_SNAPSHOTS=jj`. After each
save-triggered hot reload or restart succeeds, Studio checks for a JJ
working-copy diff and runs `jj commit -m "flutter_static: hot reload ..."`.
Failed reloads are not snapshotted, and snapshots are off by default.

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

## The terminal

Under the inspector is a terminal (xterm + a pty) running your login
shell in the project. Your agent runs there, whichever it is: Claude
Code interactively, codex, a TUI of your own, with its own permission
prompts, skills and history. Studio does not talk to a model and sends
nothing anywhere; it types into that terminal:

- A click on a story on the canvas types its id at the cursor, in
  backticks: `` `flows/onboarding/welcome/default` ``. Finish the
  sentence and press Enter.
- An Option-click on a widget types its source position the same way:
  `` `story/stories/buttons.dart:13:11` ``, the file, line and column
  that construct it (see "Finding a widget in the source"). Picking
  another row in the inspector's chain types that one.
- The sparkle button types and runs `claude --append-system-prompt
  '<context>'`: where the project is, that the catalog is this live
  process (so never `up`, `run`, `down` or `studio`), how to check work
  (`dart run flutter_static render`, then read the PNG), where tokens
  live and how to edit them, and that backticked ids in the prompt are
  stories and backticked `file:line:column` tokens are widgets the user
  Option-clicked.

Because the shell is a login shell, PATH is your terminal's. The
"new shell" button restarts it; a shell that exits says so.

The canvas AI rectangle prompt runs a one-shot edit command. By default
it uses `codex exec --sandbox workspace-write --approve-for-me {image}
{prompt}`; override it with `FLUTTER_STATIC_ONESHOT`. The
template may contain `{prompt}`, `{promptFile}` or `{image}`. Without
any of them, Studio pipes the prompt file to the command's stdin.

## Storyline rows in the index

`/index.json` `lines[].rows[]` now lists each row's title, its cells
(id, title) and each cell's variants with their full story id, so a
client can lay a flow out without re-deriving it from ids.

## Running it on the playground

```text
cd ../studio_playground
dart run flutter_static studio
```

Then open `AppColors` in the sidebar, click `primary`, drag the hue.
`packages/app_ui/lib/src/tokens/colors.dart` changes on every drag
step, the buttons, badges and screens follow within half a second.

## Not yet

- The terminal is one shell; no tabs.
- One project per Studio process.
- A story whose live layout fails (an `Expanded` under unbounded
  height, say) shows Flutter's error box in its slot; the render
  pipeline's shell detection covers the common cases, not all.
- `/index.json` has no source locations; a story's line is found by
  Option-clicking it (or `inspect`), not listed.
- Option-click works on live cards only; a story shown as its render
  (a window story, "Render" mode) answers through `inspect` instead.
- A pick names the constructor call, not the argument: the line of
  `AppButton(`, not of its `label:`.
- Editing a text token's colour, or tokens declared outside a class.
