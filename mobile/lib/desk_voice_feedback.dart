import 'dart:async';
import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import 'design.dart';
import 'interaction.dart';
import 'reply_frame.dart';

const deskControlHeight = 48.0;

class DeskVoiceControl extends StatelessWidget {
  const DeskVoiceControl(
    this.interaction, {
    super.key,
    required this.onPressed,
  });

  final RobotInteraction interaction;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final phase = interaction.phase;
    final listening = interaction.listening;
    final finishing = interaction.finishingRecording;
    final error = interaction.error;
    final retry = interaction.canRetryReply;
    final action = finishing
        ? '取消识别'
        : listening
        ? '结束录音'
        : error != null || retry
        ? '重试'
        : '对话';
    final speaking = interaction.spokenReply;
    final reply = interaction.reply;
    final turn = interaction.turnId;
    final stage = error != null
        ? _CaptionStage.error
        : listening
        ? (finishing ? _CaptionStage.sending : _CaptionStage.listening)
        : phase == InteractionPhase.thinking || interaction.loading
        ? _CaptionStage.sending
        : interaction.generating
        ? _CaptionStage.receiving
        : speaking != null
        ? _CaptionStage.reading
        : _CaptionStage.complete;
    final caption = switch (stage) {
      _CaptionStage.error => error!,
      _CaptionStage.listening =>
        interaction.draft.isNotEmpty
            ? interaction.draft
            : interaction.startingRecording
            ? '正在准备麦克风…'
            : '正在聆听…',
      _CaptionStage.sending =>
        listening
            ? (interaction.draft.isEmpty ? '正在识别…' : interaction.draft)
            : (interaction.question.isEmpty
                  ? interaction.draft
                  : interaction.question),
      _CaptionStage.receiving => reply,
      _CaptionStage.complete => retry ? interaction.draft : reply,
      _CaptionStage.reading => reply.isEmpty ? speaking! : reply,
    };
    final isReply =
        stage == _CaptionStage.receiving ||
        stage == _CaptionStage.reading ||
        (stage == _CaptionStage.complete && !retry);
    final hideCaption =
        caption.isEmpty || (isReply && interaction.deskReplyDismissed);
    final motion = !MediaQuery.disableAnimationsOf(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedSwitcher(
          duration: motion ? const Duration(milliseconds: 260) : Duration.zero,
          reverseDuration: motion
              ? const Duration(milliseconds: 175)
              : Duration.zero,
          layoutBuilder: (current, _) => current ?? const SizedBox.shrink(),
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutQuad,
            ),
            child: SlideTransition(
              position: Tween(begin: const Offset(0, .15), end: Offset.zero)
                  .animate(
                    CurvedAnimation(
                      parent: animation,
                      curve: Curves.easeOutCubic,
                    ),
                  ),
              child: child,
            ),
          ),
          child: hideCaption
              ? const SizedBox.shrink()
              : _DeskCaption(
                  key: ValueKey(
                    stage == _CaptionStage.receiving ||
                            stage == _CaptionStage.reading ||
                            stage == _CaptionStage.complete
                        ? _CaptionStage.receiving
                        : stage,
                  ),
                  stage: stage,
                  text: caption,
                  turn: turn,
                  autoDismiss: !retry,
                  onDismissed: () => interaction.dismissDeskReply(turn, reply),
                  failedDraft: error != null && retry
                      ? interaction.draft
                      : null,
                  stopReading: speaking == null
                      ? null
                      : interaction.muteCurrent,
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
            child: _VoiceTrigger(
              engaged: listening,
              speaking: interaction.speechPlaying && !listening,
              onPressed: onPressed,
            ),
          ),
        ),
      ],
    );
  }
}

enum _CaptionStage { listening, sending, receiving, reading, complete, error }

class _DeskCaption extends StatefulWidget {
  const _DeskCaption({
    super.key,
    required this.stage,
    required this.text,
    required this.turn,
    required this.stopReading,
    required this.onDismissed,
    this.failedDraft,
    this.autoDismiss = true,
  });

