import 'package:flutter/material.dart';

import 'theme.dart';

/// A flat button in Studio's chrome. [primary] fills it with the accent.
class StudioButton extends StatelessWidget {
  const StudioButton({
    super.key,
    required this.label,
    this.onTap,
    this.icon,
    this.primary = false,
    this.dense = false,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool primary;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final fg = primary ? const Color(0xFF0E1020) : StudioColors.text;
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: Material(
        color: primary ? StudioColors.accent : StudioColors.raised,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          hoverColor: primary ? Colors.white12 : StudioColors.hover,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: dense ? 8 : 10,
              vertical: dense ? 4 : 6,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 14, color: fg),
                  const SizedBox(width: 6),
                ],
                Text(
                  label,
                  style: StudioText.body.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A row of mutually exclusive choices.
class StudioChips<T> extends StatelessWidget {
  const StudioChips({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelect,
  });

  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T> onSelect;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 4,
    runSpacing: 4,
    children: [
      for (final (value, label) in options)
        Material(
          color: value == selected
              ? StudioColors.accentSoft
              : StudioColors.raised,
          borderRadius: BorderRadius.circular(5),
          child: InkWell(
            onTap: () => onSelect(value),
            borderRadius: BorderRadius.circular(5),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(
                label,
                style: StudioText.body.copyWith(
                  color: value == selected
                      ? StudioColors.accent
                      : StudioColors.muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 6),
    child: Row(
      children: [
        Expanded(child: Text(text.toUpperCase(), style: StudioText.section)),
        ?trailing,
      ],
    ),
  );
}

/// A compact text field for the inspector: commits on submit and on
/// focus loss, so a value never half-applies.
class StudioField extends StatefulWidget {
  const StudioField({
    super.key,
    required this.value,
    required this.onCommit,
    this.width = 72,
    this.mono = true,
    this.enabled = true,
  });

  final String value;
  final ValueChanged<String> onCommit;
  final double width;
  final bool mono;
  final bool enabled;

  @override
  State<StudioField> createState() => _StudioFieldState();
}

class _StudioFieldState extends State<StudioField> {
  late final _controller = TextEditingController(text: widget.value);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(StudioField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && !_focus.hasFocus) {
      _controller.text = widget.value;
    }
  }

  void _commit() {
    if (_controller.text != widget.value) widget.onCommit(_controller.text);
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: widget.width,
    height: 26,
    child: TextField(
      controller: _controller,
      focusNode: _focus,
      enabled: widget.enabled,
      onSubmitted: (_) => _commit(),
      style: widget.mono ? StudioText.mono : StudioText.body,
      cursorColor: StudioColors.accent,
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        filled: true,
        fillColor: StudioColors.sidebar,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(5),
          borderSide: const BorderSide(color: StudioColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(5),
          borderSide: const BorderSide(color: StudioColors.accent),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(5),
          borderSide: const BorderSide(color: StudioColors.border),
        ),
      ),
    ),
  );
}
