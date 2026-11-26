// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import 'design.dart';
import 'interaction.dart';

class DeskVoiceControl extends StatelessWidget {
  const DeskVoiceControl(
    this.interaction, {
    super.key,
    required this.showCaption,
    required this.onPressed,
  });

  final RobotInteraction interaction;
  final bool showCaption;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final phase = interaction.phase;
    final listening = interaction.listening;
    final finishing = interaction.finishingRecording;
    final error = interaction.error;
    final action = finishing
        ? '取消识别'
        : listening
        ? '结束录音'
        : error != null
        ? '重试'
        : '对话';
    final caption = switch (phase) {
      InteractionPhase.listening => interaction.draft,
      InteractionPhase.thinking => interaction.question,
      _ =>
        interaction.loading
            ? interaction.draft
            : interaction.spokenReply ?? interaction.reply,
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showCaption && error == null && caption.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Text(
              caption,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: primaryInk,
                fontSize: 13,
                shadows: [
                  Shadow(color: Colors.black, blurRadius: 6),
                  Shadow(color: Colors.black, blurRadius: 12),
                ],
              ),
            ),
          ),
        Semantics(
          label: finishing
              ? '正在识别，点按取消'
              : error == null
              ? action
              : '$error 点按重试',
          liveRegion: true,
          child: Tooltip(
            message: action,
            excludeFromSemantics: true,
            child: _VoiceTrigger(engaged: listening, onPressed: onPressed),
          ),
        ),
      ],
    );
  }
}

class _VoiceTrigger extends StatefulWidget {
  const _VoiceTrigger({required this.engaged, required this.onPressed});

  final bool engaged;
  final VoidCallback onPressed;

  @override
  State<_VoiceTrigger> createState() => _VoiceTriggerState();
}

class _VoiceTriggerState extends State<_VoiceTrigger>
    with SingleTickerProviderStateMixin {
  final _states = WidgetStatesController();
  late final _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1550),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateBreath();
  }

  @override
  void didUpdateWidget(covariant _VoiceTrigger oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.engaged != widget.engaged) _updateBreath();
  }

  void _updateBreath() {
    if (widget.engaged || MediaQuery.disableAnimationsOf(context)) {
      _breath.stop();
      return;
    }
    if (!_breath.isAnimating) _breath.repeat(reverse: true);
  }

  @override
  void dispose() {
    _states.dispose();
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 176,
    child: TextButton(
      onPressed: widget.onPressed,
      statesController: _states,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 56),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        shape: const StadiumBorder(),
        backgroundColor: Colors.transparent,
        overlayColor: Colors.transparent,
        splashFactory: NoSplash.splashFactory,
      ),
      child: ListenableBuilder(
        listenable: _states,
        builder: (context, _) {
          final pressed = _states.value.contains(WidgetState.pressed);
          final highlighted =
              _states.value.contains(WidgetState.focused) ||
              _states.value.contains(WidgetState.hovered);
          final opening = pressed
              ? 1.0
              : widget.engaged
              ? .58
              : highlighted
              ? .32
              : 0.0;
          return TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: opening),
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : Duration(milliseconds: pressed ? 150 : 310),
            curve: Curves.easeOutCubic,
            builder: (context, value, _) => RepaintBoundary(
              child: CustomPaint(
                size: const Size(64, 32),
                painter: _VoiceTriggerPainter(_breath, value),
              ),
            ),
          );
        },
      ),
    ),
  );
}

class _VoiceTriggerPainter extends CustomPainter {
  _VoiceTriggerPainter(this.breath, this.opening) : super(repaint: breath);

  final Animation<double> breath;
  final double opening;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final rest = Curves.easeInOutSine.transform(breath.value) * (1 - opening);
    final reach = 15 + 8 * opening + 2.4 * rest;
    final height = 4.5 + 3.5 * opening + 1.2 * rest;
    final tone = Color.lerp(violet, cyan, .18 + .70 * opening + .11 * rest)!;
    final marks = Path();
    for (final side in [-1, 1]) {
      marks
        ..moveTo(center.dx + side * (reach - 4), center.dy - height)
        ..quadraticBezierTo(
          center.dx + side * (reach + 4),
          center.dy,
          center.dx + side * (reach - 4),
          center.dy + height,
        );
    }
    final draw = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 4.6
      ..color = tone.withValues(alpha: .22 + .15 * rest)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    canvas.drawPath(marks, draw);
    draw
      ..strokeWidth = 1.55
      ..color = tone.withValues(alpha: .58 + .26 * opening + .11 * rest)
      ..maskFilter = null;
    canvas.drawPath(marks, draw);

    final radius = 2.7 + 1.1 * rest + .8 * opening;
    draw
      ..style = PaintingStyle.fill
      ..color = tone.withValues(alpha: .44 + .22 * rest)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.5);
    canvas.drawCircle(center, radius + 2, draw);
    draw
      ..color = Color.lerp(tone, primaryInk, .35)!
      ..maskFilter = null;
    canvas.drawCircle(center, radius, draw);
  }

  @override
  bool shouldRepaint(_VoiceTriggerPainter oldDelegate) =>
      oldDelegate.opening != opening;
}
