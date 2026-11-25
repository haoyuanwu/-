import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'remote.dart';
import 'status_strip.dart';

class EyeScene extends StatefulWidget {
  const EyeScene({
    super.key,
    required this.mood,
    this.fullScreen = false,
    this.revision = 0,
    this.sleepSeconds = 90,
    this.agents = const {},
  });
  final EyeMood mood;
  final bool fullScreen;
  final int revision;
  final int sleepSeconds;
  final Map<String, EyeMood> agents;

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
      ..namedBadges = widget.agents.isNotEmpty;
    ticker = createTicker((elapsed) => model.step(elapsed.inMilliseconds))
      ..start();
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
    model.namedBadges = widget.agents.isNotEmpty;
    if (oldWidget.mood != widget.mood ||
        oldWidget.revision != widget.revision) {
      model.update(widget.mood);
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
            gestures.onDown = (event) => model.down(event.localPosition);
            gestures.onMove = (event) => model.move(event.localPosition);
            gestures.onUp = (event) =>
                model.up(event.localPosition, widget.fullScreen);
            gestures.onCancel = model.cancel;
          },
        ),
      },
      behavior: HitTestBehavior.opaque,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final frame = _frame(size, widget.fullScreen);
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
              RepaintBoundary(
                child: CustomPaint(
                  painter: _Painter(model, bottomInset: insets.bottom),
                ),
              ),
              if (badgeHeight >= 10)
                if (widget.fullScreen)
                  Positioned(
                    left: insets.left + 16,
                    width: size.width * .26,
                    top: insets.top + math.min(76, size.height * .22),
                    bottom: insets.bottom + math.min(64, size.height * .20),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: badges,
                    ),
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

class _EyeGesture extends OneSequenceGestureRecognizer {
  int? _pointer;
  void Function(PointerDownEvent)? onDown;
  void Function(PointerMoveEvent)? onMove;
  void Function(PointerUpEvent)? onUp;
  VoidCallback? onCancel;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (_pointer != null) return;
    _pointer = event.pointer;
    startTrackingPointer(event.pointer, event.transform);
    resolve(GestureDisposition.accepted);
    onDown?.call(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _pointer) return;
    if (event is PointerMoveEvent) onMove?.call(event);
    if (event is PointerUpEvent) onUp?.call(event);
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

class _Animation extends ChangeNotifier {
  _Animation(this.status)
    : expression = status == EyeMood.stopped ? EyeMood.idle : status;

  static const _peekDuration = 1730;
  final random = math.Random();
  EyeMood status;
  EyeMood expression;
  bool motion = true;
  bool desk = false;
  bool namedBadges = false;
  int time = 0;
  int expressionAt = 0;
  int statusAt = 0;
  int lastInteractionAt = 0;
  int sleepSeconds = 90;
  int? localSleepAt;
  bool get sleeping =>
      (status == EyeMood.sleep || localSleepAt != null) && wokeAt == null;
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
  Offset pupil = Offset.zero;
  double spacing = .18;
  double tilt = 0;
  Size sceneSize = Size.zero;
  Offset touch = Offset.zero;
  Offset tapOrigin = Offset.zero;
  bool tapMoved = false;
  Offset stillAnchor = Offset.zero;
  int? pressedAt;
  int stillAt = 0;
  bool held = false;
  bool puzzledAtAnchor = false;
  int puzzledUntil = 0;
  int? tapAt;
  int? releaseAt;
  bool tapGreets = false;
  int? firstDeepTap;
  ({int at, bool wake, double x})? peek;
  ({int at, bool wake, double x})? queuedPeek;
  int? wokeAt;
  _Look? thought;
  final particles = <_Particle>[];
  _Face? displayed;
  _Face? morphFrom;

  void update(EyeMood value) {
    status = value;
    statusAt = time;
    lastInteractionAt = time;
    localSleepAt = null;
    tapAt = null;
    releaseAt = null;
    firstDeepTap = null;
    peek = null;
    queuedPeek = null;
    wokeAt = null;
    idleMood = null;
    idleMoodAt = time + _range(10000, 16000);
    nextBlink = time + _range(1900, 4000);
    thought = null;
    _change(value == EyeMood.stopped ? EyeMood.idle : value);
    notifyListeners();
  }

  int _range(int low, int high) => low + random.nextInt(high - low);

