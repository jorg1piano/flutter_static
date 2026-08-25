import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'phone_mockup.dart';

class Story {
  const Story(this.id, this.builder);

  final String id;
  final Widget Function() builder;
}

/// Wraps a storyline variant in whatever should surround it on the page.
typedef FrameBuilder = Widget Function(BuildContext context, Widget child);

/// The default frame: the variant as a screen inside a [PhoneMockup] of
/// the device the page asked for ([DeviceScope]).
Widget phoneMockupFrame(BuildContext context, Widget child) => PhoneMockup(
  spec: DeviceScope.of(context),
  keyboard: DeviceScope.keyboardOf(context),
  statusBar: DeviceScope.statusBarOf(context),
  child: child,
);

/// The default frame with the keyboard up, for a variant that shows a
/// focused field. Use as a cell's frameBuilder.
Widget phoneMockupKeyboardFrame(BuildContext context, Widget child) =>
    PhoneMockup(
      spec: DeviceScope.of(context),
      keyboard: true,
      statusBar: DeviceScope.statusBarOf(context),
      child: child,
    );

/// No frame: the variant at its own size, like a gallery card.
Widget bareFrame(BuildContext _, Widget child) => child;

/// A flow laid out as a column of rows. Each row is a sequence of [Cell]s
/// (a screen, a pop-up, ...), and each cell stacks its variants.
///
/// Every variant is a regular story with the id
/// `<line>/<cell>/<variant>`, so it renders, lists and mounts like any
/// other; the line page only adds the layout.
class Storyline {
  const Storyline(
    this.id, {
    required this.rows,
    this.title,
    this.knobs = const [],
  });

  /// Two segments, group first: `flows/onboarding`.
  final String id;
  final String? title;
  final List<StorylineRow> rows;

  /// The line's switches, mock data mostly; see [Knob]. The line page
  /// shows them next to the device toggle, and nothing when this is empty.
  final List<Knob<Object?>> knobs;

  List<Story> get stories => [
    for (final row in rows)
      for (final cell in row.cells)
        for (final variant in cell.variants)
          Story('$id/${cell.id}/${variant.id}', () {
            final frame = cell.frameBuilder ?? row.frameBuilder;
            return Builder(
              builder: (context) => frame(context, variant.builder()),
            );
          }),
  ];
}

class StorylineRow {
  const StorylineRow(
    this.title, {
    required this.cells,
    this.frameBuilder = phoneMockupFrame,
  });

  final String title;
  final List<Cell> cells;

  /// Applied to every variant in the row; [phoneMockupFrame] unless told
  /// otherwise, [bareFrame] for widgets shown as they are.
  final FrameBuilder frameBuilder;
}

class Cell {
  const Cell(this.id, {required this.variants, this.title, this.frameBuilder});

  final String id;
  final String? title;

  /// The first variant is the canonical state; the rest stack under it.
  final List<Story> variants;

  /// Overrides the row's frame for this cell.
  final FrameBuilder? frameBuilder;
}

/// A switch for a whole storyline: which mock data (a fake backend, a
/// seeded feed, a user) every screen in the flow runs on. Variants stack
/// on the page and show states side by side; a knob changes all of them
/// at once. The line page shows one row of buttons per knob, next to the
/// device toggle, and only for lines that declare knobs.
///
/// A variant reads the chosen value with [of]:
///
/// ```dart
/// final backend = Knob('backend', title: 'Data', options: [
///   KnobOption('empty', FakeBackend.empty(), title: 'Tom'),
///   KnobOption('busy', FakeBackend.busy(), title: 'Tre pakker'),
/// ]);
/// Story('home', () => Builder(builder: (c) => HomeScreen(backend.of(c))))
/// ```
///
/// Renders and live views take `?k.<knob>=<option>`; the first option is
/// the default. Build knobs inside `storyline()` like everything else, so
/// hot reload reaches their values.
class Knob<T> {
  const Knob(this.id, {required this.options, this.title});

  /// A slug: it goes in the URL.
  final String id;
  final String? title;

  /// The first option is the default.
  final List<KnobOption<T>> options;

  /// The value of the option the page chose, or the first option's.
  T of(BuildContext context) {
    final chosen = KnobScope.chosenOf(context)[id];
    for (final option in options) {
      if (option.id == chosen) return option.value;
    }
    return options.first.value;
  }
}

class KnobOption<T> {
  const KnobOption(this.id, this.value, {this.title});

  /// A slug: it goes in the URL.
  final String id;
  final String? title;
  final T value;
}

/// The page's knob choices, option id by knob id; [Knob.of] reads them.
/// Absent knobs are at their default.
class KnobScope extends InheritedWidget {
  const KnobScope({super.key, required this.chosen, required super.child});

  final Map<String, String> chosen;

  static Map<String, String> chosenOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<KnobScope>()?.chosen ??
      const {};

  @override
  bool updateShouldNotify(KnobScope old) => !mapEquals(old.chosen, chosen);
}

/// Subclass this and implement [build] to define your stories.
///
/// It must be a class method, not a stored closure: hot reload never re-runs
/// `main()`, and a closure created by the old `main()` keeps executing the
/// code it was created with. Method calls dispatch through the class, whose
/// code is reliably replaced on reload, so [build] is re-evaluated fresh on
/// every request and every reload.
abstract class Stories {
  const Stories();

  List<Story> build();

  /// Flows; their variants join [build]'s stories in [all].
  List<Storyline> storylines() => const [];

  /// The platform the stories run as, whatever the catalog's host is.
  ///
  /// Null keeps the host's. A catalog of iPhone screens sets
  /// [TargetPlatform.iOS]: scrollables then bounce, Material controls
  /// keep phone density instead of the desktop's compact one, and
  /// `Theme.of` reports iOS, so a Mac host stops getting those subtly
  /// wrong. Applied through [debugDefaultTargetPlatformOverride], which
  /// holds in the debug build the catalog runs as.
  TargetPlatform? get platform => null;

  /// Every story: each storyline's variants, then [build]'s stories.
  ///
  /// Flows first, so they lead the gallery: a storyline is what the parts
  /// under it add up to, and the page reads top-down.
  List<Story> all() => [
    for (final line in storylines()) ...line.stories,
    ...build(),
  ];
}
