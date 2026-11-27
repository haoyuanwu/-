// ignore: deprecated_member_use
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rear_eyes_mobile/desk_voice_feedback.dart';
import 'package:rear_eyes_mobile/design.dart';
import 'package:rear_eyes_mobile/eye_scene.dart';
import 'package:rear_eyes_mobile/interaction.dart';
import 'package:rear_eyes_mobile/main.dart';
import 'package:rear_eyes_mobile/remote.dart';
import 'package:rear_eyes_mobile/status_strip.dart';

void main() {
  testWidgets(
    'landscape streams at a reading pace and dismisses after speech',
    (tester) async {
      final interaction = RobotInteraction(RemoteClient(), () => null)
        ..phase = InteractionPhase.answering
        ..turnId = 'first-turn'
        ..reply = '一二三四五六七八';
      addTearDown(interaction.dispose);
      Future<void> showControl() => tester.pumpWidget(
        MaterialApp(
          home: ListenableBuilder(
            listenable: interaction,
            builder: (_, _) =>
                Center(child: DeskVoiceControl(interaction, onPressed: () {})),
          ),
        ),
      );
      await showControl();
      final wholeReply = find.text(interaction.reply, findRichText: true);
      expect(wholeReply, findsNothing);
      expect(find.text('一'), findsOneWidget);
      expect(tester.widget<Text>(find.text('一')).style?.color, primaryInk);
      expect(find.byType(Text), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 700));
      expect(wholeReply, findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      expect(wholeReply, findsOneWidget);

      interaction
        ..phase = InteractionPhase.idle
        ..spokenText = interaction.reply
        ..notifyListeners();
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      expect(wholeReply, findsOneWidget);

      interaction
        ..spokenText = null
        ..notifyListeners();
      await tester.pump();
      await tester.pump(const Duration(seconds: 9));
      expect(wholeReply, findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 450));
      expect(wholeReply, findsNothing);
      expect(interaction.reply, '一二三四五六七八');

      interaction
        ..spokenText = interaction.reply
        ..notifyListeners();
      await tester.pump(const Duration(milliseconds: 500));
      expect(wholeReply, findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await showControl();
      expect(wholeReply, findsNothing);

      interaction
        ..spokenText = null
        ..phase = InteractionPhase.answering
        ..turnId = 'new-turn'
        ..reply = '下一条回复'
        ..notifyListeners();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.text('下一条回复'), findsOneWidget);
    },
  );

  testWidgets(
    'landscape shows new reminders without restoring a previous reply',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(760, 300);
      addTearDown(tester.view.reset);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final events = MethodChannel(RobotInteraction.events.name);
      String? utteranceId;
      messenger.setMockMethodCallHandler(RobotInteraction.bridge, (call) async {
        if (call.method == 'speak') {
          utteranceId = (call.arguments as Map)['id'] as String?;
        }
        return switch (call.method) {
          'capabilities' => {'notifications': true, 'speech': true},
          'notificationAccess' => true,
          'notificationAppIcon' when call.arguments == 'test.app' =>
            base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+W3ioAAAAASUVORK5CYII=',
            ),
          _ => null,
        };
      });
      messenger.setMockMethodCallHandler(events, (_) async => null);
      addTearDown(() {
        messenger.setMockMethodCallHandler(RobotInteraction.bridge, null);
        messenger.setMockMethodCallHandler(events, null);
      });

      final interaction = RobotInteraction(RemoteClient(), () => null);
      final scene = ValueNotifier((EyeMood.idle, 0));
      final telemetry = ValueNotifier(Snapshot());
      addTearDown(interaction.dispose);
      addTearDown(scene.dispose);
      addTearDown(telemetry.dispose);
      final initialization = interaction.initialize();
      await tester.pump();
      await initialization;
      interaction.readNotices = true;
      interaction.reply = '已有对话回复';
      await tester.pumpWidget(
        MaterialApp(
          home: DeskPage(
            scene: scene,
            telemetry: telemetry,
            sleepSeconds: 90,
            interaction: interaction,
          ),
        ),
      );

      await messenger.handlePlatformMessage(
        events.name,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'type': 'notification',
          'app': '测试应用',
          'package': 'test.app',
          'title': '横屏新提醒',
          'text': '通知内容',
        }),
        (_) {},
      );
      await tester.pump();

      expect(interaction.spokenText, isNull);
      expect(interaction.mood, isNull);
      expect(
        tester.widget<EyeScene>(find.byType(EyeScene)).noticeCue,
        isNotNull,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      expect(find.byIcon(Icons.notifications_outlined), findsNothing);
      final notice = find.text('横屏新提醒');
      expect(notice.hitTestable(), findsOneWidget);
      expect(find.text('已有对话回复'), findsNothing);
      await tester.pump(const Duration(milliseconds: 1200));
      expect(interaction.spokenText, '你在测试应用收到一条消息，内容是：通知内容');
      expect(interaction.speechPlaying, isFalse);
      expect(utteranceId, isNotNull);
      await messenger.handlePlatformMessage(
        events.name,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'type': 'speechStarted',
          'id': utteranceId,
        }),
        (_) {},
      );
      await tester.pump();
      expect(interaction.speechPlaying, isTrue);
      expect(tester.widget<EyeScene>(find.byType(EyeScene)).mood, EyeMood.idle);
      expect(tester.widget<EyeScene>(find.byType(EyeScene)).speaking, isFalse);
      final buttonPaint = tester.renderObject<RenderRepaintBoundary>(
        find
            .descendant(
              of: find.byTooltip('对话'),
              matching: find.byType(RepaintBoundary),
            )
            .first,
      );
      Future<List<int>> mouthFrame() async {
        final image = buttonPaint.toImageSync();
        try {
          final bytes = await tester.runAsync(() => image.toByteData());
          return bytes!.buffer.asUint8List();
        } finally {
          image.dispose();
        }
      }

      final firstMouth = await mouthFrame();
      await tester.pump(const Duration(milliseconds: 90));
      expect(await mouthFrame(), isNot(firstMouth));
      expect(tester.widget<EyeScene>(find.byType(EyeScene)).noticeCue, isNull);
      expect(notice, findsOneWidget);
      await interaction.muteCurrent();
      await tester.pump();
      expect(interaction.speechPlaying, isFalse);

      await tester.tap(notice);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      final close = find.byTooltip('关闭');
      expect(close, findsOneWidget);
      await messenger.handlePlatformMessage(
        events.name,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'type': 'expression',
          'expression': 'IDEA',
        }),
        (_) {},
      );
      expect(interaction.mood, EyeMood.idea);
      await tester.pump(const Duration(seconds: 10));
      expect(interaction.mood, isNull);
      expect(interaction.notice?.title, '横屏新提醒');
      expect(close, findsOneWidget);

      await tester.tap(close);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(notice.hitTestable(), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('the homepage eye preview allows vertical scrolling', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ListView(
          controller: scroll,
          children: const [
            SizedBox(
              height: 240,
              child: EyeScene(mood: EyeMood.idle, allowVerticalScroll: true),
            ),
            SizedBox(height: 1200),
          ],
        ),
      ),
    );
    await tester.drag(find.byType(EyeScene), const Offset(0, -100));
    await tester.pump(const Duration(milliseconds: 50));
    expect(scroll.offset, greaterThan(0));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'fullscreen speech stays with the eyes and sends the transcript',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final nativeActions = <String>[];
      messenger.setMockMethodCallHandler(RobotInteraction.bridge, (call) async {
        nativeActions.add(call.method);
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

      final mic = find.byTooltip('对话');
      final screen = tester.getRect(find.byType(DeskPage));
      final controlCenter = tester.getCenter(mic);
      expect(controlCenter.dx, screen.center.dx);
      expect(controlCenter.dy, greaterThan(screen.center.dy));
      expect(find.text('对话'), findsNothing);
      await tester.tap(mic);
      await tester.pump();
      expect(find.byType(DeskVoiceControl), findsOneWidget);
      expect(find.byIcon(Icons.mic_none_rounded), findsNothing);
      expect(find.text('正在聆听…'), findsOneWidget);
      final stop = find.byTooltip('结束录音');
      expect(
        find.descendant(
          of: stop,
          matching: find.byWidgetPredicate(
            (widget) => widget is CustomPaint && !widget.size.isEmpty,
          ),
        ),
        findsOneWidget,
      );
      expect(stop, findsOneWidget);
      expect(find.text('结束录音'), findsNothing);
      expect(tester.getCenter(stop), controlCenter);
      expect(find.text('和 Robot Eyes 对话'), findsNothing);
      expect(
        tester.widget<EyeScene>(find.byType(EyeScene)).mood,
        EyeMood.focus,
      );

      await messenger.handlePlatformMessage(
        events.name,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'type': 'speechDetected',
        }),
        (_) {},
      );
      await tester.pump();
      final detected = tester.widget<EyeScene>(find.byType(EyeScene));
      expect(detected.speechActivity, 1);
      expect(detected.voiceLevel, 0);

      await messenger.handlePlatformMessage(
        events.name,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'type': 'speechLevel',
          'level': .64,
        }),
        (_) {},
      );
      await tester.pump();
      expect(tester.widget<EyeScene>(find.byType(EyeScene)).voiceLevel, .64);

      expect(nativeActions, contains('startListening'));
      await tester.tap(stop);
      await tester.pump();
      expect(nativeActions, contains('cancelListening'));
      expect(nativeActions, isNot(contains('stopListening')));
      expect(find.byTooltip('取消识别'), findsNothing);
      expect(interaction.error, isNull);

      await tester.tap(mic);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 650));
      await tester.tap(stop);
      await tester.pump();
      expect(nativeActions, contains('stopListening'));
      final processing = find.byTooltip('取消识别');
      expect(tester.getCenter(processing), controlCenter);
      final recognizingEyes = tester.widget<EyeScene>(find.byType(EyeScene));
      expect(recognizingEyes.mood, EyeMood.thinking);
      expect(recognizingEyes.voiceLevel, isNull);
      await tester.tap(processing);
      await tester.pump();
      expect(nativeActions, contains('cancelListening'));
      expect(tester.getCenter(mic), controlCenter);

      await messenger.handlePlatformMessage(
        events.name,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'type': 'speech',
          'text': '已取消的识别结果',
          'final': true,
        }),
        (_) {},
      );
      await tester.pump();
      expect(interaction.error, isNull);
      expect(interaction.draft, isEmpty);

      await tester.tap(mic);
      await tester.pump();
      await messenger.handlePlatformMessage(
        events.name,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'type': 'speechError',
          'text': '麦克风不可用',
        }),
        (_) {},
      );
      await tester.pump();
      expect(find.text('麦克风不可用'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('麦克风不可用'), findsNothing);
      expect(tester.widget<EyeScene>(find.byType(EyeScene)).mood, EyeMood.idle);

      await tester.tap(mic);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 650));
      await tester.tap(stop);
      await tester.pump();

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
      expect(interaction.error, contains('请先配对电脑'));
      expect(find.text('测试全屏说话'), findsOneWidget);
      expect(find.textContaining('请先配对电脑'), findsOneWidget);
      expect(find.byTooltip('重试'), findsOneWidget);
      expect(
        tester.widget<EyeScene>(find.byType(EyeScene)).mood,
        EyeMood.error,
      );
      expect(tester.getCenter(find.byTooltip('重试')), controlCenter);
      expect(find.byType(DeskPage), findsOneWidget);
      final starts = nativeActions
          .where((action) => action == 'startListening')
          .length;
      await tester.pump(const Duration(seconds: 4));
      expect(find.textContaining('请先配对电脑'), findsNothing);
      expect(tester.widget<EyeScene>(find.byType(EyeScene)).mood, EyeMood.idle);
      expect(find.text('测试全屏说话'), findsOneWidget);
      await tester.tap(find.byTooltip('重试'));
      await tester.pump();
      expect(
        nativeActions.where((action) => action == 'startListening'),
        hasLength(starts),
      );
      expect(interaction.draft, '测试全屏说话');
    },
  );

  testWidgets(
    'the fullscreen waveform responds to volume and speech detection',
    (tester) async {
      final voice = ValueNotifier((0.0, 0));
      final boundary = GlobalKey();
      addTearDown(voice.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: RepaintBoundary(
              key: boundary,
              child: SizedBox(
                width: 375,
                height: 210,
                child: ValueListenableBuilder(
                  valueListenable: voice,
                  builder: (_, value, _) => EyeScene(
                    mood: EyeMood.focus,
                    fullScreen: true,
                    voiceLevel: value.$1,
                    speechActivity: value.$2,
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      Future<int> waveHeight() async {
        final box =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final frame = box.toImageSync();
        try {
          final bytes = await tester.runAsync(
            () => frame.toByteData(format: ui.ImageByteFormat.rawRgba),
          );
          final rgba = bytes!.buffer.asUint8List();
          var height = 0;
          for (var y = 140; y < 175; y++) {
            final pixel = (y * frame.width + 187) * 4;
            if (rgba[pixel + 2] > 140 && rgba[pixel + 1] > 100) height++;
          }
          return height;
        } finally {
          frame.dispose();
        }
      }

      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 300));
      final quiet = await waveHeight();
      expect(quiet, greaterThan(0));
      voice.value = (.81, 0);
      for (var index = 0; index < 6; index++) {
        await tester.pump(const Duration(milliseconds: 45));
      }
      expect(await waveHeight(), greaterThan(quiet + 3));

      voice.value = (0, 0);
      for (var index = 0; index < 14; index++) {
        await tester.pump(const Duration(milliseconds: 45));
      }
      expect(await waveHeight(), closeTo(quiet, 2));
      voice.value = (0, 1);
      for (var index = 0; index < 4; index++) {
        await tester.pump(const Duration(milliseconds: 45));
      }
      expect(await waveHeight(), greaterThan(quiet + 3));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'the reading mouth moves, rests on mute and honors reduced motion',
    (tester) async {
      final boundary = GlobalKey();
      Future<void> show({required bool speaking, bool reduceMotion = false}) {
        return tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduceMotion),
              child: Center(
                child: RepaintBoundary(
                  key: boundary,
                  child: SizedBox(
                    width: 375,
                    height: 210,
                    child: EyeScene(
                      mood: EyeMood.hello,
                      fullScreen: true,
                      speaking: speaking,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }

      Future<int> mouthPixels() async {
        final box =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final frame = box.toImageSync();
        try {
          final bytes = await tester.runAsync(
            () => frame.toByteData(format: ui.ImageByteFormat.rawRgba),
          );
          final rgba = bytes!.buffer.asUint8List();
          var count = 0;
          for (var y = 149; y < 180; y++) {
            for (var x = 159; x < 216; x++) {
              final pixel = (y * frame.width + x) * 4;
              if (rgba[pixel] > 110 && rgba[pixel + 1] > 70) count++;
            }
          }
          return count;
        } finally {
          frame.dispose();
        }
      }

      await show(speaking: true);
      final samples = <int>{};
      for (var index = 0; index < 12; index++) {
        await tester.pump(const Duration(milliseconds: 40));
        samples.add(await mouthPixels());
      }
      expect(samples.where((count) => count > 100).length, greaterThan(1));

      await show(speaking: true, reduceMotion: true);
      await tester.pump(const Duration(milliseconds: 30));
      final still = await mouthPixels();
      expect(still, greaterThan(100));
      await tester.pump(const Duration(milliseconds: 140));
      expect(await mouthPixels(), still);

      await show(speaking: false);
      for (var index = 0; index < 8; index++) {
        await tester.pump(const Duration(milliseconds: 45));
      }
      expect(await mouthPixels(), 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('the latest AI expression waits for the drag release pose', (
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

    int donePixels(List<int> rgba) {
      var count = 0;
      for (var i = 0; i < rgba.length; i += 4) {
        if (rgba[i + 1] > rgba[i] + 24 && rgba[i + 1] > rgba[i + 2] + 24) {
          count++;
        }
      }
      return count;
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
    expect(donePixels(released), 0);
    await tester.pump(const Duration(milliseconds: 879));
    expect(donePixels(await pixels()), 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(donePixels(await pixels()), greaterThan(100));

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
