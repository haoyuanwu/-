import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'design.dart';
import 'notice_queue.dart';

class NoticeWindow extends StatelessWidget {
  const NoticeWindow({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 410);
    return AnimatedSwitcher(
      duration: duration,
      reverseDuration: duration == Duration.zero
          ? Duration.zero
          : const Duration(milliseconds: 180),
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.bottomCenter,
        children: [
          for (final child in previous) IgnorePointer(child: child),
          ?current,
        ],
      ),
      transitionBuilder: (child, animation) {
        final ease = animation.drive(CurveTween(curve: Curves.easeOutCubic));
        return SlideTransition(
          position: Tween(
            begin: const Offset(.035, .12),
            end: Offset.zero,
          ).animate(ease),
          child: FadeTransition(
            opacity: ease,
            child: CustomPaint(
              foregroundPainter: _NoticeSweep(animation),
              child: child,
            ),
          ),
        );
      },
      child: child,
    );
  }
}

class NoticeStack<T extends Object> extends StatefulWidget {
  const NoticeStack({
    super.key,
    required this.items,
    required this.itemBuilder,
    required this.onDismissed,
  });

  final List<T> items;
  final Widget Function(T) itemBuilder;
  final ValueChanged<T> onDismissed;

  @override
  State<NoticeStack<T>> createState() => _NoticeStackState<T>();
}

class _NoticeStackState<T extends Object> extends State<NoticeStack<T>> {
  final _list = GlobalKey<AnimatedListState>();
  late final _items = widget.items.reversed.toList();
  final _swiped = <T>{};

  @override
  void didUpdateWidget(covariant NoticeStack<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final list = _list.currentState;
    final next = widget.items.reversed.toList();
    if (list == null) {
      _items
        ..clear()
        ..addAll(next);
      return;
    }
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final duration = reduceMotion
        ? Duration.zero
        : noticeStackTransitionDuration;
    for (var index = _items.length - 1; index >= 0; index--) {
      if (next.contains(_items[index])) continue;
      final item = _items.removeAt(index);
      final swiped = _swiped.remove(item);
      list.removeItem(
        index,
        (context, animation) => IgnorePointer(
          child: ExcludeSemantics(
            child: _transition(
              swiped
                  ? Opacity(opacity: 0, child: widget.itemBuilder(item))
                  : widget.itemBuilder(item),
              animation,
            ),
          ),
        ),
        duration: duration,
      );
    }
    for (var index = 0; index < next.length; index++) {
      final item = next[index];
      if (_items.contains(item)) continue;
      _items.insert(index, item);
      list.insertItem(index, duration: duration);
    }
  }

  Widget _transition(Widget child, Animation<double> animation) {
    final eased = animation.drive(CurveTween(curve: Curves.easeOutCubic));
    return SizeTransition(
      sizeFactor: eased,
      alignment: Alignment.bottomCenter,
      child: FadeTransition(
        opacity: eased,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, .24),
            end: Offset.zero,
          ).animate(eased),
          child: Padding(padding: const EdgeInsets.only(top: 6), child: child),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedList(
    key: _list,
    initialItemCount: _items.length,
    reverse: true,
    primary: false,
    shrinkWrap: true,
    padding: EdgeInsets.zero,
    physics: const ClampingScrollPhysics(),
    itemBuilder: (context, index, animation) {
      final item = _items[index];
      final direction = Directionality.of(context) == TextDirection.ltr
          ? DismissDirection.startToEnd
          : DismissDirection.endToStart;
      return KeyedSubtree(
        key: ValueKey(item),
        child: _transition(
          Dismissible(
            key: ValueKey(item),
            direction: direction,
            movementDuration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 180),
            resizeDuration: null,
            onDismissed: (_) {
              _swiped.add(item);
              widget.onDismissed(item);
            },
            child: widget.itemBuilder(item),
          ),
          animation,
        ),
      );
    },
  );
}

class _NoticeSweep extends CustomPainter {
  _NoticeSweep(this.animation) : super(repaint: animation);

  final Animation<double> animation;

