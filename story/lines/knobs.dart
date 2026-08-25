import 'package:flutter/material.dart';
import 'package:flutter_static/flutter_static.dart';

/// Knobs demo: one screen on two mock data sets and two users. The line
/// page gets a Data and a Bruker row of buttons after the device toggle.
Storyline storyline() {
  final data = Knob<List<String>>(
    'data',
    title: 'Data',
    options: const [
      KnobOption('empty', [], title: 'Tom'),
      KnobOption('busy', [
        'Pakke til Oslo',
        'Pakke til Bergen',
        'Retur fra Tromsø',
      ], title: 'Tre pakker'),
    ],
  );
  final user = Knob<String>(
    'user',
    title: 'Bruker',
    options: const [KnobOption('guest', 'Gjest'), KnobOption('admin', 'Admin')],
  );
  return Storyline(
    'flows/knobs',
    title: 'Knobs',
    knobs: [data, user],
    rows: [
      StorylineRow(
        'Hjem',
        cells: [
          Cell(
            'home',
            title: 'Hjem',
            variants: [
              Story(
                'default',
                () => Builder(
                  builder: (context) =>
                      _home(user.of(context), data.of(context)),
                ),
              ),
            ],
          ),
        ],
      ),
    ],
  );
}

Widget _home(String user, List<String> items) => Scaffold(
  appBar: AppBar(title: Text('Hei, $user')),
  body: items.isEmpty
      ? const Center(child: Text('Ingenting her'))
      : Column(children: [for (final i in items) ListTile(title: Text(i))]),
);
