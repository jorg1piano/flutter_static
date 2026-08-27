# Monetizing Flutter Static Studio

Notes from a research session on 2026-08-27. The question: Studio's Dart has to
land on the customer's disk to compile into their app, so what is left to sell,
and how is it enforced?

## The constraint

Dart has no binary package format. A Flutter package compiles from source into
the host app. Three facts pin this down:

- `dart compile exe --obfuscate` is not supported
  ([dart-lang/sdk#56758](https://github.com/dart-lang/sdk/issues/56758)).
- Shipping `.dill` instead of source for a package was requested and closed
  ([dart-lang/sdk#62508](https://github.com/dart-lang/sdk/issues/62508)).
- pub has no closed-source distribution story
  ([dart-lang/pub-dev#3887](https://github.com/dart-lang/pub-dev/issues/3887)).

So Studio's source reaches the buyer. Every option below is about making that
not matter.

One thing already helps. `studio-host` generates a host pubspec with
`flutter_static: path: <path>` (`bin/flutter_static.dart:1317`), so the Studio
sources never have to enter the customer's repo. But `setup` does add
`flutter_static` to the customer's own pubspec (`bin/flutter_static.dart:1139`),
because `dart run flutter_static render` runs from the project. That matters for
distribution, below.

## Options

### A. Source-available licence plus per-seat key

Not open source. FSL or PolyForm Perimeter, or a plain commercial EULA with a
non-compete clause. Don't publish on pub.dev.

Distribution: a private `hosted:` registry (self-hosted unpub, Cloudsmith,
Artifactory) with per-seat `dart pub token add`. Revoking a token fails their
next `pub get`. That is the one enforcement mechanism here that a customer
cannot patch out, because it runs on your server.

Runtime: an Ed25519-signed lease verified offline at startup, refreshed online
every few weeks, bound to a machine fingerprint. Keylight, LicenseSeat and Zamok
sell this; Polar or Lemon Squeezy takes the money.

Precedent: DCM is a Dart tool with exactly this problem and sells per-seat
licences with activation keys.

Cost: about a week. This is the baseline.

### B. Split the binary

The catalog runtime stays open. Studio becomes a separate signed macOS app
talking to it over the HTTP API that already exists. Then Studio ships AOT and
obfuscated, with no source at all.

Cost: live-mounted cells become streamed frames plus forwarded pointer events,
and token writes move behind the API. The coupling is concentrated (canvas.dart
mounts `story.builder()` in one place, controller.dart holds 32 of the file and
process calls), so the refactor is bounded. But live mounting is what makes the
canvas good, and this trades it away.

Do this only if piracy is measurably costing money.

### C. Open core with a hosted tier

Widgetbook's model: the package is free, the money is in hosted golden review on
pull requests, team token sync, snapshot storage. Nothing to crack because the
value is not on disk.

Slowest to revenue and it means running a service. Worth starting sooner than it
first looks, given how thin D turned out to be.

### D. Move what can't be copied to the server

Originally scoped as three things. Only one holds up.

- **The prompt and skill library.** `controller.agentContext()`
  (`lib/src/studio/controller.dart:306`) plus the skill files that drive the
  build loops. It is the paragraph Studio hands the agent: where the catalog
  runs, which commands verify a change, that tokens and components come before
  one-off values, what a backticked story id or `file:line:col` means. That text
  is the accumulated knowledge of what makes an agent produce decent widgets,
  it changes constantly, and it is a string. Serve it versioned from your API
  and a cracked client runs on a stale copy.
- **Design-to-widget.** Does not exist in the repo. It is the skill loop
  (`flutter-static-new-design`, `flutter-static-compose`) plus
  `docs/design-iteration-notes.md`, run from Claude Code. If it becomes a Studio
  feature, dropping a design image on the canvas and getting stories back, it is
  an LLM call you pay for, so it gets metered and hosted anyway. A feature to
  build, not an asset to move.
- **Token extraction.** Retracted. `lib/src/tokens.dart` is 622 lines of parsing
  over Dart source with write-back into the exact span. It runs offline in
  milliseconds and the CLI imports it directly. Putting it behind a network call
  would slow `tokens set`, break it offline, and protect a parser someone could
  rewrite in a weekend.

So D is one asset, not three. It composes with A for almost no work, but it is
not a moat on its own.

### Rejected

- **Mac App Store.** Requires App Sandbox. Studio turns the sandbox off in
  `macos/Runner/*.entitlements` to read and write project source and spawn PTYs.
  Direct distribution with Developer ID and notarization instead.
- **Delivering the UI as rfw blobs after login.** Would satisfy the in-process
  requirement, but means rewriting 13k lines declaratively.

## Obfuscation

Cheaper than it first appears. [ljmatan/obfuscator](https://github.com/ljmatan/obfuscator)
does source-level Dart obfuscation with the analyzer: renames declarations and
their references, keeps names that are constrained (overrides, interface
members, conditional imports), strips comments, follows transitive path
dependencies from one entry point, emits the rename mapping. A publish step, not
a project.

What it buys: it raises the cost of lifting the implementation, and it strips
the comments. In this repo the comments are the design document. The header of
`lib/src/tokens.dart` explains the whole token model. The generated host pubspec
carries a paragraph on why `flutter_static_story` gets pinned. `agentContext()`
is a distilled record of what makes an agent produce good widgets. Most of the
benefit is comment stripping, because deleted prose cannot be recovered.

What it does not buy: protection for the licence check. That is one call in a
known place, and the traffic to your licence server points at it whatever the
identifiers are called. It also costs support time, since customer stack traces
come back mangled and you keep the mapping file per released version.

The 2026 caveat: handing obfuscated Dart to an LLM and asking it to name things
and explain the architecture works well. Renaming buys less against that than it
did three years ago.

The trade to weigh: obfuscation stops customers reading and debugging into the
package. For a tool aimed at people who like reading code, that has a cost.

## Recommendation

1. A now. Private registry with revocable per-seat tokens, commercial licence,
   signed offline lease. Plan for every developer and CI job on the customer's
   side needing a token, because `setup` puts `flutter_static` in their pubspec.
2. The obfuscator as a publish step, if the comment stripping is worth the
   support tax. Optional.
3. D folded into A: serve the prompt and skill library from the API, versioned.
4. C when there is a team story worth hosting.
5. B only if piracy shows up in the numbers.

Keep `flutter_static_story` open under MIT regardless. Customer story files
import it, it has to be readable and forkable, and it is what gets the tool into
repositories.

## Sources

- [DCM pricing](https://dcm.dev/pricing/)
- [Widgetbook pricing](https://www.widgetbook.io/pricing)
- [dart compile](https://dart.dev/tools/dart-compile)
- [Licensing platforms for macOS apps](https://keylight.dev/best-licensing-for-macos-apps/)
- [ljmatan/obfuscator](https://github.com/ljmatan/obfuscator)
