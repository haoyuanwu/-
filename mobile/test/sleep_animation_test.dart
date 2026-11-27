import 'dart:ui' as ui;

// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rear_eyes_mobile/eye_scene.dart';
import 'package:rear_eyes_mobile/remote.dart';

void main() {
  for (final reducedMotion in [false, true]) {
    testWidgets('the question mark settles after entering (reduced motion: $reducedMotion)', (
      tester,
    ) async {
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reducedMotion),
            child: Center(
              child: RepaintBoundary(
                key: boundary,
                child: const SizedBox(
                  width: 375,
                  height: 210,
                  child: EyeScene(mood: EyeMood.question),
                ),
              ),
            ),
          ),
        ),
      );

      Future<int> markPixels() async {
        final box = boundary.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
        final image = box.toImageSync();
        try {
          final data = await tester.runAsync(() => image.toByteData());
          var count = 0;
          for (var y = 0; y < 45; y++) {
            for (var x = 235; x < 277; x++) {
              final pixel = (y * 375 + x) * 4;
              if (data!.getUint8(pixel + 3) > 180) count++;
            }
          }
          return count;
        } finally {
          image.dispose();
        }
      }

      await tester.pump(const Duration(milliseconds: 25));
      final early = await markPixels();
      await tester.pump(const Duration(milliseconds: 225));
      final bounce = await markPixels();
      await tester.pump(const Duration(milliseconds: 350));
      final settled = await markPixels();
      if (reducedMotion) {
        expect(early, settled);
        expect(bounce, settled);
      } else {
        expect(early, lessThan(settled));
        expect(bounce, greaterThan(settled));
      }
      expect(settled, greaterThan(50));
      await tester.pump(const Duration(milliseconds: 150));
      expect(await markPixels(), settled);
    });
  }

  testWidgets('single tap plays the full reaction during AI work', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 375,
            height: 210,
            child: EyeScene(
              mood: EyeMood.thinking,
              fullScreen: true,
              conversationActive: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));

    final paint = find.descendant(
      of: find.byType(EyeScene),
      matching: find.byType(CustomPaint),
    );
    final dynamic painter = tester.widget<CustomPaint>(paint.first).painter;
    final dynamic animation = painter.model;
    final Object readingStep = animation.thought;
    final int phase = animation.workTime;
    final Offset heldGaze = animation.gaze;

    final point = tester.getCenter(find.byType(EyeScene)) + const Offset(70, 0);
    final finger = await tester.startGesture(point);
    await tester.pump(const Duration(milliseconds: 80));
    expect(animation.thought, isNull);
    expect(animation.expression, EyeMood.idle);
    await finger.up();
    await tester.pump(const Duration(milliseconds: 950));
    expect((animation.pupil as Offset).dx, greaterThan(0));
    expect(animation.gaze, heldGaze);

    await tester.pump(const Duration(milliseconds: 175));
    expect((animation.gaze as Offset).dx, greaterThan(.12));

    await tester.pump(const Duration(milliseconds: 525));
    expect(animation.pupil, Offset.zero);
    expect(animation.gaze, Offset.zero);
    expect(animation.expression, EyeMood.idle);

    await tester.pump(const Duration(milliseconds: 50));
    expect(animation.expression, EyeMood.question);
    await tester.pump(const Duration(milliseconds: 275));
    final dynamic face = animation.displayed;
    expect(face.left.ry, isNot(face.right.ry));

    await tester.pump(const Duration(milliseconds: 715));
    expect(animation.thought, isNull);
    expect(animation.workTime, phase);

    await tester.pump(const Duration(milliseconds: 16));
    expect(animation.expression, EyeMood.thinking);
    expect(animation.thought, same(readingStep));
    expect(animation.workTime, phase);
    await tester.pump(const Duration(milliseconds: 16));
    expect(animation.workTime, phase + 16);
  });

  testWidgets('completion notification outlasts the smile and work resumes', (
    tester,
  ) async {
    Future<void> show(EyeMood mood) => tester.pumpWidget(
      MaterialApp(
        home: SizedBox.expand(child: EyeScene(mood: mood, fullScreen: true)),
      ),
    );

    await show(EyeMood.done);
    final paint = find.descendant(
      of: find.byType(EyeScene),
      matching: find.byType(CustomPaint),
    );
    final dynamic painter = tester.widget<CustomPaint>(paint.first).painter;
    final dynamic animation = painter.model;
    await tester.pump(const Duration(milliseconds: 150));
    expect(animation.displayed.left.browWidth, 0);
    expect(animation.displayed.right.browWidth, 0);
    await tester.pump(const Duration(milliseconds: 4850));
    expect(animation.displayed.left.browWidth, 0);
    expect(animation.displayed.right.browWidth, 0);
    final notice = find.text('工作完成');
    expect(notice, findsNothing);

    await show(EyeMood.thinking);
    await tester.pump(const Duration(milliseconds: 274));
    expect(notice, findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 410));
    expect(notice, findsOneWidget);
    expect(notice.hitTestable(), findsNothing);
    final int phase = animation.workTime;

    await tester.pump(const Duration(milliseconds: 8589));
    expect(notice, findsOneWidget);
    expect(animation.expression, EyeMood.thinking);
    expect(animation.workTime, greaterThan(phase));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(notice, findsNothing);
  });

  testWidgets('auto sleep counts from idle and resets when work resumes', (
    tester,
  ) async {
    Future<void> show(EyeMood mood) => tester.pumpWidget(
      MaterialApp(home: EyeScene(mood: mood, sleepSeconds: 3)),
    );

    await show(EyeMood.done);
    final paint = find.descendant(
      of: find.byType(EyeScene),
      matching: find.byType(CustomPaint),
    );
    final dynamic painter = tester.widget<CustomPaint>(paint.first).painter;
    final dynamic animation = painter.model;

    await tester.pump(const Duration(seconds: 10));
    expect(animation.expression, EyeMood.done);
    await show(EyeMood.idle);
    await tester.pump(const Duration(seconds: 2));
    expect(animation.sleeping, false);

    await show(EyeMood.thinking);
    await tester.pump(const Duration(seconds: 4));
    expect(animation.expression, EyeMood.thinking);
    await show(EyeMood.idle);
    await tester.pump(const Duration(milliseconds: 2990));
    expect(animation.sleeping, false);
    await tester.pump(const Duration(milliseconds: 10));
    expect(animation.expression, EyeMood.sleep);
  });

  testWidgets('ending a conversation restarts the sleep countdown', (
    tester,
  ) async {
    final boundary = GlobalKey();
    Future<void> show(EyeMood mood, {bool talking = false}) =>
        tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: Center(
                child: RepaintBoundary(
                  key: boundary,
                  child: SizedBox(
                    width: 375,
                    height: 210,
                    child: EyeScene(
                      mood: mood,
                      sleepSeconds: 3,
                      conversationActive: talking,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

    Future<List<int>> image() async {
      final box =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final frame = box.toImageSync();
      try {
        final data = await tester.runAsync(() => frame.toByteData());
        return data!.buffer.asUint8List();
      } finally {
        frame.dispose();
      }
    }

    await show(EyeMood.sleep);
    await tester.pump(const Duration(milliseconds: 16));
    final asleep = await image();

    await show(EyeMood.focus, talking: true);
    await tester.pump(const Duration(seconds: 4));
    expect(await image(), isNot(asleep));

    await show(EyeMood.sleep);
    await tester.pump(const Duration(milliseconds: 16));
    final awake = await image();
    expect(awake, isNot(asleep));
    await tester.pump(const Duration(milliseconds: 2800));
    expect(await image(), awake);
    await tester.pump(const Duration(milliseconds: 300));
    expect(await image(), asleep);
  });

  for (final reducedMotion in [false, true]) {
    testWidgets('a new notice wakes sleeping eyes (reduced motion: $reducedMotion)', (
      tester,
    ) async {
      var wakeCount = 0;
      Future<void> show(Object? cue) => tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reducedMotion),
            child: EyeScene(
              mood: EyeMood.sleep,
              sleepSeconds: 3,
              fullScreen: true,
              noticeCue: cue,
              onWake: () => wakeCount++,
            ),
          ),
        ),
      );

      await show(null);
      await tester.pump(const Duration(milliseconds: 16));
      final paint = find.descendant(
        of: find.byType(EyeScene),
        matching: find.byType(CustomPaint),
      );
      final dynamic painter = tester.widget<CustomPaint>(paint.first).painter;
      final dynamic animation = painter.model;
      expect(animation.expression, EyeMood.sleep);

      await show('new-notice');
      await tester.pump(const Duration(milliseconds: 16));
      if (!reducedMotion) {
        expect(animation.reaction, isNotNull);
        await show(null);
        await tester.pump(const Duration(milliseconds: 1400));
      }
      expect(wakeCount, 1);
      expect(animation.expression, EyeMood.idle);
      await tester.pump(const Duration(milliseconds: 2900));
      expect(animation.expression, EyeMood.idle);
      await tester.pump(const Duration(milliseconds: 130));
      expect(animation.expression, EyeMood.sleep);
    });
  }

  testWidgets('double tap looks, reacts and holds its positions before resuming work', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 375,
            height: 210,
            child: EyeScene(mood: EyeMood.thinking),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));
    final scene = find.byType(EyeScene);
    final paint = find.descendant(of: scene, matching: find.byType(CustomPaint));
    final dynamic painter = tester.widget<CustomPaint>(paint.first).painter;
    final dynamic animation = painter.model;
    final Object reading = animation.thought;
    final point = tester.getCenter(scene) + const Offset(50, 0);

    Future<void> tap(int at) async {
      final finger = await tester.createGesture();
      await finger.down(point, timeStamp: Duration(milliseconds: at));
      await finger.up(timeStamp: Duration(milliseconds: at + 20));
    }

    await tap(20);
    await tester.pump(const Duration(milliseconds: 100));
    final Offset origin = animation.gaze;
    await tap(120);
    await tester.pump(const Duration(milliseconds: 40));
    expect(animation.gaze, origin);
    expect((animation.pupil as Offset).dx, greaterThan(0));

    await tester.pump(const Duration(milliseconds: 200));
    final Offset looking = animation.gaze;
    final double restingEye = animation.displayed.left.ry;
    expect(looking.dx, greaterThan(origin.dx));
    await tester.pump(const Duration(milliseconds: 170));
    expect(animation.gaze, looking);
    expect(animation.displayed.left.ry, restingEye);

    await tester.pump(const Duration(milliseconds: 210));
    final double surprised = animation.displayed.left.ry;
    expect(surprised, greaterThan(.24));
    expect(animation.gaze, looking);
    expect(animation.thought, isNull);
    await tester.pump(const Duration(milliseconds: 200));
    expect(animation.gaze, looking);
    expect(animation.displayed.left.ry, closeTo(surprised, .025));

    await tester.pump(const Duration(milliseconds: 320));
    final Offset dodge = animation.gaze;
    final double dodging = animation.displayed.left.ry;
    expect(dodge.dx, lessThan(origin.dx));
    expect(dodging, lessThan(surprised * .65));
    await tester.pump(const Duration(milliseconds: 170));
    expect(animation.gaze, dodge);
    expect(animation.displayed.left.ry, dodging);

    await tester.pump(const Duration(milliseconds: 390));
    final double questioning = animation.displayed.left.ry;
    expect(questioning, greaterThan((animation.displayed.right.ry as double) + .07));
    expect(animation.gaze, dodge);
    await tester.pump(const Duration(milliseconds: 600));
    expect(animation.displayed.left.ry, questioning);
    expect(animation.gaze, dodge);
    expect(animation.thought, isNull);

    await tester.pump(const Duration(milliseconds: 370));
    final Offset returning = animation.gaze;
    expect(returning.dx, greaterThan(dodge.dx));
    expect(returning.dx, closeTo(origin.dx, .005));
    await tester.pump(const Duration(milliseconds: 50));
    expect(animation.thought, same(reading));
  });

  testWidgets('a tap and a new expression start from the last painted pose', (
    tester,
  ) async {
    Future<void> show(EyeMood mood) => tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 375,
            height: 210,
            child: EyeScene(mood: mood),
          ),
        ),
      ),
    );
    await show(EyeMood.idle);
    await tester.pump(const Duration(milliseconds: 16));
    final scene = find.byType(EyeScene);
    final paint = find.descendant(of: scene, matching: find.byType(CustomPaint));
    final dynamic painter = tester.widget<CustomPaint>(paint.first).painter;
    final dynamic animation = painter.model;
    final center = tester.getCenter(scene);

    Future<void> tap(Offset point, int at) async {
      final finger = await tester.createGesture();
      await finger.down(point, timeStamp: Duration(milliseconds: at));
      await finger.up(timeStamp: Duration(milliseconds: at + 20));
    }

    await tap(center + const Offset(65, 0), 20);
    await tester.pump(const Duration(milliseconds: 100));
    await tap(center + const Offset(65, 0), 120);
    await tester.pump(const Duration(milliseconds: 1150));
    final Offset gaze = animation.gaze;
    final double lean = animation.displayedLean;
    final double eyeHeight = animation.displayed.left.ry;
    expect(gaze.dx, lessThan(-.12));
    expect(lean, lessThan(0));

    await tap(center - const Offset(65, 0), 1400);
    await tester.pump();
    expect(animation.gaze, gaze);
    expect(animation.displayedLean, lean);
    expect(animation.displayed.left.ry, eyeHeight);

    await tester.pump(const Duration(milliseconds: 340));
    expect(animation.gaze, gaze);
    expect(animation.displayedLean, closeTo(0, .001));
    expect(animation.displayed.left.ry, greaterThan(eyeHeight));

    await tester.pump(const Duration(milliseconds: 2600));
    final double idleHeight = animation.displayed.left.ry;
    await show(EyeMood.error);
    expect(animation.displayed.left.ry, idleHeight);
    await tester.pump(const Duration(milliseconds: 300));
    expect(animation.displayed.left.cross, 1);
  });

  testWidgets('a sleeping eye distinguishes peek, swipe and double-tap wake', (
    tester,
  ) async {
    var doubles = 0;
    final boundary = GlobalKey();
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
                child: EyeScene(
                  mood: EyeMood.sleep,
                  onDoubleTap: () => doubles++,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));

    Future<List<int>> image() async {
      final box =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final frame = box.toImageSync();
      try {
        final bytes = await tester.runAsync(() => frame.toByteData());
        return bytes!.buffer.asUint8List();
      } finally {
        frame.dispose();
      }
    }

    final point = tester.getCenter(find.byType(EyeScene)) - const Offset(65, 0);
    Future<void> tap(int at) async {
      final finger = await tester.createGesture();
      await finger.down(point, timeStamp: Duration(milliseconds: at));
      await finger.up(timeStamp: Duration(milliseconds: at + 30));
    }

    final asleep = await image();
    await tap(10);
    await tester.pump(const Duration(milliseconds: 100));
    expect(await image(), asleep);

    await tester.pump(const Duration(milliseconds: 250));
    final peek = await image();
    expect(peek, isNot(asleep));
    expect(doubles, 0);
    await tester.pump(const Duration(milliseconds: 1200));
    expect(await image(), asleep);

    final finger = await tester.createGesture();
    await finger.down(point, timeStamp: const Duration(milliseconds: 1600));
    await finger.moveBy(
      const Offset(95, 0),
      timeStamp: const Duration(milliseconds: 1640),
    );
    await finger.up(timeStamp: const Duration(milliseconds: 1680));
    await tester.pump(const Duration(milliseconds: 16));
    final rolling = await image();
    expect(rolling, isNot(asleep));
    expect(rolling, isNot(peek));
    await tester.pump(const Duration(milliseconds: 1100));
    expect(await image(), asleep);

    await tap(2800);
    await tester.pump(const Duration(milliseconds: 100));
    expect(await image(), asleep);
    await tap(2930);
    await tester.pump(const Duration(milliseconds: 16));
    final awake = await image();
    expect(awake, isNot(asleep));
    expect(awake, isNot(peek));
    expect(doubles, 1);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(await image(), awake);
  });

  for (final mood in [EyeMood.idle, EyeMood.sleep]) {
    testWidgets(
      '${mood.name} eyes follow both directions before finger lifts',
      (tester) async {
        final boundary = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: RepaintBoundary(
                key: boundary,
                child: SizedBox(
                  width: 375,
                  height: 210,
                  child: EyeScene(mood: mood),
                ),
              ),
            ),
          ),
        );

        Future<double> eyeCenter() async {
          for (var i = 0; i < 5; i++) {
            await tester.pump(const Duration(milliseconds: 16));
          }
          final box =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = box.toImageSync();
          try {
            final data = await tester.runAsync(
              () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
            );
            final pixels = data!.buffer.asUint8List();
            var weight = 0;
            var moments = 0;
            // Read the eyes without the drifting sleep letters above them.
            for (var y = 67; y < 139; y++) {
              for (var x = 0; x < 375; x++) {
                final alpha = pixels[(y * 375 + x) * 4 + 3];
                weight += alpha;
                moments += alpha * x;
              }
            }
            return moments / weight;
          } finally {
            image.dispose();
          }
        }

        final center = tester.getCenter(find.byType(EyeScene));
        final rest = await eyeCenter();
        final finger = await tester.startGesture(center - const Offset(68, 0));
        final pressedLeft = await eyeCenter();
        if (mood == EyeMood.idle) {
          expect(pressedLeft, closeTo(rest, 2));
        } else {
          expect(pressedLeft, lessThan(rest - 2));
        }

        await finger.moveTo(center + const Offset(68, 0));
        final draggedRight = await eyeCenter();
        expect(draggedRight, greaterThan(rest + 2));

        await finger.moveTo(center - const Offset(68, 0));
        expect(await eyeCenter(), lessThan(draggedRight - 4));
        await finger.up();
      },
    );
  }

  for (final reduceMotion in [false, true]) {
    testWidgets('sleep animation with reduced motion set to $reduceMotion', (
      tester,
    ) async {
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduceMotion),
            child: Center(
              child: RepaintBoundary(
                key: boundary,
                child: const SizedBox(
                  width: 375,
                  height: 210,
                  child: EyeScene(mood: EyeMood.sleep),
                ),
              ),
            ),
          ),
        ),
      );

      Future<List<int>> pixels() async {
        final box =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
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

      await tester.pump(const Duration(milliseconds: 300));
      final first = await pixels();
      await tester.pump(const Duration(milliseconds: 1700));
      final second = await pixels();

      int changedPixels(Rect area) {
        var count = 0;
        for (var y = area.top.toInt(); y < area.bottom; y++) {
          for (var x = area.left.toInt(); x < area.right; x++) {
            final offset = (y * 375 + x) * 4;
            if (first[offset + 3] != second[offset + 3]) count++;
          }
        }
        return count;
      }

      final lids = changedPixels(const Rect.fromLTRB(100, 85, 185, 120));
      final letters = changedPixels(const Rect.fromLTRB(225, 22, 300, 78));
      if (reduceMotion) {
        expect(lids, 0);
        expect(letters, 0);
      } else {
        expect(lids, greaterThan(50));
        expect(letters, greaterThan(50));
      }
    });
  }

  testWidgets('idle single tap leads with pupils and restarts mid-expression', (
    tester,
  ) async {
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: boundary,
            child: const SizedBox(
              width: 375,
              height: 210,
              child: EyeScene(mood: EyeMood.idle),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));

    Future<({double eyeX, double pupilX, int amber})> sampleAfter(
      int ms,
    ) async {
      await tester.pump(Duration(milliseconds: ms));
      final box =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = box.toImageSync();
      try {
        final data = await tester.runAsync(() => image.toByteData());
        final bytes = data!.buffer.asUint8List();
        var visible = 0, eyeMoment = 0;
        var bright = 0, pupilMoment = 0;
        var amber = 0;
        for (var i = 0; i < bytes.length; i += 4) {
          if (bytes[i + 3] < 220) continue;
          final x = i ~/ 4 % 375;
          visible++;
          eyeMoment += x;
          if (bytes[i] > 220 && bytes[i + 1] > 230 && bytes[i + 2] > 245) {
            bright++;
            pupilMoment += x;
          }
          if (bytes[i] > bytes[i + 2] + 35) amber++;
        }
        return (
          eyeX: eyeMoment / visible,
          pupilX: pupilMoment / bright,
          amber: amber,
        );
      } finally {
        image.dispose();
      }
    }

    final center = tester.getCenter(find.byType(EyeScene));
    Future<void> tap(double offset, int timestamp) async {
      final gesture = await tester.createGesture();
      await gesture.down(
        center + Offset(offset, 0),
        timeStamp: Duration(milliseconds: timestamp),
      );
      await gesture.up(timeStamp: Duration(milliseconds: timestamp + 20));
    }

    final rest = await sampleAfter(16);
    await tap(76, 30);
    final pupilOnly = await sampleAfter(850);
    expect(pupilOnly.eyeX, closeTo(rest.eyeX, 1));
    expect(pupilOnly.pupilX, greaterThan(rest.pupilX + 2));

    final shifted = await sampleAfter(300);
    expect(shifted.eyeX, greaterThan(rest.eyeX + 10));
    expect(shifted.amber, 0);
    final recentered = await sampleAfter(525);
    expect(recentered.eyeX, closeTo(rest.eyeX, 1));
    expect(recentered.pupilX, closeTo(rest.pupilX, 1));
    expect(recentered.amber, 0);
    await tester.pump(const Duration(milliseconds: 25));
    expect((await sampleAfter(220)).amber, greaterThan(500));

    await tap(-76, 1950);
    final restarted = await sampleAfter(850);
    expect(restarted.amber, 0);
    expect(restarted.eyeX, closeTo(rest.eyeX, 1));
    expect(restarted.pupilX, lessThan(rest.pupilX - 2));
    expect((await sampleAfter(300)).eyeX, lessThan(rest.eyeX - 10));
    await tester.pump(const Duration(milliseconds: 550));
    expect((await sampleAfter(900)).amber, greaterThan(500));
    await tester.pump(const Duration(milliseconds: 100));
    expect((await sampleAfter(300)).amber, 0);
  });

  testWidgets('contact particles follow a held and dragged finger', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 375,
            height: 210,
            child: EyeScene(mood: EyeMood.idle),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));
    final scene = find.byType(EyeScene);
    final paint = find.descendant(of: scene, matching: find.byType(CustomPaint));
    final dynamic painter = tester.widget<CustomPaint>(paint.first).painter;
    final List<dynamic> particles = painter.model.particles;
    final origin = tester.getTopLeft(scene);
    final point = tester.getCenter(scene);
    final finger = await tester.startGesture(point);
    await tester.pump(const Duration(milliseconds: 16));
    final count = particles.length;
    expect(count, greaterThan(0));
    expect(particles.last.origin, point - origin);

    await tester.pump(const Duration(milliseconds: 130));
    expect(particles.length, greaterThan(count));
    const move = Offset(75, 12);
    await finger.moveBy(move);
    await tester.pump(const Duration(milliseconds: 130));
    expect(particles.last.origin, point + move - origin);

    await finger.up();
    await tester.pump(const Duration(milliseconds: 850));
    expect(particles, isEmpty);
  });

  testWidgets('retapping during eye movement holds the current eye position', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 375,
            height: 210,
            child: EyeScene(mood: EyeMood.idle),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));
    final paint = find.descendant(
      of: find.byType(EyeScene),
      matching: find.byType(CustomPaint),
    );
    final dynamic painter = tester.widget<CustomPaint>(paint.first).painter;
    final dynamic animation = painter.model;
    final center = tester.getCenter(find.byType(EyeScene));
    final first = await tester.startGesture(center + const Offset(76, 0));
    await first.up(timeStamp: const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 1080));
    final Offset priorGaze = animation.gaze;
    expect(priorGaze.dx, greaterThan(0));

    final second = await tester.createGesture();
    await second.down(
      center - const Offset(76, 0),
      timeStamp: const Duration(milliseconds: 1100),
    );
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(animation.gaze, priorGaze);
    }
    expect((animation.pupil as Offset).dx, lessThan(0));
    await second.up(timeStamp: const Duration(milliseconds: 1200));
    await tester.pump(const Duration(milliseconds: 999));
    expect(animation.gaze, priorGaze);
    expect((animation.pupil as Offset).dx, lessThan(0));

    await tester.pump(const Duration(milliseconds: 25));
    final Offset moving = animation.gaze;
    expect(moving.dx, greaterThan(0));
    expect(moving.dx, lessThan(priorGaze.dx));
    await tester.pump(const Duration(milliseconds: 150));
    expect((animation.gaze as Offset).dx, lessThan(0));
  });

  testWidgets('alternating taps and a drag back to origin play release poses', (
    tester,
  ) async {
    var doubles = 0;
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: boundary,
            child: SizedBox(
              width: 375,
              height: 210,
              child: EyeScene(mood: EyeMood.idle, onDoubleTap: () => doubles++),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));

    Future<int> eyeCoverageAfter(int milliseconds) async {
      await tester.pump(Duration(milliseconds: milliseconds));
      final box =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = box.toImageSync();
      try {
        final data = await tester.runAsync(() => image.toByteData());
        final bytes = data!.buffer.asUint8List();
        var visible = 0;
        for (var i = 3; i < bytes.length; i += 4) {
          if (bytes[i] > 200) visible++;
        }
        return visible;
      } finally {
        image.dispose();
      }
    }

    final center = tester.getCenter(find.byType(EyeScene));
    final left = center - const Offset(45, 0);
    final right = center + const Offset(45, 0);
    Future<void> tap(Offset point, int at) async {
      final finger = await tester.createGesture();
      await finger.down(point, timeStamp: Duration(milliseconds: at));
      await finger.up(timeStamp: Duration(milliseconds: at + 20));
    }

    // These taps are within double-tap distance, but on opposite sides.
    await tap(left, 30);
    await tester.pump(const Duration(milliseconds: 110));
    await tap(right, 140);
    final alert = await eyeCoverageAfter(105);
    final scan = await eyeCoverageAfter(180);
    expect(alert - scan, greaterThan(400));
    expect(doubles, 0);
    await tester.pump(const Duration(milliseconds: 1000));

    final finger = await tester.startGesture(left);
    await finger.moveTo(right);
    await tester.pump(const Duration(milliseconds: 80));
    await finger.moveTo(left);
    await tester.pump(const Duration(milliseconds: 80));
    await finger.up();
    final inspect = await eyeCoverageAfter(330);
    final blink = await eyeCoverageAfter(185);
    expect(inspect - blink, greaterThan(400));
    expect(doubles, 0);
  });
}
