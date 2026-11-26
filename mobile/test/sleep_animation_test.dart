import 'dart:ui' as ui;

// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rear_eyes_mobile/eye_scene.dart';
import 'package:rear_eyes_mobile/remote.dart';

void main() {
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
        expect(pressedLeft, lessThan(rest - 2));

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
}
