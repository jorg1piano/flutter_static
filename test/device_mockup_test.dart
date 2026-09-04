import 'package:flutter/widgets.dart';
import 'package:flutter_static/flutter_static.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the iPad is a selectable tablet device', () {
    const ipad = DeviceSpec.ipadPro11;

    expect(ipad.formFactor, DeviceFormFactor.tablet);
    expect(ipad.screenSize, const Size(834, 1194));
    expect(ipad.hasCutout, isFalse);
    expect(DeviceSpec.byName('ipad-pro-11'), same(ipad));
    expect(DeviceSpec.all, contains(same(ipad)));
  });

  testWidgets('the iPad mockup lays out an iPad-sized screen', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1600);
    addTearDown(tester.view.reset);
    late MediaQueryData screenMedia;

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: DeviceMockup(
              spec: DeviceSpec.ipadPro11,
              keyboard: true,
              statusBar: true,
              child: Builder(
                builder: (context) {
                  screenMedia = MediaQuery.of(context);
                  return const SizedBox.expand(key: Key('screen'));
                },
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(DeviceMockup)), const Size(932, 1286));
    expect(
      tester.getSize(find.byKey(const Key('screen'))),
      const Size(834, 1194),
    );
    expect(screenMedia.size, const Size(834, 1194));
    expect(screenMedia.padding, const EdgeInsets.only(top: 24));
    expect(screenMedia.viewPadding, const EdgeInsets.only(top: 24, bottom: 20));
    expect(screenMedia.viewInsets, const EdgeInsets.only(bottom: 398));
  });
}