  @override
  void paint(Canvas canvas, Size size) {
    final t = animation.value;
    if (t <= 0 || t >= 1 || size.isEmpty) return;
    final x = (size.width + 48) * t - 24;
    final band = Rect.fromLTRB(x - 24, 0, x + 24, size.height);
    final strength = 1 - (2 * t - 1).abs();
    canvas.save();
    canvas.clipRect((Offset.zero & size).deflate(2));
    canvas.drawRect(
      band,
      Paint()
        ..shader = LinearGradient(
          colors: [
            cyan.withValues(alpha: 0),
            cyan.withValues(alpha: strength * .20),
            cyan.withValues(alpha: 0),
          ],
        ).createShader(band),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_NoticeSweep oldDelegate) =>
      animation != oldDelegate.animation;
}

class NoticeWindowFrame extends CustomPainter {
  const NoticeWindowFrame();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    const corner = 11.0;
    final frame = Path()
      ..moveTo(0, corner)
      ..lineTo(corner, 0)
      ..lineTo(w, 0)
      ..lineTo(w, h - corner)
      ..lineTo(w - corner, h)
      ..lineTo(0, h)
      ..close();
    final paint = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xf0132635), Color(0xf008101c)],
      ).createShader(Offset.zero & size);
    canvas.drawPath(frame, paint);
    paint
      ..shader = null
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = cyan.withValues(alpha: .34);
    canvas.drawPath(frame, paint);
    final corners = Path()
      ..moveTo(0, 25)
      ..lineTo(0, corner)
      ..lineTo(corner, 0)
      ..lineTo(31, 0)
      ..moveTo(w - 31, h)
      ..lineTo(w - corner, h)
      ..lineTo(w, h - corner)
      ..lineTo(w, h - 25);
    paint
      ..strokeWidth = 1.5
      ..color = cyan.withValues(alpha: .9);
    canvas.drawPath(corners, paint);
  }

  @override
  bool shouldRepaint(NoticeWindowFrame oldDelegate) => false;
}

class NoticeCardFrame extends StatelessWidget {
  const NoticeCardFrame({super.key, required this.count, required this.child});

  final int count;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final layers = count > 2 ? 2 : count - 1;
    if (layers <= 0) {
      return CustomPaint(painter: const NoticeWindowFrame(), child: child);
    }
    return Stack(
      children: [
        for (var layer = layers; layer > 0; layer--)
          Positioned(
            top: (layers - layer) * 4,
            left: 8.0 * layer,
            right: 8.0 * layer,
            bottom: 1,
            child: const CustomPaint(painter: NoticeWindowFrame()),
          ),
        Padding(
          padding: EdgeInsets.only(top: layers * 4),
          child: CustomPaint(painter: const NoticeWindowFrame(), child: child),
        ),
      ],
    );
  }
}

class NoticeMessageHistory extends StatelessWidget {
  const NoticeMessageHistory({super.key, required this.messages});

  final Iterable<({String title, String text})> messages;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final message in messages)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 10),
          padding: const EdgeInsets.only(top: 9),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: borderColor)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                message.title,
                style: const TextStyle(
                  color: primaryInk,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (message.text.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    message.text,
                    style: const TextStyle(color: secondaryInk, fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
    ],
  );
}

class NoticeCardContent extends StatelessWidget {
  const NoticeCardContent({
    super.key,
    required this.source,
    required this.title,
    required this.text,
    required this.icon,
    this.count = 1,
  });

  final String source;
  final String title;
  final String text;
  final Widget icon;
  final int count;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 7, 13, 8),
    child: Row(
      children: [
        icon,
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      source,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: cyan,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (count > 1)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Text(
                        '$count 条',
                        style: const TextStyle(color: cyan, fontSize: 10),
                      ),
                    ),
                ],
              ),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: primaryInk,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (text.isNotEmpty)
                Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: secondaryInk, fontSize: 12),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

class NoticeAppLogo extends StatelessWidget {
  const NoticeAppLogo(this.logo, {super.key});

  final Future<Uint8List?> logo;

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    future: logo,
    builder: (context, snapshot) {
      final bytes = snapshot.data;
      if (bytes == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(right: 10),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.memory(
            bytes,
            width: 30,
            height: 30,
            excludeFromSemantics: true,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        ),
      );
    },
  );
}