  final _CaptionStage stage;
  final String text;
  final String? turn;
  final VoidCallback? stopReading;
  final VoidCallback onDismissed;
  final String? failedDraft;
  final bool autoDismiss;

  @override
  State<_DeskCaption> createState() => _DeskCaptionState();
}

class _DeskCaptionState extends State<_DeskCaption>
    with TickerProviderStateMixin {
  late final _scan = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  late final _arrival = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 720),
    value: 1,
  );
  bool _started = false;
  Timer? _revealTimer;
  Timer? _dismissTimer;
  late List<String> _characters;
  var _revealed = 0;
  var _visibleText = '';
  var _dismissed = false;

  bool get _motion => !MediaQuery.disableAnimationsOf(context);
  bool get _sending => widget.stage == _CaptionStage.sending;
  bool get _canDismiss =>
      widget.autoDismiss && widget.stage == _CaptionStage.complete;

  @override
  void initState() {
    super.initState();
    _characters = widget.text.characters.toList();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateMotion();
    if (!_started || !_motion) {
      _updateText(reset: !_started);
    }
    _started = true;
  }

  @override
  void didUpdateWidget(covariant _DeskCaption oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateMotion();
    final newTurn = widget.turn != oldWidget.turn;
    final changed = widget.text != oldWidget.text;
    if (changed) _characters = widget.text.characters.toList();
    if (newTurn ||
        changed ||
        widget.stage != oldWidget.stage ||
        widget.autoDismiss != oldWidget.autoDismiss) {
      _dismissTimer?.cancel();
      _dismissTimer = null;
      _dismissed = false;
      _updateText(
        reset:
            newTurn ||
            _visibleText.isNotEmpty && !widget.text.startsWith(_visibleText),
      );
    }
  }

  void _updateText({required bool reset}) {
    if (reset) {
      _revealed = 0;
      _visibleText = '';
    }
    final length = _characters.length;
    final revealing =
        _motion &&
        (widget.stage == _CaptionStage.receiving ||
            (_revealTimer != null &&
                (widget.stage == _CaptionStage.reading || _canDismiss)));
    if (!revealing || _revealed >= length) {
      _stopReveal();
      _revealed = length;
      _visibleText = widget.text;
      _scheduleDismissal();
      return;
    }
    if (_revealed == 0) _revealNext();
    if (_revealed < length) {
      _revealTimer ??= Timer.periodic(
        const Duration(milliseconds: 82),
        (_) => setState(_revealNext),
      );
    } else {
      _scheduleDismissal();
    }
  }

  void _revealNext() {
    final remaining = _characters.length - _revealed;
    // Let bursts catch up in groups while keeping a steady visual cadence.
    final step = (remaining / 16).ceil();
    _visibleText += _characters.skip(_revealed).take(step).join();
    _revealed += step;
    _arrival.forward(from: 0);
    if (_revealed == _characters.length) {
      _stopReveal();
      _scheduleDismissal();
    }
  }

  void _stopReveal() {
    _revealTimer?.cancel();
    _revealTimer = null;
  }

  void _scheduleDismissal() {
    if (!_canDismiss || _dismissed || _visibleText.isEmpty) return;
    _dismissTimer ??= Timer(const Duration(seconds: 10), () {
      widget.onDismissed();
      setState(() => _dismissed = true);
    });
  }

  void _updateMotion() {
    if (_motion && _sending) {
      if (!_scan.isAnimating) _scan.repeat();
    } else {
      _scan.reset();
    }
    if (!_motion) _arrival.value = 1;
  }

  @override
  void dispose() {
    _stopReveal();
    _dismissTimer?.cancel();
    _scan.dispose();
    _arrival.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: _motion ? const Duration(milliseconds: 420) : Duration.zero,
    layoutBuilder: (current, previous) => _dismissed || _visibleText.isEmpty
        ? AnimatedSwitcher.defaultLayoutBuilder(current, previous)
        : current ?? const SizedBox.shrink(),
    child: _dismissed || _visibleText.isEmpty
        ? const SizedBox.shrink()
        : _caption(),
  );

  Widget _caption() {
    final error = widget.stage == _CaptionStage.error;
    final receiving =
        widget.stage == _CaptionStage.receiving ||
        _revealTimer != null ||
        (_canDismiss && _arrival.isAnimating);
    final color = error
        ? const Color(0xffff999e)
        : _sending
        ? violet
        : widget.stage == _CaptionStage.reading
        ? const Color(0xffffce9e)
        : cyan;
    final stop = widget.stopReading;
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: CustomPaint(
        painter: _CaptionSignal(
          _scan,
          _arrival,
          color,
          _motion && _sending,
          _motion && receiving,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(13, 8, 13, 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (error) ...[
                Icon(Icons.error_outline, size: 16, color: color),
                const SizedBox(width: 7),
              ],
              Flexible(
                child: LayoutBuilder(
                  builder: (context, bounds) {
                    final style = TextStyle(
                      color: error ? const Color(0xffffcbcd) : primaryInk,
                      fontSize: 14,
                      height: 1.32,
                    );
                    final excerpt = replyExcerpt(
                      context,
                      _visibleText,
                      style,
                      bounds.maxWidth,
                      tail: !error,
                    );
                    final label = Text(
                      excerpt,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: style,
                    );
                    final draft = widget.failedDraft;
                    if (draft == null || draft.isEmpty) return label;
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          draft,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: style.copyWith(
                            color: secondaryInk,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 2),
                        label,
                      ],
                    );
                  },
                ),
              ),
              if (stop != null)
                IconButton(
                  tooltip: '停止朗读',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.volume_off_outlined, size: 17),
                  onPressed: stop,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CaptionSignal extends CustomPainter {
  _CaptionSignal(
    this.scan,
    this.arrival,
    this.color,
    this.sending,
    this.receiving,
  ) : super(repaint: Listenable.merge([scan, arrival]));

  final Animation<double> scan, arrival;
  final Color color;
  final bool sending, receiving;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final shape = RRect.fromRectAndRadius(rect, const Radius.circular(10));
    final brush = Paint();
    canvas.drawRRect(shape, brush..color = const Color(0xe30b121d));
    canvas.save();
    canvas.clipRRect(shape);
    final y = size.height - 1;
    canvas.drawLine(
      Offset(8, y),
      Offset(size.width - 8, y),
      brush
        ..color = color.withValues(alpha: .32)
        ..strokeWidth = 1,
    );
    if (sending) {
      final p = Curves.easeInOutCubic.transform(scan.value);
      final x = p * (size.width + 36) - 18;
      final glow = Rect.fromLTWH(x - 35, 0, 70, size.height);
      brush.shader = LinearGradient(
        colors: [
          color.withValues(alpha: 0),
          color.withValues(alpha: .22),
          color.withValues(alpha: 0),
        ],
      ).createShader(glow);
      canvas.drawRect(glow, brush);
      brush.shader = null;
      canvas.drawLine(
        Offset(x - 13, y),
        Offset(x + 13, y),
        brush
          ..color = color
          ..strokeWidth = 1.6,
      );
      for (var i = 0; i < 4; i++) {
        final dot = (p * 2.5 + i * .23) % 1;
        canvas.drawCircle(
          Offset(x - dot * 28, y - 4 - dot * (5 + i * 2)),
          1.2 - dot * .55,
          brush..color = color.withValues(alpha: (1 - dot) * .65),
        );
      }
    } else if (receiving && arrival.value < 1) {
      final pulse = 1 - Curves.easeOutCubic.transform(arrival.value);
      final x = size.width - 9;
      canvas.drawLine(
        Offset(x - 24 * (1 - pulse), y),
        Offset(x, y),
        brush
          ..color = color.withValues(alpha: pulse)
          ..strokeWidth = 1.8,
      );
      canvas.drawCircle(
        Offset(x, y - 3),
        1.5 + pulse,
        brush..color = color.withValues(alpha: pulse * .85),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CaptionSignal oldDelegate) =>
      color != oldDelegate.color ||
      sending != oldDelegate.sending ||
      receiving != oldDelegate.receiving ||
      arrival != oldDelegate.arrival;
}

class _VoiceTrigger extends StatefulWidget {
  const _VoiceTrigger({
    required this.engaged,
    required this.speaking,
    required this.onPressed,
  });

  final bool engaged;
  final bool speaking;
  final VoidCallback onPressed;

  @override
  State<_VoiceTrigger> createState() => _VoiceTriggerState();
}

class _VoiceTriggerState extends State<_VoiceTrigger>
    with TickerProviderStateMixin {
  final _states = WidgetStatesController();
  late final _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1550),
  );
  late final _speech = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateMotion();
  }

  @override
  void didUpdateWidget(covariant _VoiceTrigger oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.engaged != widget.engaged ||
        oldWidget.speaking != widget.speaking) {
      _updateMotion();
    }
  }

  void _updateMotion() {
    final motion = !MediaQuery.disableAnimationsOf(context);
    if (widget.speaking && motion) {
      if (!_speech.isAnimating) _speech.repeat();
    } else {
      _speech.reset();
    }
    if (widget.engaged || widget.speaking || !motion) {
      _breath.stop();
      return;
    }
    if (!_breath.isAnimating) _breath.repeat(reverse: true);
  }

  @override
  void dispose() {
    _states.dispose();
    _breath.dispose();
    _speech.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 176,
    child: TextButton(
      onPressed: widget.onPressed,
      statesController: _states,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, deskControlHeight),
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
                painter: _VoiceTriggerPainter(
                  _breath,
                  _speech,
                  value,
                  widget.speaking,
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
}

class _VoiceTriggerPainter extends CustomPainter {
  _VoiceTriggerPainter(this.breath, this.speech, this.opening, this.speaking)
    : super(repaint: Listenable.merge([breath, speech]));

  final Animation<double> breath;
  final Animation<double> speech;
  final double opening;
  final bool speaking;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    if (speaking) {
      _paintMouth(canvas, center);
      return;
    }
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

  void _paintMouth(Canvas canvas, Offset center) {
    final phase = speech.value * 2 * math.pi;
    final syllable = math.pow(
      (1 - math.cos(phase * 9 + .5 * math.sin(phase * 2))) / 2,
      1.35,
    );
    final phrase = .44 + .56 * (1 - math.cos(phase * 2 + 1.05)) / 2;
    final articulation = syllable * phrase;
    final width = 13 + 4.5 * (1 - articulation) + opening * 1.5;
    final gap = 1 + 7.0 * articulation;
    final lips = Path()
      ..moveTo(center.dx - width, center.dy)
      ..quadraticBezierTo(
        center.dx,
        center.dy - gap,
        center.dx + width,
        center.dy,
      )
      ..quadraticBezierTo(
        center.dx,
        center.dy + gap * 1.35,
        center.dx - width,
        center.dy,
      )
      ..close();
    final color = Color.lerp(cyan, violet, .12 + .28 * articulation)!;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.2
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4)
      ..color = color.withValues(alpha: .30 + .28 * articulation);
    canvas.drawPath(lips, paint);
    paint
      ..style = PaintingStyle.fill
      ..maskFilter = null
      ..color = color.withValues(alpha: .09 + .22 * articulation);
    canvas.drawPath(lips, paint);
    paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..color = Color.lerp(color, primaryInk, .35)!;
    canvas.drawPath(lips, paint);
    for (final side in [-1, 1]) {
      final start = center + Offset(side * (width + 4), 0);
      canvas.drawLine(
        start,
        start + Offset(side * 3.5, 0),
        paint
          ..strokeCap = StrokeCap.round
          ..color = color.withValues(alpha: .43 + .4 * articulation),
      );
    }
  }

  @override
  bool shouldRepaint(_VoiceTriggerPainter oldDelegate) =>
      oldDelegate.opening != opening ||
      oldDelegate.speaking != speaking ||
      oldDelegate.speech != speech;
}
