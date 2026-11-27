import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'design.dart';
import 'notice_window.dart';
import 'remote.dart';
import 'status_strip.dart';

class EyeScene extends StatefulWidget {
  const EyeScene({
    super.key,
    required this.mood,
    this.fullScreen = false,
    this.noticeCue,
    this.voiceLevel,
    this.speechActivity = 0,
    this.speaking = false,
    this.conversationActive = false,
    this.revision = 0,
    this.sleepSeconds = 90,
    this.agents = const {},
    this.connected = false,
    this.allowVerticalScroll = false,
    this.onDoubleTap,
    this.onWake,
    this.leftInset = 0,
    this.keepAwake = false,
  });
  final EyeMood mood;
  final bool fullScreen;
  final Object? noticeCue;
  final double? voiceLevel;
  final int speechActivity;
  final bool speaking;
  final bool conversationActive;
  final int revision;
  final int sleepSeconds;
  final Map<String, EyeMood> agents;
  final bool connected;
  final bool allowVerticalScroll;
  final VoidCallback? onDoubleTap;
  final VoidCallback? onWake;
  final double leftInset;
  final bool keepAwake;

  @override
  State<EyeScene> createState() => _EyeSceneState();
}

class _EyeSceneState extends State<EyeScene>
    with SingleTickerProviderStateMixin {
  late final _Animation model;
  late final Ticker ticker;

  @override
  void initState() {
    super.initState();
    model = _Animation(widget.mood)
      ..sleepSeconds = widget.sleepSeconds
      ..desk = widget.fullScreen
      ..leftInset = widget.leftInset
      ..keepAwake = widget.keepAwake
      ..voiceLevel = widget.voiceLevel
      ..setConversationActive(widget.conversationActive)
      ..setSpeaking(widget.speaking)
      ..setNotice(widget.noticeCue != null);
    ticker = createTicker((elapsed) {
      final wokeAt = model.wokeAt;
      model.step(elapsed.inMilliseconds);
      if (model.wokeAt != null && model.wokeAt != wokeAt) {
        widget.onWake?.call();
      }
    })..start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    model.motion = !MediaQuery.disableAnimationsOf(context);
  }

  @override
  void didUpdateWidget(covariant EyeScene oldWidget) {
    super.didUpdateWidget(oldWidget);
    model.sleepSeconds = widget.sleepSeconds;
    model.desk = widget.fullScreen;
    model.leftInset = widget.leftInset;
    model.keepAwake = widget.keepAwake;
    model.voiceLevel = widget.voiceLevel;
    if (widget.voiceLevel == null) {
      model.speechDetectedAt = null;
    } else if (oldWidget.speechActivity != widget.speechActivity) {
      model.speechDetectedAt = model.time;
    }
    model.setSpeaking(widget.speaking);
    model.setConversationActive(widget.conversationActive);
    if (oldWidget.mood != widget.mood ||
        oldWidget.revision != widget.revision) {
      model.update(widget.mood);
    }
    if (oldWidget.noticeCue != widget.noticeCue) {
      model.setNotice(widget.noticeCue != null);
    }
  }

  @override
  void dispose() {
    ticker.dispose();
    model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: '电子眼，${widget.mood.label}',
    child: RawGestureDetector(
      gestures: {
        _EyeGesture: GestureRecognizerFactoryWithHandlers<_EyeGesture>(
          _EyeGesture.new,
          (gestures) {
            gestures.allowVerticalScroll = widget.allowVerticalScroll;
            gestures.onDown = model.down;
            gestures.onMove = model.move;
            gestures.onUp = (event) {
              if (model.up(event)) widget.onDoubleTap?.call();
            };
            gestures.onCancel = model.cancel;
          },
        ),
      },
      behavior: HitTestBehavior.opaque,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final frame = _frame(size, widget.fullScreen, widget.leftInset);
          final badgeHeight = math.min(
            frame.height * .085,
            widget.fullScreen ? 22.0 : 17.0,
          );
          final insets = MediaQuery.paddingOf(context);
          final badges = StatusStrip(
            state: widget.mood,
            agents: widget.agents,
            height: badgeHeight,
            desk: widget.fullScreen,
          );
          return Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(child: CustomPaint(painter: _Painter(model))),
              if (widget.fullScreen)
                Positioned(
                  top: insets.top + 12,
                  left: math.max(insets.left, widget.leftInset) + 12,
                  right: insets.right + 12,
                  child: IgnorePointer(
                    child: Center(
                      child: ValueListenableBuilder<bool>(
                        valueListenable: model.completionNotice,
                        builder: (context, visible, _) => NoticeWindow(
                          child: visible
                              ? const _CompletionBanner()
                              : const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ),
                ),
              if (badgeHeight >= 10 &&
                  (widget.connected || widget.agents.isNotEmpty))
                if (widget.fullScreen)
                  Positioned(
                    left: insets.left + 16,
                    width: size.width * .26,
                    top: insets.top + 16,
                    bottom: insets.bottom + math.min(64, size.height * .20),
                    child: Align(alignment: Alignment.topLeft, child: badges),
                  )
                else
                  Positioned(
                    left: 4,
                    right: 4,
                    bottom: math.max(
                      0,
                      size.height -
                          frame.top -
                          frame.height * .9 -
                          badgeHeight / 2,
                    ),
                    child: badges,
                  ),
            ],
          );
        },
      ),
    ),
  );
}