  void down(Offset point) {
    if (!sleeping) lastInteractionAt = time;
    pressedAt = time;
    stillAt = time;
    touch = tapOrigin = stillAnchor = point;
    tapMoved = false;
    tapAt = releaseAt = null;
    held = false;
    puzzledAtAnchor = false;
    puzzledUntil = 0;
  }

  void move(Offset point) {
    touch = point;
    if ((point - tapOrigin).distance > kTouchSlop) tapMoved = true;
    if ((point - stillAnchor).distance > kTouchSlop) {
      stillAnchor = point;
      stillAt = time;
      puzzledAtAnchor = false;
    }
  }

  void cancel() {
    pressedAt = null;
    held = false;
  }

  void up(Offset point, bool showParticles) {
    move(point);
    final duration = time - (pressedAt ?? time);
    pressedAt = null;
    if (duration >= 500 || held) {
      if (!sleeping) releaseAt = time;
      held = false;
      return;
    }
    if (showParticles && motion && !tapMoved) {
      for (var index = 0; index < 12; index++) {
        particles.add(
          _Particle(
            point,
            time,
            _range(460, 820),
            Offset(
              index / 11 * .30 - .15 + random.nextDouble() * .05 - .025,
              .07 + random.nextDouble() * .16,
            ),
            .009 + random.nextDouble() * .012,
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
    if (status == EyeMood.question) return;
    if (sleeping) {
      if (tapMoved) return;
      if (peek?.wake == true || queuedPeek != null) return;
      final first = firstDeepTap;
      final second = first != null && time - first <= 4000;
      final shouldWake = time - (localSleepAt ?? statusAt) < 300000 || second;
      final starts = motion && second
          ? math.max(time, first + _peekDuration)
          : time;
      final action = (at: starts, wake: shouldWake, x: point.dx);
      if (starts > time) {
        queuedPeek = action;
      } else {
        peek = action;
      }
      firstDeepTap = shouldWake ? null : time;
    } else {
      tapAt = time;
      tapGreets = random.nextBool();
    }
  }

  void _change(EyeMood next) {
    if (next == expression) return;
    morphFrom = displayed;
    expression = next;
    expressionAt = time;
  }

  void step(int now) {
    final elapsed = (now - time).clamp(1, 50);
    time = now;
    final queued = queuedPeek;
    if (queued != null && time >= queued.at) {
      peek = queued;
      queuedPeek = null;
    }
    final activePeek = peek;
    if (activePeek != null &&
        (!motion ||
            time - activePeek.at >=
                _peekDuration + (activePeek.wake ? 580 : 0))) {
      if (activePeek.wake) {
        wokeAt = lastInteractionAt = time;
        localSleepAt = null;
      }
      peek = null;
    }
    final priorWake = wokeAt;
    if (priorWake != null && time - priorWake >= sleepSeconds * 1000) {
      wokeAt = null;
    }
    if (status == EyeMood.idle &&
        wokeAt == null &&
        pressedAt == null &&
        time - lastInteractionAt >= sleepSeconds * 1000) {
      localSleepAt ??= time;
    }
    final base = sleeping
        ? EyeMood.sleep
        : wokeAt != null
        ? EyeMood.idle
        : status;
    var next = base == EyeMood.stopped ? EyeMood.idle : base;
    var tracking = false;
    var compress = false;
    var puzzling = false;
    final start = pressedAt;
    final tap = tapAt;
    final release = releaseAt;
    final canReact = base != EyeMood.question && base != EyeMood.sleep;
    if (canReact && start != null) {
      if (!held && time - start >= 500) {
        held = true;
        stillAt = time;
      }
      if (held && !puzzledAtAnchor && time - stillAt >= 1500) {
        puzzledAtAnchor = true;
        puzzledUntil = time + 950;
      }
      puzzling = held && time < puzzledUntil;
      next = puzzling
          ? EyeMood.question
          : held
          ? EyeMood.focus
          : EyeMood.idle;
      tracking = true;
      compress = held;
    } else if (canReact && release != null && time - release < 440) {
      next = EyeMood.focus;
      tracking = compress = true;
    } else if (canReact &&
        tap != null &&
        time - tap < (tapGreets ? 5400 : 4000)) {
      final age = time - tap;
      tracking = age < 2000 || (age >= 2500 && age < 3000);
      compress = tracking;
      next = age < 3000
          ? EyeMood.idle
          : age < 4000
          ? EyeMood.question
          : EyeMood.hello;
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
    _change(next);
    final face = _frame(sceneSize, desk);
    final centered = Offset(
      ((touch.dx - face.left) / math.max(1, face.width) - .5).clamp(-.65, .65),
      ((touch.dy - face.top) / math.max(1, face.height) -
              .445 -
              (held ? .075 : 0))
          .clamp(-.55, .65),
    );
    final idleGlance = base == EyeMood.idle && time < glanceEnd
        ? glance
        : Offset.zero;
    final strength = held || puzzling ? .90 : .68;
    final target = tracking
        ? Offset(
            (centered.dx * .36).clamp(-.159, .159) * strength,
            (centered.dy * .40).clamp(-.08, .19) * strength,
          )
        : Offset(idleGlance.dx * .082, idleGlance.dy * .063);
    final pupilTarget = tracking
        ? Offset(centered.dx * 1.58, centered.dy * 1.7)
        : next == EyeMood.idea
        ? const Offset(0, -.18)
        : idleGlance;
    final old = thought;
    if (next == EyeMood.thinking && motion) {
      if (old == null || time >= old.end) thought = _look(old);
      final look = thought!;
      final ease = _ease((time - look.start) / 320);
      pupil = Offset.lerp(look.fromPupil, look.target, ease)!;
      gaze = Offset.lerp(
        look.fromGaze,
        Offset(look.target.dx * .105, look.target.dy * .083),
        ease,
      )!;
    } else {
      thought = null;
      gaze = Offset.lerp(
        gaze,
        target,
        motion ? 1 - math.exp(-elapsed / 90) : 1,
      )!;
      pupil = Offset.lerp(
        pupil,
        pupilTarget,
        motion ? 1 - math.exp(-elapsed / 100) : 1,
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
      compress ? _mix(.143, .18, distance) : .18,
      motion ? 1 - math.exp(-elapsed / 100) : 1,
    );
    final age = time - expressionAt;
    final turn = age % 15800 - 11000;
    final angle = switch (expression) {
      EyeMood.done =>
        math.sin((age - 270) / 860 * 2 * math.pi) *
            .112 *
            _pulse(age - 270, 1800),
      EyeMood.sleep =>
        (age ~/ 15800).isEven
            ? -.148 * _pulse(turn, 3800)
            : .148 * _pulse(turn, 3800),
      _ => 0.0,
    };
    tilt = _mix(tilt, motion ? angle : 0, 1 - math.exp(-elapsed / 54));
    particles.removeWhere(
      (particle) => time - particle.at >= particle.duration,
    );
    notifyListeners();
  }

  _Look _look(_Look? previous) {
    final remaining = previous?.beforeCode ?? _range(2, 5);
    final moveBlink = random.nextBool() ? time + _range(15, 135) : null;
    if (remaining == 0) {
      return _Look(
        time,
        time + 2320,
        _range(2, 5),
        null,
        Offset.zero,
        pupil,
        gaze,
        moveBlink,
        null,
        false,
      );
    }
    final direction = previous?.direction;
    final next = direction == null
        ? random.nextInt(8)
        : (direction + _range(2, 7)) % 8;
    final angle = next * math.pi / 4;
    final end = time + _range(2320, 3321);
    final count = random.nextInt(3);
    return _Look(
      time,
      end,
      remaining - 1,
      next,
      Offset(math.cos(angle), math.sin(angle)),
      pupil,
      gaze,
      moveBlink,
      count == 0 ? null : _range(time + 570, end - 620),
      count == 2,
    );
  }

  double blink() {
    if (!motion) return 1;
    final release = releaseAt;
    if (release != null && time - release < 440) return _double(time - release);
    final look = thought;
    if (look != null) {
      final moveBlink = look.moveBlink;
      final holdBlink = look.holdBlink;
      if (moveBlink != null && time >= moveBlink && time < moveBlink + 185) {
        return 1 - .92 * _pulse(time - moveBlink, 185);
      }
      if (holdBlink == null) return 1;
      return look.doubleBlink
          ? _double(time - holdBlink)
          : 1 - .92 * _pulse(time - holdBlink, 185);
    }
    if (expression != EyeMood.idle &&
        expression != EyeMood.question &&
        expression != EyeMood.focus) {
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

  double _double(int age) =>
      1 - .91 * (age >= 255 ? _pulse(age - 255, 165) : _pulse(age, 175));
}

class _Look {
  _Look(
    this.start,
    this.end,
    this.beforeCode,
    this.direction,
    this.target,
    this.fromPupil,
    this.fromGaze,
    this.moveBlink,
    this.holdBlink,
    this.doubleBlink,
  );
  final int start, end, beforeCode;
  final int? direction, moveBlink, holdBlink;
  final Offset target, fromPupil, fromGaze;
  final bool doubleBlink;
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

Rect _frame(Size size, bool desk) {
  final aspect = desk ? 1.55 : 624 / 596;
  final height = math.min(size.height, size.width / aspect);
  return Rect.fromCenter(
    center: size.center(Offset.zero),
    width: height * aspect,
    height: height,
  );
}

class _Painter extends CustomPainter {
  _Painter(this.model, {required this.bottomInset}) : super(repaint: model);

  final _Animation model;
  final double bottomInset;
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

  _Face _face(EyeMood expression, double blink, double aspect) {
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
        double brow = 0,
        double lean = 0,
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
          browTilt: lean,
          arch: arch,
          browWidth: brow == 0 ? 0 : .024,
          inset: inset * visible,
          cheek: cheek * visible,
        );
      }

      switch (expression) {
        case EyeMood.stopped:
        case EyeMood.idle:
          return open(y, .275, .432);
        case EyeMood.thinking:
          return open(y, .30, .405);
        case EyeMood.idea:
          return open(y - .023, .327, .515 + swell * .039, openness: 1);
        case EyeMood.question:
          final small =
              model.time < model.puzzledUntil && model.pressedAt != null
              ? _ease((model.pupil.dx + .44) / .88)
              : 1.0;
          final largeEye = open(
            y - .055,
            .285,
            .485,
            brow: .085,
            lean: side * .035,
            arch: .07,
          );
          final smallEye = open(
            y + .065,
            .25,
            .28,
            brow: .245,
            lean: side * .035,
            arch: .042,
            inset: .019,
            cheek: side * .025,
          );
          return largeEye.mix(smallEye, side < 0 ? 1 - small : small);
        case EyeMood.done:
          return _Eye(
            Offset(x, y + .07 - swell * .037),
            .148 + swell * .007,
            .051,
            bend: .286 + swell * .028,
            crescent: 1,
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
          return _Eye(Offset(x, y + .04), .126, .014, bend: -.065);
        case EyeMood.focus:
          final proximity = _ease((model.pupil.dx * side - .045) / .68);
          return open(
            y,
            .253 * (1 - proximity * .14),
            .401 * (1 - proximity * .24),
            brow: .172 + proximity * .048,
            lean: -side * .108,
            arch: .026,
          );
        case EyeMood.hello:
          final hop = model.motion ? _pulse(age, 680) : 0.0;
          final wink = model.motion && side < 0
              ? 1 - .89 * _pulse(age - 410, 520)
              : 1.0;
          return open(
            y - hop * .052 + (side < 0 ? .02 : 0),
            .29,
            side < 0 ? .403 : .458,
            openness: wink,
          );
      }
    }

    return _Face(eye(-1), eye(1), palette[expression]!.map(Color.new).toList());
  }

  @override
  void paint(Canvas canvas, Size size) {
    model.sceneSize = size;
    final frame = _frame(size, model.desk);
    final w = frame.width;
    final h = frame.height;
    if (w <= 0 || h <= 0) return;
    final expression = model.expression;
    var face = _face(expression, model.blink(), w / h);
    final age = model.time - model.expressionAt;
    final progress = model.motion ? _ease(age / 320) : 1.0;
    final previous = model.morphFrom;
    if (previous != null && progress < 1) face = previous.mix(face, progress);
    final peek = model.peek;
    if (peek != null) {
      final elapsed = model.time - peek.at;
      final awake = _face(EyeMood.idle, 1, w / h);
      if (elapsed >= _Animation._peekDuration) {
        face = face.mix(
          awake,
          _ease((elapsed - _Animation._peekDuration) / 580),
        );
      } else if (elapsed < 1490) {
        final flatten = _ease(math.min(elapsed, 1490 - elapsed) / 160);
        final open = math.min(
          _ease((elapsed - 160) / 420),
          _ease((1330 - elapsed) / 250),
        );
        _Eye opening(_Eye closed, _Eye openEye) => closed
            .sleepLid(bend: _mix(closed.bend, 0, flatten))
            .mix(openEye.sleepLid(halfLid: 1), open);
        face = peek.x <= frame.center.dx
            ? _Face(opening(face.left, awake.left), face.right, face.colors)
            : _Face(face.left, opening(face.right, awake.right), face.colors);
      }
    }
    model.displayed = face;
    canvas.save();
    canvas.translate(frame.left, frame.top);
    canvas.save();
    canvas.translate(w * .5, h * .46);
    canvas.rotate(model.tilt);
    canvas.translate(-w * .5, -h * .46);
    final thought = model.thought;
    final code = thought != null && thought.direction == null
        ? model.time - thought.start - 320
        : -1;
    _eye(canvas, face.left, face.colors, w, h, true, code);
    _eye(canvas, face.right, face.colors, w, h, false, code);
    canvas.restore();
    _details(canvas, expression, face.colors[0], w, h, age, progress);
    canvas.restore();
    _drawParticles(canvas, h);
    if (model.desk && expression == EyeMood.thinking) {
      _loading(
        canvas,
        Offset(size.width / 2, size.height - bottomInset - 24),
        16,
        math.min(h, 480) * .62,
        face.colors[0],
      );
    }
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

      _drawHalo(canvas, shape, colors[1], h * .076);
      final paint = Paint()
        ..shader = _ellipticalGradient(
          Offset(cx, cy - eye.bend * h / 4),
          rx,
          ry + eye.bend.abs() * h / 4,
          colors,
          const [0, .52, 1],
        );
      canvas.drawPath(shape, paint);
      if (eye.pupil > .04) {
        canvas.save();
        canvas.clipPath(shape);
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
              Paint()
                ..color = const Color(0xffffffff).withAlpha(
                  (glow[index] * eye.pupil * (1 - codeBlend)).round(),
                ),
            );
            canvas.restore();
          }
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
        canvas.restore();
      }
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
      final control = Offset(cx, y - eye.arch * h);
      final brow = Path();
      Offset edge(double t, int side) {
        final a = Offset.lerp(first, control, t)!;
        final b = Offset.lerp(control, end, t)!;
        final tangent = b - a;
        final center = Offset.lerp(a, b, t)!;
        final radius = _mix(.32, .72, left ? t : 1 - t) * eye.browWidth * h;
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
      _drawHalo(canvas, brow, colors[1], h * .053, strength * .85);
      canvas.drawPath(brow, Paint()..color = colors[0].withAlpha(238));
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
    if (mood == EyeMood.thinking) {
      if (model.desk) return;
      final badgeHeight = math.min(h * .085, 17.0);
      final y = model.namedBadges
          ? math.min(h * .765, h * .86 - badgeHeight * 1.67)
          : h * .765;
      _loading(canvas, Offset(w * .5, y), w * .065, h, color);
    } else if (mood == EyeMood.question) {
      final small = model.time < model.puzzledUntil && model.pressedAt != null
          ? _ease((model.pupil.dx + .44) / .88)
          : 1.0;
      final x = (_mix(.19, .81, small) + model.gaze.dx).clamp(.08, .92);
      _text(
        canvas,
        '?',
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
    } else if (mood == EyeMood.done && model.motion && age < 720) {
      final t = _unit(age / 720);
      for (final side in [-1, 1]) {
        canvas.drawCircle(
          Offset(w * (.5 + side * (.28 + t * .12)), h * (.33 - t * .18)),
          h * (.01 + t * .012),
          Paint()..color = color.withAlpha((200 * _pulse(age, 720)).round()),
        );
      }
    }
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

  void _loading(
    Canvas canvas,
    Offset center,
    double spacing,
    double scale,
    Color color,
  ) {
    final paint = Paint();
    for (var i = 0; i < 3; i++) {
      final signal = model.motion
          ? math.max(0.0, math.sin(model.time / 320 - i * .9))
          : .45;
      canvas.drawCircle(
        center + Offset((i - 1) * spacing, 0),
        scale * (.012 + .009 * signal),
        paint..color = color.withAlpha((75 + 180 * signal).round()),
      );
    }
  }

  @override
  bool shouldRepaint(_Painter oldDelegate) =>
      model != oldDelegate.model || bottomInset != oldDelegate.bottomInset;
}
