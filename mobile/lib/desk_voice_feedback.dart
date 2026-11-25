import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import 'design.dart';
import 'interaction.dart';

class DeskVoiceFeedback extends StatelessWidget {
  const DeskVoiceFeedback(this.interaction, {super.key});

  final RobotInteraction interaction;

  @override
  Widget build(BuildContext context) {
    final phase = interaction.phase;
    final speaking = interaction.spokenText != null;
    final active =
        phase != InteractionPhase.idle || speaking || interaction.loading;
    final (label, accent) = switch (phase) {
      InteractionPhase.listening => ('', cyan),
      InteractionPhase.thinking => ('正在思考', violet),
      InteractionPhase.answering => (speaking ? '正在朗读' : '正在回答', cyan),
      InteractionPhase.idle => (
        speaking
            ? '正在朗读'
            : interaction.loading
            ? '正在连接模型'
            : '',
        cyan,
      ),
    };
    final caption = switch (phase) {
      InteractionPhase.listening => interaction.draft,
      InteractionPhase.thinking => interaction.question,
      _ =>
        interaction.loading
            ? interaction.draft
            : interaction.spokenText ?? interaction.error ?? interaction.reply,
    };
    if (!active && caption.isEmpty) return const SizedBox.shrink();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (active) ...[
          ExcludeSemantics(
            child: RepaintBoundary(
              child: _VoiceWave(
                color: accent,
                listening:
                    interaction.listening && !interaction.finishingRecording,
                level: interaction.inputLevel,
                speaking: speaking,
              ),
            ),
          ),
          if (label.isNotEmpty)
            Semantics(
              liveRegion: true,
              child: Text(label, style: TextStyle(color: accent, fontSize: 12)),
            ),
        ],
        if (caption.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: panelColor.withAlpha(235),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: borderColor),
            ),
            child: Text(
              caption,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: interaction.error == null
                    ? primaryInk
                    : Theme.of(context).colorScheme.error,
                fontSize: 13,
              ),
            ),
          ),
      ],
    );
  }
}

class DeskVoiceButton extends StatelessWidget {
  const DeskVoiceButton({
    super.key,
    required this.listening,
    required this.speechEnabled,
    required this.onPressed,
  });

  final bool listening;
  final bool speechEnabled;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final label = listening
        ? '结束录音'
        : speechEnabled
        ? '说话'
        : 'AI 对话';
    final accent = listening ? cyan : violet;
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: SweepGradient(
          colors: [accent, const Color(0xff30445c), cyan, accent],
        ),
        boxShadow: [
          BoxShadow(
            color: accent.withAlpha(listening ? 118 : 58),
            blurRadius: 15,
          ),
        ],
      ),
      padding: const EdgeInsets.all(1.5),
      child: Material(
        color: const Color(0xff151a2c),
        shape: const CircleBorder(),
        child: IconButton(
          tooltip: label,
          onPressed: onPressed,
          color: listening ? cyan : primaryInk,
          style: IconButton.styleFrom(
            minimumSize: const Size.square(51),
            shape: const CircleBorder(),
          ),
          icon: Icon(
            listening
                ? Icons.stop_rounded
                : speechEnabled
                ? Icons.mic_rounded
                : Icons.chat_bubble_outline,
            size: 23,
          ),
        ),
      ),
    );
  }
}

class _VoiceWave extends StatefulWidget {
  const _VoiceWave({
    required this.color,
    required this.listening,
    required this.level,
    required this.speaking,
  });

  final Color color;
  final bool listening;
  final double level;
  final bool speaking;

  @override
  State<_VoiceWave> createState() => _VoiceWaveState();
}

class _VoiceWaveState extends State<_VoiceWave>
    with SingleTickerProviderStateMixin {
  late final _time = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1900),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _time.stop();
      _time.value = 0;
    } else if (!_time.isAnimating) {
      _time.repeat();
    }
  }

  @override
  void dispose() {
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 110),
    tween: Tween(
      end: widget.listening
          ? widget.level
          : widget.speaking
          ? .58
          : .34,
    ),
    builder: (context, amplitude, _) => SizedBox(
      width: 152,
      height: 38,
      child: CustomPaint(
        painter: _WavePainter(
          _time,
          widget.color,
          MediaQuery.disableAnimationsOf(context) ? .30 : amplitude,
        ),
      ),
    ),
  );
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.time, this.color, this.amplitude) : super(repaint: time);

  final Animation<double> time;
  final Color color;
  final double amplitude;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.height / 2;
    final tick = time.value * math.pi * 2;
    final brush = Paint()..strokeCap = StrokeCap.round;
    const count = 21;
    for (var index = 0; index < count; index++) {
      final progress = (index + 1) / (count + 1);
      final x = size.width * progress;
      final envelope = math.sin(math.pi * progress);
      final pulse = .52 + .48 * math.sin(tick + index * .72);
      final mirror = .70 + .30 * math.cos(2 * tick - index * .48);
      final half = 1.5 + envelope * (1.5 + 14 * amplitude) * pulse;
      final top = Offset(x, center - half);
      final bottom = Offset(x, center + half * mirror);
      final shade = Color.lerp(violet, color, envelope)!;
      brush
        ..strokeWidth = 7
        ..color = shade.withAlpha(30)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
      canvas.drawLine(top, bottom, brush);
      brush
        ..strokeWidth = 2.7
        ..color = shade.withAlpha((140 + 115 * envelope).round())
        ..maskFilter = null;
      canvas.drawLine(top, bottom, brush);
    }
  }

  @override
  bool shouldRepaint(_WavePainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.amplitude != amplitude;
}
