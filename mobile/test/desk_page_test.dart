// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rear_eyes_mobile/eye_scene.dart';
import 'package:rear_eyes_mobile/main.dart';
import 'package:rear_eyes_mobile/remote.dart';

void main() {
  testWidgets('landscape eyes fill the viewport under vertical status labels', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(820, 360);
    tester.view.padding = const FakeViewPadding(left: 28, bottom: 16);
    addTearDown(tester.view.reset);
    final scene = ValueNotifier((EyeMood.thinking, 0));
    final telemetry = ValueNotifier(
      Snapshot(agents: {'Codex': EyeMood.thinking, 'WorkBuddy': EyeMood.done}),
    );
    addTearDown(scene.dispose);
    addTearDown(telemetry.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: DeskPage(scene: scene, telemetry: telemetry, sleepSeconds: 90),
      ),
    );

    final eyes = tester.getRect(find.byType(EyeScene));
    final codex = tester.getTopLeft(find.text('Codex'));
    final workBuddy = tester.getTopLeft(find.text('WorkBuddy'));
    expect(eyes, const Rect.fromLTWH(0, 0, 820, 360));
    expect(codex.dx, greaterThan(28));
    expect(codex.dx, workBuddy.dx);
    expect(codex.dy, lessThan(workBuddy.dy));
    expect(tester.takeException(), isNull);
  });

  testWidgets('fullscreen controls toggle on double tap and auto-hide', (
    tester,
  ) async {
    final scene = ValueNotifier((EyeMood.idle, 0));
    final telemetry = ValueNotifier(Snapshot());
    addTearDown(scene.dispose);
    addTearDown(telemetry.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: DeskPage(scene: scene, telemetry: telemetry, sleepSeconds: 90),
      ),
    );

    const center = Offset(400, 300);
    final exit = find.text('退出全屏').hitTestable();
    final overlays = find.descendant(
      of: find.byType(DeskPage),
      matching: find.byType(AnimatedOpacity),
    );

    Future<void> tap(int startMs) async {
      final gesture = await tester.createGesture();
      await gesture.down(center, timeStamp: Duration(milliseconds: startMs));
      await gesture.up(timeStamp: Duration(milliseconds: startMs + 30));
      await tester.pump();
    }

    void expectControls(bool visible) {
      expect(exit, visible ? findsOneWidget : findsNothing);
      expect(
        tester
            .widgetList<AnimatedOpacity>(overlays)
            .map((item) => item.opacity),
        visible ? [1, 1] : [0, 0],
      );
    }

    expectControls(false);
    await tap(10);
    expectControls(false);

    final drag = await tester.createGesture();
    await drag.down(center, timeStamp: const Duration(milliseconds: 130));
    await drag.moveBy(
      const Offset(80, 0),
      timeStamp: const Duration(milliseconds: 160),
    );
    await drag.up(timeStamp: const Duration(milliseconds: 190));
    await tester.pump();
    expectControls(false);

    await tap(230);
    expectControls(false);
    await tap(360);
    expectControls(true);

    await tap(500);
    expectControls(true);
    await tap(630);
    expectControls(false);

    await tap(770);
    await tap(900);
    expectControls(true);

    await tester.pump(const Duration(seconds: 15));
    await tester.pump(const Duration(milliseconds: 220));
    expectControls(false);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