class _CompletionBanner extends StatelessWidget {
  const _CompletionBanner();

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: const CustomPaint(
      painter: NoticeWindowFrame(),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 10, horizontal: 16),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            StatusGlyph(EyeMood.done),
            SizedBox(width: 8),
            Flexible(
              child: Text(
                '工作完成',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: primaryInk,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _EyeGesture extends OneSequenceGestureRecognizer {
  int? _pointer;
  Offset _origin = Offset.zero;
  bool _claimed = false;
  bool allowVerticalScroll = false;
  void Function(PointerDownEvent)? onDown;
  void Function(PointerMoveEvent)? onMove;
  void Function(PointerUpEvent)? onUp;
  VoidCallback? onCancel;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (_pointer != null || event.buttons != kPrimaryButton) return;
    _pointer = event.pointer;
    _origin = event.position;
    startTrackingPointer(event.pointer, event.transform);
    _claimed = !allowVerticalScroll;
    if (_claimed) resolve(GestureDisposition.accepted);
    onDown?.call(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _pointer) return;
    if (event is PointerMoveEvent) {
      if (!_claimed) {
        final offset = event.position - _origin;
        if (offset.dy.abs() > kTouchSlop && offset.dy.abs() > offset.dx.abs()) {
          resolve(GestureDisposition.rejected);
          return;
        }
        if (offset.dx.abs() > kTouchSlop) {
          _claimed = true;
          resolve(GestureDisposition.accepted);
        }
      }
      onMove?.call(event);
    }
    if (event is PointerUpEvent) {
      if (!_claimed) resolve(GestureDisposition.accepted);
      onUp?.call(event);
    }
    if (event is PointerCancelEvent) onCancel?.call();
    stopTrackingIfPointerNoLongerDown(event);
  }

  @override
  void rejectGesture(int pointer) {
    if (_pointer == pointer) {
      onCancel?.call();
      stopTrackingPointer(pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) => _pointer = null;
  @override
  String get debugDescription => 'electronic eyes';
}

double _unit(num value) => value.clamp(0, 1).toDouble();
double _ease(num value) {
  final t = _unit(value);
  return t * t * (3 - 2 * t);
}

double _pulse(num age, num duration) =>
    math.sin(_unit(age / duration) * math.pi);
double _mix(double a, double b, double t) => a + (b - a) * t;

enum _GestureReaction { tap, doubleTap, swipe, volley, peek, wake, rollOver }

enum _Pose { rest, alert, blink, wink, curious, grin, focus, droop, scan }

typedef _Beat = ({int at, _Pose pose, double side, double lift, double signal});

_Beat _beat(
  int at,
  _Pose pose, {
  double side = 0,
  double lift = 0,
  double signal = 0,
}) => (at: at, pose: pose, side: side, lift: lift, signal: signal);

class _Reaction {
  _Reaction(
    this.kind,
    this.at,
    this.point,
    this.direction,
    this.beats,
    this.from,
    this.fromGaze,
    this.fromPupil,
  );

  final _GestureReaction kind;
  final int at;
  final Offset point, direction;
  final List<_Beat> beats;
  final _Face? from;
  final Offset fromGaze, fromPupil;
  int get duration => beats.last.at;
}

const _doubleTapLookAt = 170;
const _doubleTapDodgeStartsAt = 850;
const _doubleTapDodgeAt = 1050;
const _doubleTapQuestionAt = 1570;
const _doubleTapReturnAt = 2350;
const _doubleTapEndAt = 2680;

List<_Beat> _choreography(
  _GestureReaction kind,
  EyeMood mood,
  int variation,
  bool listening,
  bool speaking,
) {
  const alert = _Pose.alert, blink = _Pose.blink, wink = _Pose.wink;
  const curious = _Pose.curious, grin = _Pose.grin, focus = _Pose.focus;
  const droop = _Pose.droop, scan = _Pose.scan, rest = _Pose.rest;
  final handoff = speaking
      ? grin
      : listening
      ? focus
      : switch (mood) {
          EyeMood.thinking => scan,
          EyeMood.question || EyeMood.error => curious,
          EyeMood.done || EyeMood.hello => grin,
          EyeMood.idea => alert,
          _ => [wink, curious, grin][variation],
        };
  return switch (kind) {
    _GestureReaction.tap => [
      _beat(0, rest),
      _beat(105, alert, side: .65, lift: .28),
      _beat(265, handoff, side: .45, signal: .65),
      _beat(410, handoff, side: .25, signal: .26),
      _beat(565, listening || speaking ? focus : blink, side: -.17),
      _beat(735, alert, lift: .13),
      _beat(990, rest),
    ],
    _GestureReaction.doubleTap => [
      _beat(0, rest),
      _beat(430, rest),
      _beat(565, alert, signal: .8),
      _beat(_doubleTapDodgeStartsAt, alert, signal: .8),
      _beat(_doubleTapDodgeAt, focus, side: -1),
      _beat(1350, focus, side: -1),
      _beat(_doubleTapQuestionAt, curious, side: -1),
      _beat(_doubleTapReturnAt, curious, side: -1),
      _beat(_doubleTapEndAt, rest),
    ],
    _GestureReaction.swipe => [
      _beat(0, rest),
      _beat(125, focus, side: 1, lift: -.15, signal: .65),
      _beat(330, curious, side: -.65, lift: .32),
      _beat(515, listening || speaking ? focus : blink, side: .3),
      _beat(690, handoff, lift: .18, signal: .30),
      _beat(950, rest),
    ],
    _GestureReaction.volley => [
      _beat(0, rest),
      _beat(
        105,
        [alert, scan, wink][variation],
        side: 1,
        lift: .35,
        signal: .88,
      ),
      _beat(285, variation == 1 ? alert : scan, side: -.85, signal: .7),
      _beat(495, [curious, wink, grin][variation], side: .62, lift: .35),
      _beat(740, variation == 0 ? wink : handoff, side: -.35, signal: .72),
      _beat(965, focus, side: .12),
      _beat(1240, rest),
    ],
    _GestureReaction.peek => [
      _beat(0, rest),
      _beat(180, droop, side: 1),
      _beat(410, curious, side: .65, signal: .28),
      _beat(575, droop, side: .88),
      _beat(760, droop, side: -.42),
      _beat(1120, rest),
    ],
    _GestureReaction.wake => [
      _beat(0, rest),
      _beat(130, droop, side: 1),
      _beat(295, alert, lift: 1, signal: 1),
      _beat(460, scan, side: -.8, signal: .88),
      _beat(620, scan, side: .72, signal: .68),
      _beat(810, wink, side: .3, lift: .25),
      _beat(1080, grin, lift: .42),
      _beat(1390, rest),
    ],
    _GestureReaction.rollOver => [
      _beat(0, rest),
      _beat(155, droop, side: 1, lift: -.3),
      _beat(360, curious, side: -.75),
      _beat(580, droop, side: -.40, lift: .1),
      _beat(830, rest),
    ],
  };
}

class _Animation extends ChangeNotifier {
  _Animation(this.status)
    : expression = status == EyeMood.stopped ? EyeMood.idle : status;

  final random = math.Random();
  EyeMood status;
  EyeMood expression;
  bool motion = true;
  bool desk = false;
  double leftInset = 0;
  bool keepAwake = false;
  int time = 0;
  int expressionAt = 0;
  int statusAt = 0;
  int? donePresentedAt;
  final completionNotice = ValueNotifier(false);
  int? _completionNoticeAt;

  @override
  void dispose() {
    completionNotice.dispose();
    super.dispose();
  }

  int lastInteractionAt = 0;
  int sleepSeconds = 90;
  int? localSleepAt;
  bool conversationActive = false;
  bool? _pendingConversationActive;
  int? conversationEndedAt;
  bool get conversationKeepsAwake =>
      keepAwake ||
      conversationActive ||
      (conversationEndedAt != null &&
          time - conversationEndedAt! < sleepSeconds * 1000);
  bool get sleeping =>
      (status == EyeMood.sleep || localSleepAt != null) &&
      wokeAt == null &&
      !conversationKeepsAwake;

  void setConversationActive(bool active) {
    if (_interacting) {
      _pendingConversationActive = active;
      return;
    }
    _pendingConversationActive = null;
    if (conversationActive == active) return;
    conversationActive = active;
    conversationEndedAt = active ? null : time;
    lastInteractionAt = time;
    localSleepAt = null;
  }

  int idleMoodAt = 10000;
  int glanceAt = 1900;
  int glanceEnd = 0;
  int nextBlink = 1900;
  int blinkAt = -1000;
  bool doubleBlink = false;
  EyeMood? idleMood;
  int idleMoodEnd = 0;
  Offset glance = Offset.zero;
  Offset gaze = Offset.zero;
  int? noticeAt;
  double? voiceLevel;
  int? speechDetectedAt;
  double voiceEnergy = 0;
  int? speakingAt;
  double speechPresence = 0;
  double syllable = 0;
  double emphasis = 0;
  Offset pupil = Offset.zero;
  double spacing = .18;
  double tilt = 0;
  Size sceneSize = Size.zero;
  Offset touch = Offset.zero;
  Offset touchVelocity = Offset.zero;
  int touchEventAt = 0;
  int touchMovedAt = 0;
  int contactParticlesAt = 0;
  Offset tapOrigin = Offset.zero;
  bool tapMoved = false;
  Offset stillAnchor = Offset.zero;
  int? pressedAt;
  PointerDownEvent? press;
  bool sleepingPress = false;
  int stillAt = 0;
  bool held = false;
  bool puzzledAtAnchor = false;
  int puzzledUntil = 0;
  PointerUpEvent? pendingTap;
  int tapDeadline = 0;
  bool pairingTap = false;
  bool followingTouch = false;
  double sleepTouch = 0;
  double sleepTouchSide = 0;
  Offset sleepDrag = Offset.zero;
  EyeMood? pendingMood;
  int tapVariation = 0;
  _Reaction? reaction;
  static const _idleTapEyesAt = 1000;
  static const _idleTapReturnAt = 1500;
  static const _idleTapQuestionAt = 1700;
  static const _idleTapEndAt = 2700;
  ({int at, Offset point, Offset fromPupil, Offset fromGaze})? idleTap;
  bool get _canStartLookTap =>
      !sleeping &&
      reaction?.kind != _GestureReaction.wake &&
      (status == EyeMood.thinking ||
          ((status == EyeMood.idle || wokeAt != null) &&
              !conversationActive &&
              voiceLevel == null &&
              speakingAt == null));
  PointerUpEvent? lastTap;
  int alternations = 0;
  Offset dragDirection = Offset.zero;
  int? wokeAt;
  _Look? _workingLook;
  int workTime = 0;
  bool _working = false;
  ({int at, Offset pupil, Offset gaze})? _workReturn;

  _Look? get thought => _working ? _workingLook : null;
  final particles = <_Particle>[];
  _Face? displayed;
  _Face? morphFrom;
  Offset displayedOffset = Offset.zero;
  double displayedLean = 0;
  ({int at, Offset offset, double lean})? poseFrom;

  void update(EyeMood value) {
    if (_interacting) {
      pendingMood = value;
      return;
    }
    _applyMood(value);
    notifyListeners();
  }

  bool get _interacting =>
      press != null ||
      pendingTap != null ||
      reaction != null ||
      idleTap != null;

  void _applyMood(EyeMood value) {
    pendingMood = null;
    if (value == EyeMood.thinking && status == value) return;
    if (status == EyeMood.done &&
        value != EyeMood.done &&
        donePresentedAt != null) {
      _completionNoticeAt = time + (motion ? 275 : 0);
    }
    status = value;
    statusAt = time;
    donePresentedAt = null;
    lastInteractionAt = time;
    localSleepAt = null;
    pendingTap = lastTap = null;
    alternations = 0;
    reaction = null;
    idleTap = null;
    pairingTap = false;
    cancel();
    wokeAt = null;
    idleMood = null;
    idleMoodAt = time + _range(10000, 16000);
    nextBlink = time + _range(1900, 4000);
    _workingLook = null;
    _working = false;
    _workReturn = null;
    _change(value == EyeMood.stopped ? EyeMood.idle : value);
  }

  int _range(int low, int high) => low + random.nextInt(high - low);

  void down(PointerDownEvent event) {
    final previous = pendingTap;
    pairingTap =
        previous != null &&
        previous.kind == event.kind &&
        event.timeStamp >= previous.timeStamp &&
        event.timeStamp - previous.timeStamp <= kDoubleTapTimeout &&
        (previous.position - event.position).distance <= kDoubleTapSlop &&
        !_oppositeSides(previous.localPosition, event.localPosition);
    if (!pairingTap) _commitTap();
    if (!sleeping) lastInteractionAt = time;
    press = event;
    pressedAt = time;
    sleepingPress = sleeping;
    stillAt = time;
    touch = tapOrigin = stillAnchor = event.localPosition;
    touchVelocity = dragDirection = Offset.zero;
    touchEventAt = event.timeStamp.inMilliseconds;
    touchMovedAt = time;
    contactParticlesAt = time;
    if (motion) _emitParticles(at: touch);
    tapMoved = false;
    held = false;
    puzzledAtAnchor = false;
    puzzledUntil = 0;
  }

  void move(PointerMoveEvent event) {
    if (press == null) return;
    final point = event.localPosition;
    final eventAt = event.timeStamp.inMilliseconds;
    final delta = math.max(1, eventAt - touchEventAt);
    touchVelocity = Offset.lerp(
      touchVelocity,
      (point - touch) / delta.toDouble(),
      1 - math.exp(-delta / 36),
    )!;
    touchEventAt = eventAt;
    touchMovedAt = time;
    final deltaPosition = point - touch;
    if (deltaPosition.distance >= 2) {
      dragDirection = deltaPosition / deltaPosition.distance;
    }
    _positionTouch(point);
    // A drag owns this input sequence, including any unconfirmed first tap.
    if (tapMoved && pairingTap) {
      pairingTap = false;
      pendingTap = null;
    }
  }

  void _positionTouch(Offset point) {
    touch = point;
    if ((point - tapOrigin).distance > kTouchSlop) {
      tapMoved = true;
      idleTap = null;
    }
    if ((point - stillAnchor).distance > kTouchSlop) {
      stillAnchor = point;
      stillAt = time;
      puzzledAtAnchor = false;
    }
  }

  void cancel() {
    if (pairingTap) pendingTap = null;
    pairingTap = false;
    press = null;
    pressedAt = null;
    sleepingPress = false;
    held = false;
  }

  bool up(PointerUpEvent event) {
    final down = press;
    if (down == null) return false;
    final point = event.localPosition;
    _positionTouch(point);
    final wasSleeping = sleepingPress && sleeping;
    if (!wasSleeping) lastInteractionAt = time;
    final dragged = tapMoved;
    final wasHeld =
        held || event.timeStamp - down.timeStamp >= kLongPressTimeout;
    final doubleTap = pairingTap && !dragged && !wasHeld;
    cancel();
    if (dragged) {
      lastTap = null;
      alternations = 0;
      final displacement = point - down.localPosition;
      _react(
        wasSleeping ? _GestureReaction.rollOver : _GestureReaction.swipe,
        point,
        direction: dragDirection != Offset.zero
            ? dragDirection
            : displacement / math.max(1, displacement.distance),
      );
    } else if (doubleTap) {
      lastTap = null;
      alternations = 0;
      _react(
        wasSleeping ? _GestureReaction.wake : _GestureReaction.doubleTap,
        point,
      );
    } else if (wasHeld) {
      lastTap = null;
      alternations = 0;
      _react(wasSleeping ? _GestureReaction.peek : _GestureReaction.tap, point);
    } else {
      final previous = lastTap;
      final alternating =
          previous != null &&
          previous.kind == event.kind &&
          event.timeStamp >= previous.timeStamp &&
          event.timeStamp - previous.timeStamp <=
              const Duration(milliseconds: 620) &&
          _oppositeSides(previous.localPosition, point);
      lastTap = event;
      if (alternating) {
        alternations++;
        _react(
          wasSleeping ? _GestureReaction.peek : _GestureReaction.volley,
          point,
          variation: alternations == 1 ? 0 : 1 + alternations % 2,
        );
      } else {
        alternations = 0;
        if (_canStartLookTap) {
          final interrupted = reaction != null;
          reaction = null;
          idleTap = (
            at: time,
            point: point,
            fromPupil: pupil,
            fromGaze: gaze,
          );
          glanceEnd = idleMoodEnd = time;
          glanceAt = time + _idleTapEndAt + _range(1500, 2800);
          idleMoodAt = time + _idleTapEndAt + _range(8500, 12500);
          nextBlink = glanceAt;
          _change(EyeMood.idle, interrupted: interrupted);
        }
      }
      // Even a volley tap can begin a deliberate same-side double tap.
      pendingTap = event;
      tapDeadline = time + kDoubleTapTimeout.inMilliseconds;
    }
    return doubleTap;
  }

  bool _oppositeSides(Offset first, Offset second) {
    final frame = _frame(sceneSize, desk, leftInset);
    final center = frame.center.dx;
    final margin = math.min(23.0, frame.width * .075);
    return (first.dx < center - margin && second.dx > center + margin) ||
        (second.dx < center - margin && first.dx > center + margin);
  }

  void _commitTap() {
    final tap = pendingTap;
    if (tap == null) return;
    pendingTap = null;
    if (alternations > 0 || idleTap != null) return;
    _react(
      sleeping ? _GestureReaction.peek : _GestureReaction.tap,
      tap.localPosition,
    );
  }

  void _react(
    _GestureReaction kind,
    Offset point, {
    Offset direction = Offset.zero,
    int? variation,
  }) {
    // Let a committed wake-up finish before accepting another expression.
    if (reaction?.kind == _GestureReaction.wake ||
        (reaction?.kind == _GestureReaction.doubleTap &&
            kind == _GestureReaction.tap)) {
      return;
    }
    _capturePose();
    idleTap = null;
    reaction = _Reaction(
      kind,
      time,
      point,
      direction,
      _choreography(
        kind,
        status,
        variation ?? (kind == _GestureReaction.tap ? tapVariation++ % 3 : 0),
        voiceLevel != null,
        speakingAt != null,
      ),
      displayed,
      gaze,
      pupil,
    );
    if (desk &&
        motion &&
        (kind == _GestureReaction.doubleTap || kind == _GestureReaction.wake)) {
      _emitParticles();
    }
  }

  void _emitParticles({Offset? at, int? count}) {
    final frame = _frame(sceneSize, desk, leftInset);
    final tap = at != null;
    final amount = count ?? (tap ? 12 : 8);
    for (var index = 0; index < amount; index++) {
      final side = index.isEven ? -1 : 1;
      particles.add(
        _Particle(
          at ??
              Offset(
                frame.center.dx + side * frame.width * .32,
                frame.top + frame.height * (.37 + (index ~/ 2) * .046),
              ),
          time,
          _range(460, 820),
          Offset(
            side * (.04 + random.nextDouble() * .13),
            (tap ? .07 : .025) + random.nextDouble() * .13,
          ),
          .006 + random.nextDouble() * .008,
          random.nextDouble() * 2 * math.pi,
          (random.nextDouble() - .5) * 3.5,
          const [
            Color(0xff74f4ff),
            Color(0xffa392ff),
            Color(0xfff494ef),
          ][index % 3],
          index % 3 == 0,
        ),
      );
    }
    if (particles.length > 60) {
      particles.removeRange(0, particles.length - 60);
    }
  }

  void _capturePose() {
    poseFrom = (at: time, offset: displayedOffset, lean: displayedLean);
  }

  void _change(EyeMood next, {bool interrupted = false}) {
    if (next == expression && !interrupted) return;
    _capturePose();
    morphFrom = displayed;
    expression = next;
    expressionAt = time;
  }

  void setNotice(bool active) {
    noticeAt = active ? time : null;
    if (!active) return;
    if (sleeping) {
      final frame = _frame(sceneSize, desk, leftInset);
      _react(_GestureReaction.wake, frame.centerRight);
    } else if (status == EyeMood.idle || wokeAt != null) {
      lastInteractionAt = time;
    }
  }

  void setSpeaking(bool speaking) {
    speakingAt = speaking ? (speakingAt ?? time) : null;
  }

  void step(int now) {
    final frameTime = now - time;
    final elapsed = frameTime.clamp(1, 50);
    time = now;
    if (motion && press != null && time - contactParticlesAt >= 110) {
      contactParticlesAt = time;
      _emitParticles(at: touch, count: 3);
    }
    final detectedAt = speechDetectedAt;
    final detection = detectedAt == null
        ? 0.0
        : .82 * (1 - _ease((time - detectedAt - 110) / 290));
    final voiceTarget = math.max(math.sqrt(_unit(voiceLevel ?? 0)), detection);
    voiceEnergy = motion
        ? _mix(
            voiceEnergy,
            voiceTarget,
            1 - math.exp(-elapsed / (voiceTarget > voiceEnergy ? 62 : 170)),
          )
        : 0;
    if (!pairingTap && pendingTap != null && time >= tapDeadline) {
      _commitTap();
    }
    if (idleTap case final tap? when time - tap.at >= _idleTapEndAt) {
      idleTap = null;
    }
    if (reaction case final active?
        when time - active.at >= active.duration ||
            (!motion && active.kind == _GestureReaction.wake)) {
      if (active.kind == _GestureReaction.wake) {
        wokeAt = lastInteractionAt = time;
        localSleepAt = null;
      }
      _change(expression, interrupted: true);
      reaction = null;
    }
    if (_pendingConversationActive case final active? when !_interacting) {
      setConversationActive(active);
    }
    if (pendingMood case final mood? when !_interacting) {
      _applyMood(mood);
    }
    final noticeAt = _completionNoticeAt;
    completionNotice.value =
        noticeAt != null && time >= noticeAt && time - noticeAt < 9000;
    final reacting = reaction;
    final priorWake = wokeAt;
    if (priorWake != null && time - lastInteractionAt >= sleepSeconds * 1000) {
      wokeAt = null;
    }
    if (status == EyeMood.idle &&
        reaction == null &&
        idleTap == null &&
        !conversationKeepsAwake &&
        wokeAt == null &&
        pressedAt == null &&
        pendingTap == null &&
        time - lastInteractionAt >= sleepSeconds * 1000) {
      localSleepAt ??= time;
    }
    final base = sleeping
        ? EyeMood.sleep
        : wokeAt != null || (status == EyeMood.sleep && conversationKeepsAwake)
        ? EyeMood.idle
        : status;
    var next =
        base == EyeMood.stopped || (base == EyeMood.thinking && _interacting)
        ? EyeMood.idle
        : base;
    var tracking = false;
    var compress = false;
    var puzzling = false;
    final start = pressedAt;
    var attention = 1.0;
    var pupilOnlyPress = false;
    final playful = next == EyeMood.idle || next == EyeMood.focus;
    if (start != null) {
      if (!held && time - start >= kLongPressTimeout.inMilliseconds) {
        held = true;
        idleTap = null;
        stillAt = time;
        if (pairingTap) pendingTap = null;
        pairingTap = false;
      }
      final dragging = tapMoved || held;
      if (!sleepingPress) {
        pupilOnlyPress = !dragging && _canStartLookTap;
        if (playful && held && !puzzledAtAnchor && time - stillAt >= 1500) {
          puzzledAtAnchor = true;
          puzzledUntil = time + 950;
        }
        puzzling = held && time < puzzledUntil;
        if (dragging && playful && voiceLevel == null) {
          next = puzzling ? EyeMood.question : EyeMood.focus;
        }
        tracking = dragging || motion;
        compress = playful && voiceLevel == null && !pupilOnlyPress;
        attention = playful && voiceLevel == null ? 1 : .56;
      }
    } else if (idleTap case final tap?) {
      if (time - tap.at >= _idleTapQuestionAt) next = EyeMood.question;
    } else if (motion &&
        base != EyeMood.sleep &&
        (pendingTap != null ||
            reacting?.kind == _GestureReaction.tap ||
            reacting?.kind == _GestureReaction.swipe ||
            reacting?.kind == _GestureReaction.volley)) {
      tracking = true;
      attention = reacting == null || pendingTap != null
          ? .78
          : 1 - _ease((time - reacting.at) / reacting.duration);
    } else if (base == EyeMood.idle && motion) {
      if (time >= idleMoodAt) {
        idleMood = [
          EyeMood.done,
          EyeMood.hello,
          EyeMood.idea,
        ][random.nextInt(3)];
        idleMoodEnd = time + _range(1150, 1550);
        idleMoodAt = idleMoodEnd + _range(13000, 23000);
      }
      if (time < idleMoodEnd) next = idleMood ?? base;
      if (time >= glanceAt) {
        final side = random.nextBool() ? 1.0 : -1.0;
        glance = [
          Offset(side * .84, .04),
          Offset(side * .56, -.71),
          Offset(side * .60, .55),
          Offset(side * .08, -.74),
        ][random.nextInt(4)];
        glanceEnd = time + _range(660, 1340);
        glanceAt = glanceEnd + _range(2200, 4300);
      }
    }
    if (next == EyeMood.done && status == EyeMood.done) {
      donePresentedAt ??= followingTouch ? time : statusAt;
    }
    followingTouch = tracking || idleTap != null;
    _change(next);
    final readingAloud = speakingAt != null && next == EyeMood.hello;
    speechPresence = motion
        ? _mix(
            speechPresence,
            readingAloud ? 1 : 0,
            1 - math.exp(-elapsed / 58),
          )
        : readingAloud
        ? 1
        : 0;
    if (readingAloud) {
      final seconds = (time - speakingAt!) / 1000;
      // The TTS bridge reports playback state. Vary the pose with a local cadence.
      final phrase = .5 - .5 * math.cos(seconds * 2 * math.pi / 1.65);
      final beat = seconds * 4.6 + .24 * math.sin(seconds * 7);
      syllable = motion ? _pulse(beat % 1, 1) * (.48 + .52 * phrase) : .35;
      emphasis = motion ? phrase * syllable : 0;
    }
    final face = _frame(sceneSize, desk, leftInset);
    final lookPoint = start != null
        ? touch
        : idleTap?.point ??
              pendingTap?.localPosition ??
              reacting?.point ??
              touch;
    final sleepContact = motion && base == EyeMood.sleep && sleepingPress;
    final sleepAmount = sleepContact ? (tapMoved ? .42 : .32) : 0.0;
    final sleepEase = motion
        ? 1 - math.exp(-elapsed / (sleepContact ? 55 : 125))
        : 1.0;
    sleepTouch = _mix(sleepTouch, sleepAmount, sleepEase);
    sleepTouchSide = _mix(
      sleepTouchSide,
      ((lookPoint.dx - face.center.dx) / math.max(1, face.width) * 6).clamp(
        -1.0,
        1.0,
      ),
      sleepEase,
    );
    final displacement = touch - tapOrigin;
    final drag = sleepContact && tapMoved
        ? Offset(
            (displacement.dx / math.max(1, face.width)).clamp(-.35, .35),
            (displacement.dy / math.max(1, face.height)).clamp(-.30, .30),
          )
        : Offset.zero;
    sleepDrag = Offset.lerp(sleepDrag, drag, sleepEase)!;
    final centered = Offset(
      ((lookPoint.dx - face.left) / math.max(1, face.width) - .5).clamp(
        -.65,
        .65,
      ),
      ((lookPoint.dy - face.top) / math.max(1, face.height) -
              .445 -
              (next == EyeMood.focus ? .075 : 0))
          .clamp(-.55, .65),
    );
    final lead = motion && next == EyeMood.focus
        ? 78 * math.exp(-(time - touchMovedAt) / 110)
        : 0.0;
    final predicted = Offset(
      (touchVelocity.dx * lead / math.max(1, face.width)).clamp(-.18, .18),
      (touchVelocity.dy * lead / math.max(1, face.height)).clamp(-.15, .15),
    );
    final idleGlance = base == EyeMood.idle && time < glanceEnd
        ? glance
        : Offset.zero;
    final frameWidth = math.max(1.0, face.width);
    final frameHeight = math.max(1.0, face.height);
    // Keep the eyes and brows inside the space available around the face.
    Offset boundedGaze(Offset position) => Offset(
      position.dx.clamp(
        -math.min(.27, .15 + math.max(0, face.left - leftInset) / frameWidth),
        math.min(.27, .15 + math.max(0, sceneSize.width - face.right) / frameWidth),
      ),
      position.dy.clamp(
        -math.min(.24, .075 + math.max(0, face.top) / frameHeight),
        math.min(.25, .24 + math.max(0, sceneSize.height - face.bottom) / frameHeight),
      ),
    );
    final look = boundedGaze(Offset(centered.dx * .62, centered.dy * .56));
    final target = pupilOnlyPress
        ? gaze
        : tracking
        ? look * attention
        : Offset(idleGlance.dx * .082, idleGlance.dy * .063);
    final pupilTarget = tracking
        ? Offset(
            (centered.dx + predicted.dx) * 1.85 * attention,
            (centered.dy + predicted.dy) * 1.85 * attention,
          )
        : next == EyeMood.idea
        ? const Offset(0, -.18)
        : idleGlance;
    final working = next == EyeMood.thinking && motion && !_interacting;
    // Advance the reading sequence only while consecutive frames show it.
    if (working && _working) {
      workTime += frameTime;
    } else if (working && _workingLook != null) {
      _workReturn = (at: workTime, pupil: pupil, gaze: gaze);
    }
    _working = working;
    if (reacting?.kind == _GestureReaction.doubleTap &&
        motion &&
        start == null) {
      final age = time - reacting!.at;
      final toward = centered - reacting.fromGaze;
      final direction = toward.distance < .12
          ? Offset(toward.dx < 0 ? -1 : 1, 0)
          : toward / toward.distance;
      final dodge = boundedGaze(reacting.fromGaze - direction * .26);
      final looking = _ease((age - 55) / (_doubleTapLookAt - 55));
      final dodging = _ease(
        (age - _doubleTapDodgeStartsAt) /
            (_doubleTapDodgeAt - _doubleTapDodgeStartsAt),
      );
      final returning = _ease(
        (age - _doubleTapReturnAt) / (_doubleTapEndAt - _doubleTapReturnAt),
      );
      final looked = Offset.lerp(reacting.fromGaze, look, looking)!;
      final lookedPupil = Offset.lerp(
        reacting.fromPupil,
        centered * 1.85,
        _ease(age / 95),
      )!;
      gaze = Offset.lerp(
        Offset.lerp(looked, dodge, dodging),
        reacting.fromGaze,
        returning,
      )!;
      pupil = Offset.lerp(
        Offset.lerp(lookedPupil, direction * .80, dodging),
        reacting.fromPupil,
        returning,
      )!;
    } else if (idleTap case final tap? when !tracking) {
      final age = time - tap.at;
      final returning = _ease((age - _idleTapReturnAt) / 125);
      final swing = _ease((age - _idleTapEyesAt) / 125);
      gaze = motion
          ? Offset.lerp(
                  tap.fromGaze,
                  look,
                  swing,
                )! *
                (1 - returning)
          : Offset.zero;
      pupil = motion
          ? Offset.lerp(
                  tap.fromPupil,
                  Offset(centered.dx * 1.85, centered.dy * 1.85),
                  _ease(age / 90),
                )! *
                (1 - returning)
          : Offset.zero;
    } else if (working) {
      final previous = _workingLook;
      if (previous == null || workTime >= previous.end) {
        _workingLook = _look(previous);
      }
      final look = _workingLook!;
      final age = workTime - look.start;
      pupil = Offset.lerp(
        look.fromPupil,
        look.target,
        _ease(age / look.moveDuration),
      )!;
      gaze = Offset.lerp(
        look.fromGaze,
        Offset(look.target.dx * .083, look.target.dy * .067),
        _ease((age - 20) / (look.moveDuration + 65)),
      )!;
      if (_workReturn case final from?) {
        final progress = _ease((workTime - from.at) / 125);
        pupil = Offset.lerp(from.pupil, pupil, progress)!;
        gaze = Offset.lerp(from.gaze, gaze, progress)!;
        if (progress == 1) _workReturn = null;
      }
    } else {
      gaze = Offset.lerp(
        gaze,
        target,
        motion ? 1 - math.exp(-elapsed / (tracking ? 57 : 90)) : 1,
      )!;
      pupil = Offset.lerp(
        pupil,
        pupilTarget,
        motion ? 1 - math.exp(-elapsed / (tracking ? 29 : 155)) : 1,
      )!;
    }
    final distance = _unit(
      math.max(
        (touch.dx - sceneSize.width / 2).abs() /
            math.max(1, sceneSize.width / 2),
        (touch.dy - face.center.dy).abs() / math.max(1, sceneSize.height / 2),
      ),
    );
    spacing = _mix(
      spacing,
      compress
          ? _mix(.18, _mix(.143, .18, distance), math.max(0, attention))
          : .18,
      motion ? 1 - math.exp(-elapsed / 100) : 1,
    );
    final age = time - expressionAt;
    final doneAge = status == EyeMood.done
        ? time - (donePresentedAt ?? statusAt)
        : age;
    final turn = age % 15800 - 11000;
    final angle = switch (expression) {
      EyeMood.done =>
        math.sin((doneAge - 190) / 620 * 2 * math.pi) *
            .092 *
            _pulse(doneAge - 190, 620),
      EyeMood.sleep =>
        (age ~/ 15800).isEven
            ? -.148 * _pulse(turn, 3800)
            : .148 * _pulse(turn, 3800),
      EyeMood.hello =>
        math.sin((time - (speakingAt ?? time)) / 315) * .038 * speechPresence,
      _ => 0.0,
    };
    final followTilt = tracking && !pupilOnlyPress
        ? (centered.dx * .14 + predicted.dx * .244) * attention
        : 0.0;
    tilt = motion
        ? _mix(tilt, angle + followTilt, 1 - math.exp(-elapsed / 54))
        : 0;
    particles.removeWhere(
      (particle) => time - particle.at >= particle.duration,
    );
    notifyListeners();
  }

  // Each stop has its own travel time, dwell range, and optional blink.
  static const _readingStops = [
    (Offset(-.86, -.29), 145, 370, 505, null),
    (Offset(-.18, -.26), 65, 185, 265, null),
    (Offset(.70, -.22), 95, 510, 680, null),
    (Offset(-.77, .42), 80, 365, 510, 10),
    (Offset(.06, .44), 70, 200, 300, null),
    (Offset(.81, .46), 180, 680, 900, null),
    (Offset(.40, -.57), 220, 850, 1120, 375),
  ];
  static const _codeSettle = 200;

  _Look _look(_Look? previous) {
    final step = (previous?.step ?? -1) + 1;
    if (step == _readingStops.length) {
      return _Look(
        null,
        workTime,
        workTime + _codeSettle + 2000,
        105,
        Offset.zero,
        pupil,
        gaze,
        null,
      );
    }
    final (direction, moveDuration, minHold, maxHold, blinkDelay) =
        _readingStops[step];
    final target =
        direction +
        Offset(
          random.nextDouble() * .10 - .05,
          random.nextDouble() * .08 - .04,
        );
    return _Look(
      step,
      workTime,
      workTime + _range(minHold, maxHold),
      moveDuration,
      target,
      pupil,
      gaze,
      blinkDelay == null ? null : workTime + blinkDelay + _range(0, 36),
    );
  }

  double blink() {
    if (!motion || idleTap != null) return 1;
    final look = thought;
    if (look != null) {
      final blinkAt = look.blinkAt;
      if (blinkAt == null) return 1;
      final age = workTime - blinkAt;
      final closure = age < 65 ? _ease(age / 65) : 1 - _ease((age - 65) / 120);
      return 1 - .92 * closure;
    }
    if (expression != EyeMood.idle &&
        expression != EyeMood.question &&
        expression != EyeMood.focus &&
        !(expression == EyeMood.hello && speakingAt != null)) {
      return 1;
    }
    if (time >= nextBlink) {
      blinkAt = time;
      nextBlink =
          time +
          (expression == EyeMood.idle
              ? _range(1900, 4000)
              : _range(2600, 5700));
      doubleBlink = random.nextInt(4) == 0;
    }
    final age = time - blinkAt;
    return 1 -
        .92 *
            (doubleBlink && age >= 255
                ? _pulse(age - 255, 170)
                : _pulse(age, 185));
  }
}

class _Look {
  _Look(
    this.step,
    this.start,
    this.end,
    this.moveDuration,
    this.target,
    this.fromPupil,
    this.fromGaze,
    this.blinkAt,
  );
  final int start, end, moveDuration;
  final int? step, blinkAt;
  final Offset target, fromPupil, fromGaze;
}

class _Particle {
  _Particle(
    this.origin,
    this.at,
    this.duration,
    this.drift,
    this.size,
    this.angle,
    this.spin,
    this.color,
    this.filled,
  );
  final Offset origin, drift;
  final int at, duration;
  final double size, angle, spin;
  final Color color;
  final bool filled;
}

class _Eye {
  const _Eye(
    this.center,
    this.rx,
    this.ry, {
    this.pupil = 0,
    this.cross = 0,
    this.bend = 0,
    this.inset = 0,
    this.cheek = 0,
    this.crescent = 0,
    this.halfLid = 0,
    this.browY = 0,
    this.browTilt = 0,
    this.arch = 0,
    this.browWidth = 0,
  });
  final Offset center;
  final double rx, ry, pupil, cross, bend, inset, cheek, crescent, halfLid;
  final double browY, browTilt, arch, browWidth;

  _Eye mix(_Eye to, double amount) => _Eye(
    Offset.lerp(center, to.center, amount)!,
    _mix(rx, to.rx, amount),
    _mix(ry, to.ry, amount),
    pupil: _mix(pupil, to.pupil, amount),
    cross: _mix(cross, to.cross, amount),
    bend: _mix(bend, to.bend, amount),
    inset: _mix(inset, to.inset, amount),
    cheek: _mix(cheek, to.cheek, amount),
    crescent: _mix(crescent, to.crescent, amount),
    halfLid: _mix(halfLid, to.halfLid, amount),
    browY: _mix(browY, to.browY, amount),
    browTilt: _mix(browTilt, to.browTilt, amount),
    arch: _mix(arch, to.arch, amount),
    browWidth: _mix(browWidth, to.browWidth, amount),
  );

  _Eye aperture(double opening, {double? inset}) => _Eye(
    center + Offset(0, (1 - opening) * .024),
    rx,
    math.max(.013, ry * opening),
    pupil: pupil * math.min(1.0, opening),
    cross: cross,
    bend: bend,
    inset: inset ?? this.inset,
    cheek: cheek * opening,
    crescent: crescent,
    halfLid: halfLid,
    browY: browY + (1 - opening) * .02,
    browTilt: browTilt,
    arch: arch,
    browWidth: browWidth,
  );

  _Eye sleepLid({double? bend, double? halfLid}) => _Eye(
    center,
    rx,
    ry,
    pupil: pupil,
    bend: bend ?? this.bend,
    halfLid: halfLid ?? this.halfLid,
  );
}

class _Face {
  _Face(this.left, this.right, this.colors);
  final _Eye left, right;
  final List<Color> colors;
  _Face mix(_Face to, double t) => _Face(
    left.mix(to.left, t),
    right.mix(to.right, t),
    List.generate(3, (i) => Color.lerp(colors[i], to.colors[i], t)!),
  );
}

Rect _frame(Size size, bool desk, double leftInset) {
  final inset = leftInset.clamp(0.0, size.width).toDouble();
  final aspect = desk ? 1.55 : 624 / 596;
  final height = math.min(size.height, (size.width - inset) / aspect);
  return Rect.fromCenter(
    center: size.center(Offset(inset / 2, desk ? height * .055 : 0)),
    width: height * aspect,
    height: height,
  );
}

class _Painter extends CustomPainter {
  _Painter(this.model) : super(repaint: model);

  final _Animation model;
  static const palette = {
    EyeMood.thinking: [0xffaff7f5, 0xff52dce9, 0xff3588eb],
    EyeMood.question: [0xffffe6a0, 0xffffc161, 0xffff7845],
    EyeMood.done: [0xffcaffe3, 0xff70f2b8, 0xff29b98c],
    EyeMood.error: [0xffffcbc2, 0xffff8279, 0xffe74263],
    EyeMood.sleep: [0xffcbbff3, 0xffa092df, 0xff6358a3],
    EyeMood.idle: [0xffe0eeff, 0xffa0c9f9, 0xff668ed9],
    EyeMood.focus: [0xffdbf2ff, 0xff8ccdff, 0xff608af5],
    EyeMood.hello: [0xfffff3be, 0xffffc89e, 0xffe48fc6],
    EyeMood.idea: [0xffffffcb, 0xff81f5de, 0xff55baff],
  };

  _Face _face(
    EyeMood expression,
    double blink,
    double aspect, {
    bool gesture = false,
  }) {
    final age = model.time - model.expressionAt;
    final swell = model.motion ? _pulse(age, 760) : 0.0;
    _Eye eye(int side) {
      final x = .5 + side * model.spacing;
      const y = .445;
      _Eye open(
        double cy,
        double width,
        double height, {
        double? openness,
        double brow = .145,
        double browWidth = .024,
        double? lean,
        double arch = 0,
        double inset = 0,
        double cheek = 0,
      }) {
        final visible = _unit(((openness ?? blink) - .18) / .82);
        return _Eye(
          Offset(x, cy),
          math.min(width * .46, height * .37 / aspect),
          _mix(.014, height / 2, visible),
          pupil: visible,
          browY: brow,
          browTilt: lean ?? -side * .018,
          arch: arch,
          browWidth: browWidth,
          inset: inset * visible,
          cheek: cheek * visible,
        );
      }

      switch (expression) {
        case EyeMood.stopped:
        case EyeMood.idle:
          return open(y, .275, .432);
        case EyeMood.thinking:
          final reading = _unit(model.pupil.dy * 2);
          return open(y, .30, .405, brow: .175, inset: reading * .022);
        case EyeMood.idea:
          return open(
            y - .023,
            .327,
            .515 + swell * .039,
            brow: .092,
            openness: 1,
          );
        case EyeMood.question:
          final small =
              model.time < model.puzzledUntil && model.pressedAt != null
              ? _ease((model.pupil.dx + .44) / .88)
              : 1.0;
          final lift = model.motion && !gesture
              ? .026 * _pulse(age - 35, 370) - .009 * _pulse(age - 330, 230)
              : 0.0;
          final largeEye = open(
            y - .055,
            .285,
            .485,
            brow: gesture ? .138 : .085 - lift,
            lean: side * .035,
            arch: gesture ? .049 : .07,
          );
          final smallEye = open(
            y + .065,
            .25,
            .28,
            brow: .245 + lift * .30,
            lean: side * .035,
            arch: .042,
            inset: .019,
            cheek: side * .025,
          );
          return largeEye.mix(smallEye, side < 0 ? 1 - small : small);
        case EyeMood.done:
          final crescent = _Eye(
            Offset(x, y + .07 - swell * .037),
            .148 + swell * .007,
            .051,
            bend: .286 + swell * .028,
            crescent: 1,
          );
          final doneAge =
              model.time - (model.donePresentedAt ?? model.statusAt);
          final pop = model.motion && model.status == EyeMood.done
              ? _ease(doneAge / 105) * (1 - _ease((doneAge - 150) / 290))
              : 0.0;
          return crescent.mix(
            open(y - .016, .32, .49, openness: 1, browWidth: 0),
            pop,
          );
        case EyeMood.error:
          final shake = model.motion
              ? math.sin(age / 26) * (1 - _unit(age / 410)) * .021
              : 0.0;
          return _Eye(
            Offset(x + shake, y + side * .025),
            0,
            0,
            cross: 1,
            browY: .205 + side * .015,
            browTilt: -side * .104,
            arch: .013,
            browWidth: .024,
          );
        case EyeMood.sleep:
          final breath = model.motion
              ? (1 - math.cos(2 * math.pi * age / 4200)) / 2
              : 0.0;
          return _Eye(
            Offset(x, y + .04 - breath * .018),
            .126 + breath * .008,
            .014 + breath * .005,
            bend: -.065 - breath * .019,
          );
        case EyeMood.focus:
          final proximity = _ease((model.pupil.dx * side - .045) / .68);
          final voice = model.voiceEnergy;
          final response = model.desk ? voice : 0.0;
          final raised = model.desk && model.voiceLevel != null ? .024 : 0.0;
          final accent = response * math.sin(model.time / 330);
          return open(
            y - raised - .022 * voice - .035 * response + side * .016 * accent,
            (.253 + .016 * voice + .032 * response) * (1 - proximity * .14),
            (.401 + .105 * voice + .035 * response) * (1 - proximity * .24),
            brow:
                .151 +
                proximity * .048 -
                .045 * voice -
                raised -
                .024 * response +
                side * .018 * accent,
            lean: -side * (.108 - .072 * voice) + .11 * accent,
            arch: .026 + .021 * voice + .021 * response,
          );
        case EyeMood.hello:
          final hop = model.motion ? _pulse(age, 680) : 0.0;
          final wink = model.motion && side < 0
              ? 1 - .89 * _pulse(age - 410, 520)
              : 1.0;
          final greeting = open(
            y - hop * .052 + (side < 0 ? .02 : 0),
            .29,
            side < 0 ? .403 : .458,
            brow: .145 - hop * .04,
            arch: .035,
            openness: wink,
          );
          final speaking = model.speechPresence;
          if (speaking < .01) return greeting;
          final beat = model.syllable;
          return greeting.mix(
            open(
              y - .045 + .039 * beat + side * .012 * model.emphasis,
              .298,
              .406 + .073 * beat,
              brow: .133 - .042 * model.emphasis + side * .012 * beat,
              lean: -side * .12,
              arch: .064,
              openness: blink,
            ),
            speaking,
          );
      }
    }

    return _Face(eye(-1), eye(1), palette[expression]!.map(Color.new).toList());
  }

  @override
  void paint(Canvas canvas, Size size) {
    model.sceneSize = size;
    final frame = _frame(size, model.desk, model.leftInset);
    final w = frame.width;
    final h = frame.height;
    if (w <= 0 || h <= 0) return;
    final expression = model.expression;
    final noticeAge = model.time - (model.noticeAt ?? -2000);
    final reacting =
        model.motion &&
        !model.followingTouch &&
        (expression == EyeMood.idle || expression == EyeMood.stopped) &&
        noticeAge < 1050;
    final glance = reacting
        ? _ease(noticeAge / 180) * (1 - _ease((noticeAge - 520) / 480))
        : 0.0;
    final blink =
        model.blink() * (reacting ? 1 - .88 * _pulse(noticeAge - 320, 210) : 1);
    var face = _face(expression, blink, w / h);
    final age = model.time - model.expressionAt;
    final morphDuration = expression == EyeMood.done || model.followingTouch
        ? 145
        : 275;
    final progress = model.motion ? _ease(age / morphDuration) : 1.0;
    final previous = model.morphFrom;
    if (previous != null && progress < 1) face = previous.mix(face, progress);
    final reaction = model.reaction;
    var offset = model.sleepDrag * .27;
    var signal = 0.0;
    var signalSide = 0.0;
    var lean = model.sleepDrag.dx * .75;
    var detailsProgress = progress;
    int? gestureQuestionAge;
    var gestureQuestionOpacity = 1.0;
    if (expression == EyeMood.sleep && model.sleepTouch > .002) {
      final awake = _face(EyeMood.idle, 1, w / h);
      final side = model.sleepTouchSide;
      face = _Face(
        face.left.mix(
          awake.left.sleepLid(halfLid: 1),
          model.sleepTouch * (.5 - side * .5),
        ),
        face.right.mix(
          awake.right.sleepLid(halfLid: 1),
          model.sleepTouch * (.5 + side * .5),
        ),
        face.colors,
      );
    }
    if (reaction != null) {
      final age = model.time - reaction.at;
      final kind = reaction.kind;
      final side = reaction.direction.dx.abs() > .25
          ? reaction.direction.dx.sign
          : reaction.point.dx <= frame.center.dx
          ? -1.0
          : 1.0;
      final beats = reaction.beats;
      final index = beats.indexWhere((beat) => beat.at > age);
      if (model.motion && index > 0) {
        final previous = beats[index - 1], next = beats[index];
        final progress = _ease((age - previous.at) / (next.at - previous.at));
        final original = face;
        face = _gestureFace(
          original,
          previous,
          kind,
          side,
          w / h,
        ).mix(_gestureFace(original, next, kind, side, w / h), progress);
        if (reaction.from case final from? when age < 115) {
          face = from.mix(face, _ease(age / 115));
        }
        final turn = side * _mix(previous.side, next.side, progress);
        final lift = _mix(previous.lift, next.lift, progress);
        if (kind != _GestureReaction.doubleTap) {
          offset += Offset(
            turn * .049,
            -lift * .049 + reaction.direction.dy * turn.abs() * .032,
          );
        }
        lean += turn * .115;
        signal = _mix(previous.signal, next.signal, progress);
        signalSide = turn;
        if (kind == _GestureReaction.wake) {
          detailsProgress *= 1 - _ease(age / 270);
        } else if (kind == _GestureReaction.doubleTap &&
            age >= _doubleTapQuestionAt) {
          gestureQuestionAge = age - _doubleTapQuestionAt;
          if (next.pose != _Pose.curious) {
            gestureQuestionOpacity = 1 - progress;
          }
        }
      } else if (!model.motion) {
        final pose = switch (kind) {
          _GestureReaction.peek || _GestureReaction.rollOver => _Pose.droop,
          _GestureReaction.tap ||
          _GestureReaction.volley ||
          _GestureReaction.doubleTap => _Pose.curious,
          _ => _Pose.alert,
        };
        face = _gestureFace(face, _beat(0, pose, side: 1), kind, side, w / h);
        if (kind == _GestureReaction.doubleTap) gestureQuestionAge = age;
      }
    }
    if (model.motion &&
        model.tapMoved &&
        model.pressedAt != null &&
        !model.sleepingPress) {
      final speed =
          _unit(model.touchVelocity.distance / 1.4) *
          math.exp(-(model.time - model.touchMovedAt) / 130);
      final bias = model.pupil.dx.clamp(-1.0, 1.0);
      final voice = model.voiceLevel != null || model.speakingAt != null;
      final squeeze = speed * (voice ? .11 : .27);
      face = _Face(
        face.left.aperture(1 - squeeze * (1 - bias)),
        face.right.aperture(1 - squeeze * (1 + bias)),
        face.colors,
      );
      if (speed > signal && !voice) {
        signal = speed * .72;
        signalSide = bias;
      }
    }
    if (model.poseFrom case final from?
        when model.motion && model.time - from.at < 115) {
      final handoff = _ease((model.time - from.at) / 115);
      offset = Offset.lerp(from.offset, offset, handoff)!;
      lean = _mix(from.lean, lean, handoff);
    }
    model.displayed = face;
    model.displayedOffset = offset;
    model.displayedLean = lean;
    canvas.save();
    canvas.translate(frame.left, frame.top);
    canvas.save();
    canvas.translate(w * (.5 + offset.dx), h * (.46 + offset.dy));
    canvas.rotate(model.tilt + lean);
    canvas.translate(-w * .5, -h * .46);
    final thought = model.thought;
    final code = thought != null && thought.step == null
        ? model.workTime - thought.start - _Animation._codeSettle
        : -1;
    canvas.translate(w * .036 * glance, h * .028 * glance);
    final eyeColors = glance == 0
        ? face.colors
        : List.generate(
            3,
            (i) => Color.lerp(
              face.colors[i],
              Color(palette[EyeMood.thinking]![i]),
              glance * .72,
            )!,
          );
    _eye(canvas, face.left, eyeColors, w, h, true, code);
    _eye(canvas, face.right, eyeColors, w, h, false, code);
    if (gestureQuestionAge case final age?) {
      _questionMark(
        canvas,
        Offset(w * (.81 + model.gaze.dx).clamp(.08, .92), h * (.14 + model.gaze.dy)),
        h * .18,
        face.colors[0],
        age,
        strength: gestureQuestionOpacity,
      );
    }
    if (signal > .01) _gestureSignal(canvas, face, w, h, signal, signalSide);
    if (model.desk && expression == EyeMood.focus && model.voiceLevel != null) {
      _listeningBars(canvas, face.colors[1], w, h, progress);
    }
    if ((expression == EyeMood.hello || expression == EyeMood.idle) &&
        model.speechPresence >= .01) {
      _speechMouth(canvas, w, h);
    }
    canvas.restore();
    if (reaction?.kind != _GestureReaction.doubleTap ||
        expression != EyeMood.question) {
      _details(canvas, expression, face.colors[0], w, h, age, detailsProgress);
    }
    canvas.restore();
    _drawParticles(canvas, h);
  }

  _Face _gestureFace(
    _Face base,
    _Beat beat,
    _GestureReaction kind,
    double side,
    double aspect,
  ) {
    final pose = beat.pose;
    final wake = kind == _GestureReaction.wake;
    if (pose == _Pose.rest) {
      return wake && beat.at > 0 ? _face(EyeMood.idle, 1, aspect) : base;
    }
    final nearLeft = side * (beat.side < 0 ? -1 : 1) < 0;
    final awake = _face(EyeMood.idle, 1, aspect);
    if (kind == _GestureReaction.peek || kind == _GestureReaction.rollOver) {
      final opening = pose == _Pose.curious ? .58 : .27;
      return _Face(
        base.left.mix(
          awake.left.sleepLid(halfLid: .85, bend: -.012),
          nearLeft ? opening : .04,
        ),
        base.right.mix(
          awake.right.sleepLid(halfLid: .85, bend: -.012),
          nearLeft ? .04 : opening,
        ),
        base.colors,
      );
    }
    final activeVoice = model.voiceLevel != null || model.speakingAt != null;
    final operational =
        activeVoice ||
        model.status == EyeMood.thinking ||
        model.status == EyeMood.question ||
        model.status == EyeMood.error;
    if (wake && pose == _Pose.droop) {
      return _Face(
        base.left.mix(awake.left.sleepLid(halfLid: 1), nearLeft ? .72 : .18),
        base.right.mix(awake.right.sleepLid(halfLid: 1), nearLeft ? .18 : .72),
        base.colors,
      );
    }
    final source = wake ? awake : base;
    final target = switch (pose) {
      _Pose.alert => _face(EyeMood.idea, 1, aspect),
      _Pose.grin => _face(EyeMood.done, 1, aspect),
      _Pose.curious => _face(EyeMood.question, 1, aspect, gesture: true),
      _ => source,
    };
    if (kind == _GestureReaction.doubleTap) {
      if (pose == _Pose.focus) {
        return _Face(
          awake.left.aperture(nearLeft ? .43 : .62),
          awake.right.aperture(nearLeft ? .62 : .43),
          base.colors,
        );
      }
      return target;
    }

    _Eye eye(_Eye from, _Eye to, bool near) {
      switch (pose) {
        case _Pose.blink:
        case _Pose.wink:
          if (pose == _Pose.wink && !near) return from.aperture(1.06);
          return from.aperture(activeVoice ? .72 : .16);
        case _Pose.scan:
        case _Pose.focus:
          return from.aperture(near ? .64 : .87, inset: .016);
        default:
          if (model.status == EyeMood.error) return from;
          return from.mix(
            to,
            operational
                ? .25
                : near || pose != _Pose.curious
                ? .91
                : .43,
          );
      }
    }

    return _Face(
      eye(source.left, target.left, nearLeft),
      eye(source.right, target.right, !nearLeft),
      operational ? base.colors : source.mix(target, .72).colors,
    );
  }

  void _gestureSignal(
    Canvas canvas,
    _Face face,
    double w,
    double h,
    double strength,
    double side,
  ) {
    for (final sign in [-1, 1]) {
      final eye = sign < 0 ? face.left : face.right;
      final intensity = strength * (.66 + sign * side * .30);
      final center = eye.center + model.gaze;
      final x = (center.dx + sign * (eye.rx + .024)) * w;
      final y = (center.dy - eye.ry * .63) * h;
      final length = h * (.025 + intensity * .027);
      final trace = Path()
        ..moveTo(x - sign * length, y - length * .42)
        ..lineTo(x - sign * length * .40, y - length * .42)
        ..lineTo(x, y)
        ..lineTo(x, y + length);
      canvas.drawPath(
        trace,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = h * .006
          ..color = face.colors[0].withValues(alpha: intensity),
      );
      canvas.drawCircle(
        Offset(x, y + length * 1.65),
        h * .005,
        Paint()..color = face.colors[1].withValues(alpha: intensity * .75),
      );
    }
  }

  void _listeningBars(
    Canvas canvas,
    Color color,
    double w,
    double h,
    double progress,
  ) {
    final energy = model.voiceEnergy;
    final paint = Paint()
      ..color = color.withAlpha((progress * (150 + 105 * energy)).round());
    for (var index = -2; index <= 2; index++) {
      final ripple = .5 + .5 * math.sin(model.time / 75 + index * 1.55);
      final height =
          h *
          (.013 + energy * (.025 + .058 * ripple) * (1 - .17 * index.abs()));
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(w * .5 + h * index * .041, h * .745),
            width: h * .016,
            height: height,
          ),
          Radius.circular(h * .008),
        ),
        paint,
      );
    }
  }

  void _speechMouth(Canvas canvas, double w, double h) {
    final amount = model.speechPresence;
    final beat = model.syllable;
    final center = Offset(w * .5, h * (.737 + .015 * beat));
    final halfWidth = h * (.123 - .047 * beat);
    final opening = h * (.028 + .112 * beat) * amount;
    final shape = Path()
      ..moveTo(center.dx - halfWidth, center.dy)
      ..quadraticBezierTo(
        center.dx,
        center.dy + h * .011 * amount,
        center.dx + halfWidth,
        center.dy,
      )
      ..cubicTo(
        center.dx + halfWidth * .62,
        center.dy + opening,
        center.dx - halfWidth * .62,
        center.dy + opening,
        center.dx - halfWidth,
        center.dy,
      )
      ..close();
    canvas.drawPath(
      shape,
      Paint()
        ..color = const Color(0xffffc89e).withAlpha((220 * amount).round()),
    );
    canvas.drawPath(
      shape,
      Paint()
        ..color = const Color(0xffffe6bb).withAlpha((230 * amount).round())
        ..style = PaintingStyle.stroke
        ..strokeWidth = h * .008
        ..strokeJoin = StrokeJoin.round,
    );
  }

  void _eye(
    Canvas canvas,
    _Eye eye,
    List<Color> colors,
    double w,
    double h,
    bool left,
    int code,
  ) {
    const white = Color(0xffffffff);
    const black = Color(0xff000000);
    final center = eye.center + model.gaze;
    final cx = center.dx * w, cy = center.dy * h;
    final rx = eye.rx * w, ry = eye.ry * h;
    if (rx > .5 && ry > .5) {
      var shape = _outline(eye, cx, cy, rx, ry, h);
      if (eye.crescent > 0 && eye.bend * 3.25 > .004) {
        final metrics = shape.computeMetrics(forceClosed: true).first;
        final bent = Path();
        final angle = eye.bend * 3.25;
        final radius = rx / angle;
        for (var i = 0; i < 96; i++) {
          final pos = metrics
              .getTangentForOffset(metrics.length * i / 96)
              ?.position;
          if (pos == null) continue;
          final u = ((pos.dx - cx) / rx).clamp(-1, 1);
          final a = u * angle;
          final thickness = 1 + (.20 - .31 * u * u) * eye.crescent;
          final offset = (pos.dy - cy) * thickness;
          final x = cx + (radius - offset) * math.sin(a);
          final y =
              cy +
              radius * (math.cos(angle) - math.cos(a)) +
              offset * math.cos(a);
          if (i == 0) {
            bent.moveTo(x, y);
          } else {
            bent.lineTo(x, y);
          }
        }
        bent.close();
        shape = bent;
      }

      final listening = model.expression == EyeMood.focus;
      final voice = listening ? model.voiceEnergy : 0.0;
      final breath = listening && model.voiceLevel != null && model.motion
          ? .10 * (1 - math.cos(model.time * 2 * math.pi / 2100))
          : 0.0;
      _drawHalo(
        canvas,
        shape,
        colors[1],
        h * (.076 + .022 * voice + .011 * breath),
        1 + .52 * voice + breath,
      );
      final paint = Paint()
        ..shader = _ellipticalGradient(
          Offset(cx, cy - eye.bend * h / 4),
          rx,
          ry + eye.bend.abs() * h / 4,
          colors,
          const [0, .52, 1],
        );
      canvas.drawPath(shape, paint);
      canvas.save();
      canvas.clipPath(shape);
      final rim = Paint()
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = math.min(h * .012, ry * .22)
        ..shader = ui.Gradient.linear(
          Offset(cx, cy - ry),
          Offset(cx, cy + ry),
          [
            Color.lerp(colors[0], white, .65)!.withAlpha(177),
            colors[0].withAlpha(48),
            Color.lerp(colors[2], black, .50)!.withAlpha(150),
          ],
          const [0, .48, 1],
        );
      canvas.drawPath(shape, rim);
      if (eye.pupil > .04) {
        canvas.translate(model.pupil.dx * rx * .24, model.pupil.dy * ry * .22);
        final codeBlend = _unit(math.min(code, 2000 - code) / 240);
        const pupilScale = .76 * .86;
        if (codeBlend < 1) {
          const glow = [
            4,
            6,
            8,
            11,
            14,
            17,
            20,
            23,
            26,
            29,
            34,
            39,
            44,
            50,
            57,
            65,
            76,
            88,
          ];
          final intensity = eye.pupil * (1 - codeBlend);
          final pupilPaint = Paint();
          for (var index = 0; index < glow.length; index++) {
            final f = index / (glow.length - 1);
            canvas.save();
            canvas.translate(cx, cy);
            canvas.scale(
              pupilScale * _mix(.995, .69, f),
              pupilScale * _mix(.99, .65, f),
            );
            canvas.translate(-cx, -cy);
            canvas.drawPath(
              shape,
              pupilPaint
                ..color = Color.lerp(
                  colors[0],
                  white,
                  .42 + .58 * f,
                )!.withAlpha((glow[index] * intensity).round()),
            );
            canvas.restore();
          }
          // Two soft reflections follow the pupil and fade into the code display.
          canvas.drawOval(
            Rect.fromCenter(
              center: Offset(cx - rx * .23, cy - ry * .40),
              width: rx * .36,
              height: ry * .105,
            ),
            pupilPaint..color = white.withAlpha((172 * intensity).round()),
          );
          canvas.drawCircle(
            Offset(cx + rx * .045, cy - ry * .40),
            math.min(rx, ry) * .047,
            pupilPaint..color = white.withAlpha((108 * intensity).round()),
          );
        }
        if (codeBlend > 0) {
          _code(
            canvas,
            Offset(cx, cy),
            rx * pupilScale,
            ry * pupilScale,
            code,
            codeBlend,
          );
        }
      }
      canvas.restore();
    }
    if (eye.cross > .001) {
      final dx = .069 * eye.cross * w;
      final dy = .115 * eye.cross * h;
      final stroke = Paint()
        ..strokeCap = StrokeCap.round
        ..strokeWidth = .069 * eye.cross * h
        ..shader = LinearGradient(colors: colors).createShader(
          Rect.fromCenter(
            center: Offset(cx, cy),
            width: 2 * dx,
            height: 2 * dy,
          ),
        );
      for (final sign in [-1, 1]) {
        final first = Offset(cx - dx, cy - sign * dy);
        final last = Offset(cx + dx, cy + sign * dy);
        canvas.drawLine(
          first,
          last,
          Paint()
            ..strokeWidth = stroke.strokeWidth + h * .028
            ..strokeCap = StrokeCap.round
            ..color = colors[1].withAlpha(74),
        );
        canvas.drawLine(first, last, stroke);
      }
    }
    if (eye.browWidth > .001) {
      final y = (eye.browY + model.gaze.dy) * h;
      final first = Offset(cx - w * .077, y - eye.browTilt * h / 2);
      final end = Offset(cx + w * .077, y + eye.browTilt * h / 2);
      final control = Offset(cx, y - math.max(.046, eye.arch) * h);
      final brow = Path();
      Offset edge(double t, num side) {
        final a = Offset.lerp(first, control, t)!;
        final b = Offset.lerp(control, end, t)!;
        final tangent = b - a;
        final center = Offset.lerp(a, b, t)!;
        final inner = left ? t : 1 - t;
        final radius =
            (_mix(.24, .58, inner) + .15 * math.sin(math.pi * inner)) *
            eye.browWidth *
            1.22 *
            h;
        return center +
            Offset(tangent.dy, -tangent.dx) *
                (radius * side / tangent.distance);
      }

      void roundTip(double t, Offset direction, int side) {
        final from = edge(t, side);
        final to = edge(t, -side);
        // Extend the curve along its tangent to round off the tapered end.
        final extension =
            direction * ((to - from).distance * 2 / (3 * direction.distance));
        brow.cubicTo(
          from.dx + extension.dx,
          from.dy + extension.dy,
          to.dx + extension.dx,
          to.dy + extension.dy,
          to.dx,
          to.dy,
        );
      }

      final start = edge(0, 1);
      brow.moveTo(start.dx, start.dy);
      const segments = 16;
      for (var i = 1; i <= segments; i++) {
        final point = edge(i / segments, 1);
        brow.lineTo(point.dx, point.dy);
      }
      roundTip(1, end - control, 1);
      for (var i = segments - 1; i >= 0; i--) {
        final point = edge(i / segments, -1);
        brow.lineTo(point.dx, point.dy);
      }
      roundTip(0, first - control, -1);
      brow.close();

      final strength = _unit(eye.browWidth / .024);
      _drawHalo(canvas, brow, colors[1], h * .041, strength * .61);
      final bounds = brow.getBounds();
      canvas.drawPath(
        brow,
        Paint()
          ..shader = ui.Gradient.linear(
            Offset(cx, bounds.top),
            Offset(cx, bounds.bottom),
            [
              Color.lerp(colors[0], white, .22)!.withAlpha(244),
              Color.lerp(colors[0], colors[1], .60)!.withAlpha(232),
              Color.lerp(colors[1], colors[2], .64)!.withAlpha(214),
            ],
            const [0, .48, 1],
          ),
      );

      final highlight = Path();
      final highlightStart = edge(.12, .52);
      final highlightEnd = edge(.88, .52);
      highlight.moveTo(highlightStart.dx, highlightStart.dy);
      for (var index = 1; index <= segments; index++) {
        final point = edge(.12 + .76 * index / segments, .52);
        highlight.lineTo(point.dx, point.dy);
      }
      final sheen = Color.lerp(colors[0], white, .82)!;
      canvas.save();
      canvas.clipPath(brow);
      canvas.drawPath(
        highlight,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = eye.browWidth * h * .23
          ..shader = ui.Gradient.linear(
            highlightStart,
            highlightEnd,
            [sheen.withAlpha(0), sheen.withAlpha(196), sheen.withAlpha(0)],
            [0, left ? .65 : .35, 1],
          ),
      );
      canvas.restore();
    }
  }

  void _drawHalo(
    Canvas canvas,
    Path shape,
    Color color,
    double width, [
    double strength = 1,
  ]) {
    const alpha = [2, 3, 4, 5, 7, 9, 12, 15, 18, 21, 24, 27];
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;
    for (var index = 0; index < alpha.length; index++) {
      paint
        ..color = color.withAlpha((alpha[index] * strength).round())
        ..strokeWidth = width * (1 - index / alpha.length);
      canvas.drawPath(shape, paint);
    }
  }

  ui.Shader _ellipticalGradient(
    Offset center,
    double rx,
    double ry,
    List<Color> colors,
    List<double> stops,
  ) => ui.Gradient.radial(
    Offset.zero,
    1,
    colors,
    stops,
    TileMode.clamp,
    Float64List.fromList([
      rx,
      0,
      0,
      0,
      0,
      ry,
      0,
      0,
      0,
      0,
      1,
      0,
      center.dx,
      center.dy,
      0,
      1,
    ]),
  );

  Path _outline(
    _Eye eye,
    double cx,
    double cy,
    double rx,
    double ry,
    double h,
  ) {
    final top = cy - ry * (1 - eye.halfLid * .52);
    final bottom = cy + ry * (1 - eye.halfLid);
    final corner = math.min(rx * .92, math.min(ry, (bottom - top) * .68));
    final restBend = math.min(0.0, eye.bend * h);
    final inset = eye.inset * h + eye.halfLid * ry * .035;
    final insetFraction = _unit(eye.inset / .019);
    final insetCorner = _mix(corner, math.min(corner, rx * .24), insetFraction);
    final lowerCorner = _mix(
      insetCorner,
      math.min(insetCorner, rx * .10),
      eye.halfLid,
    );
    final leftLift = math.max(0.0, -eye.cheek) * h;
    final rightLift = math.max(0.0, eye.cheek) * h;
    final topShoulder = restBend * corner / rx * .8;
    final bottomShoulder = restBend * lowerCorner / rx * .8;
    final leftBottom = bottom - leftLift;
    final rightBottom = bottom - rightLift;
    final cap = corner * .55;
    final bottomCap = lowerCorner * .55;
    final leftX = cx - rx + lowerCorner;
    final rightX = cx + rx - lowerCorner;
    final leftY = leftBottom - bottomShoulder;
    final rightY = rightBottom - bottomShoulder;
    final lowerControl = bottom - restBend + bottomShoulder - inset * 2;
    final rightControl =
        _mix(rightY, lowerControl, 2 / 3) - rightLift * insetFraction * .45;
    final leftControl =
        _mix(leftY, lowerControl, 2 / 3) - leftLift * insetFraction * .45;
    final outline = Path();
    void lid(
      double fromX,
      double fromY,
      double middle,
      double toX,
      double toY,
    ) {
      outline.cubicTo(
        _mix(fromX, cx, .4),
        fromY,
        _mix(fromX, cx, .6),
        middle,
        cx,
        middle,
      );
      outline.cubicTo(
        _mix(cx, toX, .4),
        middle,
        _mix(cx, toX, .6),
        toY,
        toX,
        toY,
      );
    }

    final topEdge = top - topShoulder;
    outline.moveTo(cx - rx + corner, topEdge);
    if (restBend < 0) {
      lid(
        cx - rx + corner,
        topEdge,
        _mix(topEdge, top - restBend * .5, 1 - corner / rx),
        cx + rx - corner,
        topEdge,
      );
    } else {
      outline.lineTo(cx + rx - corner, topEdge);
    }
    outline
      ..cubicTo(
        cx + rx - corner + cap,
        topEdge,
        cx + rx,
        top + corner - cap,
        cx + rx,
        top + corner,
      )
      ..lineTo(cx + rx, rightBottom - lowerCorner)
      ..cubicTo(
        cx + rx,
        rightBottom - lowerCorner + bottomCap,
        rightX + bottomCap,
        rightY,
        rightX,
        rightY,
      );
    if (restBend < 0) {
      final shoulder = (rightY + leftY) * .5;
      final curve = (shoulder + 1.5 * (rightControl + leftControl)) * .25;
      lid(
        rightX,
        rightY,
        _mix(shoulder, curve, 1 - lowerCorner / rx),
        leftX,
        leftY,
      );
    } else {
      outline.cubicTo(
        _mix(rightX, cx, 2 / 3),
        rightControl,
        _mix(leftX, cx, 2 / 3),
        leftControl,
        leftX,
        leftY,
      );
    }
    return outline
      ..cubicTo(
        leftX - bottomCap,
        leftY,
        cx - rx,
        leftBottom - lowerCorner + bottomCap,
        cx - rx,
        leftBottom - lowerCorner,
      )
      ..lineTo(cx - rx, top + corner)
      ..cubicTo(
        cx - rx,
        top + corner - cap,
        cx - rx + corner - cap,
        topEdge,
        cx - rx + corner,
        topEdge,
      )
      ..close();
  }

  void _code(
    Canvas canvas,
    Offset center,
    double rx,
    double ry,
    int age,
    double progress,
  ) {
    final rect = Rect.fromCenter(center: center, width: rx * 2, height: ry * 2);
    canvas.drawOval(
      rect,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xff04150c).withValues(alpha: progress),
            const Color(0xff081d12).withValues(alpha: .9 * progress),
            const Color(0x00081d12),
          ],
          stops: const [0, .62, 1],
        ).createShader(rect),
    );
    final columnWidth = 2 * rx / 7;
    final rowHeight = 2 * ry / 10;
    final size = math.min(columnWidth, rowHeight);
    for (var column = 0; column < 7; column++) {
      final x = center.dx + (column - 3) * columnWidth;
      final travel =
          (age + center.dx * 3) / (115 + (column % 3) * 33) + column * 2.3;
      final whole = travel.floor();
      for (var row = -1; row <= 10; row++) {
        final y = center.dy - ry + (row + travel - whole) * rowHeight;
        final distance = Offset(
          (x - center.dx) / rx,
          (y - center.dy) / ry,
        ).distanceSquared;
        final edge = _unit((1 - distance) / .55);
        if (edge == 0) continue;
        final stream = row - whole;
        final tail = (stream + column * 3) % 7;
        final reveal = .20 + (row * 11 + column * 17) % 13 * .05;
        if (progress < reveal) {
          canvas.drawRect(
            Rect.fromCenter(
              center: Offset(x, y),
              width: size * .84,
              height: size * .84,
            ),
            Paint()
              ..color = const Color(0xff43ff8b)
                  .withValues(alpha: .84 * edge * progress / reveal),
          );
        } else {
          final color = tail == 0
              ? const Color(0xffdcffd8)
              : const Color(0xff4bff83);
          _text(
            canvas,
            '${(stream ^ (stream >> 2) ^ column) & 1}',
            Offset(x, y),
            size * .86,
            color.withAlpha(((255 - tail * 27) * edge).round()),
            mono: true,
          );
        }
      }
    }
  }

  void _details(
    Canvas canvas,
    EyeMood mood,
    Color color,
    double w,
    double h,
    int age,
    double progress,
  ) {
    if (mood == EyeMood.question) {
      final small = model.time < model.puzzledUntil && model.pressedAt != null
          ? _ease((model.pupil.dx + .44) / .88)
          : 1.0;
      final x = (_mix(.19, .81, small) + model.gaze.dx).clamp(.08, .92);
      _questionMark(
        canvas,
        Offset(
          w * x,
          h *
              (.19 -
                  .05 * progress +
                  model.gaze.dy -
                  (1 - (2 * small - 1).abs()) * .035),
        ),
        h * .18,
        color,
        age,
      );
    } else if (mood == EyeMood.idea) {
      _text(
        canvas,
        '!',
        Offset(w * .86, h * .17),
        h * (.165 + _pulse(age, 550) * .026),
        const Color(0xffffe491),
      );
    } else if (mood == EyeMood.sleep) {
      if (!model.motion) {
        _text(
          canvas,
          'Z',
          Offset(w * .79, h * .25),
          h * .11,
          color.withAlpha(151),
        );
        _text(
          canvas,
          'z',
          Offset(w * .865, h * .177),
          h * .083,
          color.withAlpha(100),
        );
        return;
      }
      for (var i = 0; i < 2; i++) {
        final drift = ((age + 640 + i * 1440) % 3200) / 3200;
        final alpha = (185 * _pulse(drift, 1) * progress).round();
        _text(
          canvas,
          i == 0 ? 'Z' : 'z',
          Offset(w * (.76 + drift * .14), h * (.33 - drift * .20)),
          h * (.077 + drift * .039),
          color.withAlpha(alpha),
        );
      }
    } else if (mood == EyeMood.done && model.motion) {
      final doneAge = model.status == EyeMood.done
          ? model.time - (model.donePresentedAt ?? model.statusAt)
          : age;
      if (doneAge >= 720) return;
      final t = _unit(doneAge / 720);
      for (final side in [-1, 1]) {
        canvas.drawCircle(
          Offset(w * (.5 + side * (.28 + t * .12)), h * (.33 - t * .18)),
          h * (.01 + t * .012),
          Paint()
            ..color = color.withAlpha((200 * _pulse(doneAge, 720)).round()),
        );
      }
    }
  }

  void _questionMark(
    Canvas canvas,
    Offset center,
    double size,
    Color color,
    int age, {
    double strength = 1,
  }) {
    final entry = model.motion ? _unit(age / 430) : 1.0;
    final dotEntry = model.motion ? _unit((age - 75) / 360) : 1.0;
    final spring = Curves.easeOutBack.transform(entry);
    final dotSpring = Curves.easeOutBack.transform(dotEntry);
    final settle = 1 - _ease(entry);
    canvas.save();
    canvas.translate(center.dx, center.dy - size * .25 * settle);
    canvas.rotate(-.16 * settle);
    final scale = size * _mix(.62, 1, spring);
    canvas.scale(scale, scale);

    final hook = Path()
      ..moveTo(-.225, -.245)
      ..cubicTo(-.20, -.395, -.062, -.46, .075, -.426)
      ..cubicTo(.242, -.385, .284, -.240, .202, -.134)
      ..cubicTo(.145, -.063, .018, -.034, .006, .065)
      ..quadraticBezierTo(0, .091, 0, .125);
    final opacity = _ease(entry * 2.7) * strength;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(
      hook,
      stroke
        ..strokeWidth = .23
        ..color = color.withAlpha((42 * opacity).round()),
    );
    canvas.drawPath(
      hook,
      stroke
        ..strokeWidth = .14
        ..color = color.withAlpha((255 * opacity).round()),
    );
    final dotOpacity = _ease(dotEntry * 2.7) * strength;
    final dot = Offset(0, .347 + (1 - dotSpring) * .23);
    canvas.drawCircle(
      dot,
      .113 * dotSpring,
      Paint()..color = color.withAlpha((42 * dotOpacity).round()),
    );
    canvas.drawCircle(
      dot,
      .077 * dotSpring,
      Paint()..color = color.withAlpha((255 * dotOpacity).round()),
    );
    canvas.restore();
  }

  void _drawParticles(Canvas canvas, double h) {
    for (final particle in model.particles) {
      final progress = _unit((model.time - particle.at) / particle.duration);
      final remaining = 1 - progress;
      final travel = 1 - remaining * remaining;
      final size = particle.size * h * (.55 + .45 * remaining);
      canvas.save();
      canvas.translate(
        particle.origin.dx + particle.drift.dx * h * travel,
        particle.origin.dy - particle.drift.dy * h * travel,
      );
      canvas.rotate(particle.angle + particle.spin * progress);
      final path = Path()
        ..moveTo(0, -size)
        ..lineTo(size * .8, size * .62)
        ..lineTo(-size * .8, size * .62)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..color = particle.color.withAlpha((84 * remaining).round())
          ..style = PaintingStyle.stroke
          ..strokeWidth = size * .52,
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = particle.color.withAlpha((235 * remaining).round())
          ..style = particle.filled ? PaintingStyle.fill : PaintingStyle.stroke
          ..strokeWidth = size * .19,
      );
      canvas.restore();
    }
  }

  void _text(
    Canvas canvas,
    String text,
    Offset point,
    double size,
    Color color, {
    bool mono = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: size,
          fontWeight: FontWeight.w700,
          fontFamily: mono ? 'monospace' : null,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      point - Offset(painter.width / 2, painter.height / 2),
    );
    painter.dispose();
  }

  @override
  bool shouldRepaint(_Painter oldDelegate) => model != oldDelegate.model;
}
