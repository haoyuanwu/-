import 'dart:ui' as ui;

// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rear_eyes_mobile/eye_scene.dart';
import 'package:rear_eyes_mobile/remote.dart';

void main() {
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
