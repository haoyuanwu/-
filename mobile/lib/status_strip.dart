import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import 'design.dart';
import 'remote.dart';

Color moodColor(EyeMood mood) => switch (mood) {
  EyeMood.thinking => cyan,
  EyeMood.question => const Color(0xffffcc75),
  EyeMood.done => const Color(0xff88efad),
  EyeMood.error => const Color(0xffff93aa),
  EyeMood.stopped => secondaryInk,
  EyeMood.sleep => violet,
  _ => const Color(0xffc1d8fa),
};

class StatusGlyph extends StatelessWidget {
  const StatusGlyph(this.state, {super.key, this.size = 14});
  final EyeMood state;
  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _GlyphPainter(state));
}

// The same normalized paths as the Android StatusIcon drawable.
class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.state);
  final EyeMood state;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    void dot() =>
        path.addOval(Rect.fromCircle(center: const Offset(8, 13), radius: .42));
    switch (state) {
      case EyeMood.thinking:
        path
          ..moveTo(4, 2.5)
          ..lineTo(13, 8)
          ..lineTo(4, 13.5)
          ..close();
      case EyeMood.question:
        path
          ..moveTo(5, 5.1)
          ..cubicTo(5, 1.8, 11.4, 1.4, 11.4, 5.2)
          ..cubicTo(11.4, 7.4, 8, 7.4, 8, 9.8);
        dot();
      case EyeMood.done:
        path
          ..moveTo(2.7, 8.2)
          ..lineTo(6.4, 12)
          ..lineTo(13.4, 4.5);
      case EyeMood.error:
        path
          ..moveTo(8, 3)
          ..lineTo(8, 9.4);
        dot();
      case EyeMood.stopped:
        path.addRRect(RRect.fromLTRBR(3, 3, 13, 13, const Radius.circular(1)));
      case EyeMood.sleep:
        path
          ..moveTo(10.7, 13.8)
          ..cubicTo(3.2, 15.4, .1, 5.6, 7.3, 2.1)
          ..cubicTo(5.6, 6.7, 8.9, 11.2, 13.9, 10.7)
          ..cubicTo(13.1, 12.2, 12, 13.2, 10.7, 13.8)
          ..close();
      default:
        path
          ..moveTo(5.5, 3.5)
          ..lineTo(5.5, 12.5)
          ..moveTo(10.5, 3.5)
          ..lineTo(10.5, 12.5);
    }
    canvas.scale(size.width / 16, size.height / 16);
    canvas.drawPath(
      path,
      Paint()
        ..color = moodColor(state)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.7
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_GlyphPainter oldDelegate) => state != oldDelegate.state;
}

class StatusStrip extends StatelessWidget {
  const StatusStrip({
    super.key,
    required this.state,
    required this.agents,
    required this.height,
    this.desk = false,
  });
  final EyeMood state;
  final Map<String, EyeMood> agents;
  final double height;
  final bool desk;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final available = constraints.maxWidth;
      final maxBadgeWidth = math.min(
        available,
        math.max(available * .46, height * 7),
      );
      if (available < height) return const SizedBox.shrink();
      final gap = height * .17;
      final items = agents.entries.toList()
        ..sort(
          (a, b) => EyeMood.statusPriority
              .indexOf(a.value)
              .compareTo(EyeMood.statusPriority.indexOf(b.value)),
        );
      final badges = items.isEmpty
          ? <(String, EyeMood?)>[('', state)]
          : <(String, EyeMood?)>[
              for (final item in items) (item.key, item.value),
            ];
      final textStyle = DefaultTextStyle.of(context).style.copyWith(
        color: desk ? primaryInk : null,
        fontSize: height * .63,
        fontWeight: FontWeight.w500,
      );
      double widthOf((String, EyeMood?) badge) {
        final text = TextPainter(
          text: TextSpan(text: badge.$1, style: textStyle),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout();
        final width =
            text.width +
            height *
                (badge.$2 == null
                    ? .44
                    : badge.$1.isEmpty
                    ? 1.14
                    : 1.26);
        text.dispose();
        return (width.ceilToDouble() + 2).clamp(0, maxBadgeWidth).toDouble();
      }

      Widget buildBadge((String, EyeMood?) badge) => Tooltip(
        message: badge.$2 == null
            ? '还有 ${badge.$1.substring(1)} 个 AI 工具'
            : badge.$1.isEmpty
            ? badge.$2!.label
            : '${badge.$1} · ${badge.$2!.label}',
        child: Container(
          height: height,
          width: widthOf(badge),
          padding: EdgeInsets.symmetric(horizontal: height * .22),
          decoration: BoxDecoration(
            color: Color.alphaBlend(
              (badge.$2 == null ? secondaryInk : moodColor(badge.$2!))
                  .withAlpha(23),
              backdrop,
            ),
            border: Border.all(
              color: (badge.$2 == null ? secondaryInk : moodColor(badge.$2!))
                  .withAlpha(175),
            ),
            borderRadius: BorderRadius.circular(height / 2),
          ),
          child: Row(
            mainAxisAlignment: desk
                ? MainAxisAlignment.start
                : MainAxisAlignment.center,
            children: [
              if (badge.$2 case final mood?)
                StatusGlyph(mood, size: height * .70),
              if (badge.$1.isNotEmpty) ...[
                if (badge.$2 != null) SizedBox(width: height * .12),
                Flexible(
                  child: Text(
                    badge.$1,
                    style: textStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
        ),
      );

      if (desk) {
        final slots = ((constraints.maxHeight + gap) / (height + gap)).floor();
        if (slots <= 0) return const SizedBox.shrink();
        final shown = badges.length <= slots ? badges.length : slots - 1;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: gap,
          children: [
            for (final badge in badges.take(shown)) buildBadge(badge),
            if (shown < badges.length)
              buildBadge(('+${badges.length - shown}', null)),
          ],
        );
      }

      final rows = <List<(String, EyeMood?)>>[[]];
      double rowWidth(List<(String, EyeMood?)> row) =>
          row.fold(0.0, (sum, badge) => sum + widthOf(badge)) +
          gap * (row.length - 1);
      var count = 0;
      for (final badge in badges) {
        final row = rows.last;
        if (row.isNotEmpty &&
            rowWidth(row) + gap + widthOf(badge) > available) {
          if (rows.length == 2) break;
          rows.add([]);
        }
        rows.last.add(badge);
        count++;
      }
      if (count < badges.length) {
        final row = rows.last;
        while (row.isNotEmpty &&
            rowWidth(row) + gap + widthOf(('+${badges.length - count}', null)) >
                available) {
          row.removeLast();
          count--;
        }
        row.add(('+${badges.length - count}', null));
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        spacing: gap,
        children: [
          for (final row in rows)
            Row(
              mainAxisSize: MainAxisSize.min,
              spacing: gap,
              children: [for (final badge in row) buildBadge(badge)],
            ),
        ],
      );
    },
  );
}
