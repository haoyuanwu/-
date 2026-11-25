// ignore: deprecated_member_use
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rear_eyes_mobile/desk_voice_feedback.dart';
import 'package:rear_eyes_mobile/eye_scene.dart';
import 'package:rear_eyes_mobile/interaction.dart';
import 'package:rear_eyes_mobile/main.dart';
import 'package:rear_eyes_mobile/remote.dart';
import 'package:rear_eyes_mobile/status_strip.dart';

void main() {
  testWidgets(
    'fullscreen speech stays with the eyes and sends the transcript',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(RobotInteraction.bridge, (call) async {
        return call.method == 'capabilities' ? {'speech': true} : null;
      });
      const events = MethodChannel('com.reareyes/interactionEvents');
      messenger.setMockMethodCallHandler(events, (_) async => null);
      final interaction = RobotInteraction(RemoteClient(), () => null);
      final scene = ValueNotifier((EyeMood.idle, 0));
      final telemetry = ValueNotifier(Snapshot());
      addTearDown(() {
        interaction.dispose();
        scene.dispose();
        telemetry.dispose();
        messenger.setMockMethodCallHandler(RobotInteraction.bridge, null);
        messenger.setMockMethodCallHandler(events, null);
      });
      interaction.addListener(() {
        scene.value = (interaction.mood ?? EyeMood.idle, scene.value.$2 + 1);
      });
      final initialization = interaction.initialize();
      await tester.pump();
      await initialization;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: DeskPage(
              scene: scene,
              telemetry: telemetry,
              sleepSeconds: 90,
              interaction: interaction,
            ),
          ),
        ),
      );

      final mic = find.byTooltip('说话');
      final screen = tester.getRect(find.byType(DeskPage));
      expect(tester.getCenter(mic).dx, greaterThan(screen.center.dx));
      expect(tester.getCenter(mic).dy, greaterThan(screen.center.dy));
      expect(find.text('说话'), findsNothing);
      await tester.tap(mic);
      await tester.pump();
      expect(find.byType(DeskVoiceFeedback), findsOneWidget);
      expect(find.text('正在聆听'), findsNothing);
      expect(find.byTooltip('结束录音'), findsOneWidget);
      expect(find.text('和 Robot Eyes 对话'), findsNothing);
      expect(
        tester.widget<EyeScene>(find.byType(EyeScene)).mood,
        EyeMood.focus,
      );

      await messenger.handlePlatformMessage(
        events.name,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'type': 'speech',
          'text': '测试全屏说话',
          'final': true,
        }),
        (_) {},
      );
      await tester.pump();
      expect(find.textContaining('请先配对电脑'), findsOneWidget);
      expect(find.byType(DeskPage), findsOneWidget);
    },
  );

  testWidgets('the latest AI expression waits until the drag ends', (
    tester,
  ) async {
    final mood = ValueNotifier(EyeMood.idle);
    final boundary = GlobalKey();
    addTearDown(mood.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Center(
            child: RepaintBoundary(
              key: boundary,
              child: SizedBox(
                width: 375,
                height: 210,
                child: ValueListenableBuilder(
                  valueListenable: mood,
                  builder: (_, value, _) => EyeScene(mood: value),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    Future<List<int>> pixels() async {
      final box =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final frame = box.toImageSync();
      try {
        final bytes = await tester.runAsync(
          () => frame.toByteData(format: ui.ImageByteFormat.rawRgba),
        );
        return bytes!.buffer.asUint8List();
      } finally {
        frame.dispose();
      }
    }

    final finger = await tester.startGesture(
      tester.getCenter(find.byType(EyeScene)),
    );
    await finger.moveBy(const Offset(85, 0));
    await tester.pump(const Duration(milliseconds: 70));
    final tracking = await pixels();

    mood.value = EyeMood.error;
    await tester.pump(const Duration(milliseconds: 70));
    expect(await pixels(), orderedEquals(tracking));
    mood.value = EyeMood.done;
    await tester.pump(const Duration(milliseconds: 70));
    expect(await pixels(), orderedEquals(tracking));

    await finger.up();
    await tester.pump(const Duration(milliseconds: 70));
    final released = await pixels();
    expect(released, isNot(orderedEquals(tracking)));
    var greenPixels = 0;
    for (var i = 0; i < released.length; i += 4) {
      if (released[i + 1] > released[i] + 24 &&
          released[i + 1] > released[i + 2] + 24) {
        greenPixels++;
      }
    }
    expect(greenPixels, greaterThan(100));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'local mode hides badges and connected mode shows only valid usage',
    (tester) async {
      final scene = ValueNotifier((EyeMood.idle, 0));
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final five = UsageWindow(100, now + 3600);
      final expiredWeek = UsageWindow(25, now - 1);
      final telemetry = ValueNotifier(Snapshot(five: five, week: expiredWeek));
      addTearDown(scene.dispose);
      addTearDown(telemetry.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: DeskPage(scene: scene, telemetry: telemetry, sleepSeconds: 90),
        ),
      );
      expect(find.byType(StatusStrip), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      telemetry.value = Snapshot(
        links: ['USB'],
        agents: {'WorkBuddy': EyeMood.thinking},
      );
      await tester.pump();
      expect(find.text('WorkBuddy'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      telemetry.value = Snapshot(links: ['USB'], five: five, week: expiredWeek);
      await tester.pump();
      expect(find.text('0%'), findsOneWidget);
      expect(find.text('本周'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    },
  );

  testWidgets('landscape eyes fill the viewport under vertical status labels', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(820, 360);
    tester.view.padding = const FakeViewPadding(left: 28, top: 12, bottom: 16);
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
    final strip = tester.getTopLeft(find.byType(StatusStrip));
    final codex = tester.getTopLeft(find.text('Codex'));
    final workBuddy = tester.getTopLeft(find.text('WorkBuddy'));
    expect(eyes, const Rect.fromLTWH(0, 0, 820, 360));
    expect(strip, const Offset(44, 28));
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
