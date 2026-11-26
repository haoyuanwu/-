// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import 'design.dart';
import 'interaction.dart';

enum ReplyStage {
  waiting('等待回复', violet),
  receiving('接收中', cyan),
  reading('朗读中', Color(0xffffce9e)),
  complete(null, cyan);

  const ReplyStage(this.label, this.color);

  final String? label;
  final Color color;

  static ReplyStage fromActivity({
    required bool generating,
    required bool hasReply,
    required bool speaking,
  }) => speaking
      ? reading
      : generating
      ? (hasReply ? receiving : waiting)
      : complete;
}

class ReplyPreview extends StatelessWidget {
  const ReplyPreview(this.interaction, {super.key});

  final RobotInteraction interaction;

  @override
  Widget build(BuildContext context) {
    final reply = interaction.reply;
    final speaking = interaction.spokenReply != null;
    final text =
        interaction.spokenReply ??
        (reply.isEmpty ? interaction.question : reply);
    return ReplyFrame(
      model: interaction.replyModel ?? 'Robot Eyes',
      stage: ReplyStage.fromActivity(
        generating: interaction.generating,
        hasReply: reply.isNotEmpty,
        speaking: speaking,
      ),
      action: speaking
          ? IconButton(
              tooltip: '停止朗读',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.volume_off_outlined, size: 18),
              onPressed: interaction.muteCurrent,
            )
          : null,
      child: LayoutBuilder(
        builder: (context, constraints) {
          const style = TextStyle(
            color: primaryInk,
            fontSize: 14,
            height: 1.32,
          );
          var excerpt = text.isEmpty ? '正在思考…' : text;
          if (reply.isNotEmpty && (interaction.generating || speaking)) {
            final lines = TextPainter(
              text: TextSpan(text: excerpt, style: style),
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
            )..layout(maxWidth: constraints.maxWidth);
            final metrics = lines.computeLineMetrics();
            if (metrics.length > 2) {
              final line = metrics[metrics.length - 2];
              final offset = Offset(0, line.baseline - line.ascent / 2);
              final start = lines
                  .getLineBoundary(lines.getPositionForOffset(offset))
                  .start;
              excerpt = excerpt.substring(start);
            }
            lines.dispose();
          }
          return Text(
            excerpt,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: style,
          );
        },
      ),
    );
  }
}

class ReplyFrame extends StatefulWidget {
  const ReplyFrame({
    super.key,
    required this.model,
    required this.stage,
    required this.child,
    this.action,
  });

  final String model;
  final ReplyStage stage;
  final Widget child;
  final Widget? action;

  @override
  State<ReplyFrame> createState() => _ReplyFrameState();
}

class _ReplyFrameState extends State<ReplyFrame>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scan = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1650),
  );

  void _updateScan() {
    final moving =
        widget.stage != ReplyStage.complete &&
        !MediaQuery.disableAnimationsOf(context);
    if (moving && !_scan.isAnimating) {
      _scan.repeat();
    } else if (!moving) {
      _scan.reset();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateScan();
  }

  @override
  void didUpdateWidget(covariant ReplyFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.stage != widget.stage) _updateScan();
  }

  @override
  void dispose() {
    _scan.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.stage.color;
    final status = widget.stage.label;
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(13, 9, 13, 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.graphic_eq_rounded, size: 17, color: color),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  widget.model,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: const TextStyle(
                    color: primaryInk,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (status != null)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    status,
                    style: TextStyle(color: color, fontSize: 12),
                  ),
                ),
              ?widget.action,
            ],
          ),
          const SizedBox(height: 7),
          widget.child,
        ],
      ),
    );
    return CustomPaint(painter: _ReplyRail(_scan, color), child: content);
  }
}

class _ReplyRail extends CustomPainter {
  _ReplyRail(this.scan, this.color) : super(repaint: scan);

  final Animation<double> scan;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final edge = Path()
      ..moveTo(.5, .5)
      ..lineTo(size.width - 16, .5)
      ..lineTo(size.width - .5, 16)
      ..lineTo(size.width - .5, size.height - 5)
      ..lineTo(size.width - 5, size.height - .5)
      ..lineTo(.5, size.height - .5)
      ..close();
    canvas.drawPath(edge, Paint()..color = const Color(0xf20f1a28));
    canvas.drawPath(
      edge,
      Paint()
        ..color = color.withValues(alpha: .29)
        ..style = PaintingStyle.stroke,
    );
    if (size.height <= 18) return;
    final railLength = (size.height - 12).clamp(6.0, 108.0);
    final y = 6 + scan.value * (railLength - 6);
    canvas.drawLine(
      Offset(1.5, y),
      Offset(1.5, y + 6),
      Paint()
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _ReplyRail oldDelegate) =>
      color != oldDelegate.color || scan != oldDelegate.scan;
}
