import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import 'design.dart';
import 'eye_scene.dart';
import 'notice_queue.dart';
import 'notice_window.dart';
import 'remote.dart';

const _channel = MethodChannel('com.reareyes/rear-eyes');

typedef _RearNotice = ({
  String key,
  String source,
  String title,
  String text,
  String packageName,
});

class RearDisplay extends StatefulWidget {
  const RearDisplay({super.key});

  @override
  State<RearDisplay> createState() => _RearDisplayState();
}

class _RearDisplayState extends State<RearDisplay> {
  Map<Object?, Object?>? _snapshot;
  final _notices = NoticeQueue<_RearNotice>();
  final _received = <String>{};
  int? _lastNoticeAt;

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'update') _update(call.arguments as Map);
    });
    unawaited(_subscribe());
  }

  Future<void> _subscribe() async {
    final snapshot = await _channel.invokeMapMethod<Object?, Object?>(
      'subscribe',
    );
    if (snapshot != null && _snapshot == null) _update(snapshot);
  }

  void _update(Map<Object?, Object?> snapshot) {
    if (!mounted) return;
    final entries = (snapshot['notices'] as List?)?.whereType<Map>() ?? [];
    _received.retainAll(entries.map((item) => item['key']));
    for (final item in entries) {
      final key = item['key'] as String;
      if (!_received.add(key)) continue;
      final packageName = item['package'] as String;
      final receivedAt = item['receivedAt'] as int?;
      final previous = _lastNoticeAt;
      if (receivedAt != null &&
          previous != null &&
          receivedAt - previous > noticeGroupingWindow.inMilliseconds) {
        _notices.endGrouping();
      }
      _lastNoticeAt = receivedAt;
      _notices.add((
        key: key,
        source: item['source'] as String,
        title: item['title'] as String,
        text: item['text'] as String,
        packageName: packageName,
      ), source: item['verification'] == true ? null : packageName);
    }
    setState(() => _snapshot = snapshot);
  }

  Future<void> _expand(NoticeGroup<_RearNotice> group) async {
    _notices.pause();
    try {
      await showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          backgroundColor: Colors.transparent,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: CustomPaint(
              painter: const NoticeWindowFrame(),
              child: ListenableBuilder(
                listenable: _notices,
                builder: (_, _) => SingleChildScrollView(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              group.latest.source,
                              style: const TextStyle(color: cyan),
                            ),
                          ),
                          IconButton(
                            tooltip: '关闭',
                            icon: const Icon(
                              Icons.close_rounded,
                              color: secondaryInk,
                            ),
                            onPressed: () => Navigator.pop(context),
                          ),
                        ],
                      ),
                      NoticeMessageHistory(
                        messages: group.items.reversed.map(
                          (item) => (title: item.title, text: item.text),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    } finally {
      _notices.resume();
    }
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    _notices.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    if (snapshot == null) return const SizedBox.expand();
    final mood = EyeMood.values.firstWhere(
      (value) => value.wire == snapshot['mood'],
      orElse: () => EyeMood.idle,
    );
    final sleepRevision = snapshot['sleepRevision'];
    final insets = MediaQuery.paddingOf(context);
    final leftInset = (snapshot['leftInset'] as num).toDouble();
    return ColoredBox(
      color: const Color(0xff000000),
      child: Stack(
        fit: StackFit.expand,
        children: [
          EyeScene(
            mood: mood,
            revision: snapshot['revision'] as int,
            fullScreen: true,
            leftInset: leftInset,
            sleepSeconds: snapshot['sleepSeconds'] as int,
            keepAwake: snapshot['keepAwake'] as bool,
            noticeCue: snapshot['noticeCue'],
            conversationActive: snapshot['conversationActive'] as bool,
            voiceLevel: (snapshot['voiceLevel'] as num?)?.toDouble(),
            speechActivity: snapshot['speechActivity'] as int,
            speaking: snapshot['speaking'] as bool,
            onWake: sleepRevision == null
                ? null
                : () => unawaited(
                    _channel.invokeMethod<void>('wake', sleepRevision),
                  ),
          ),
          Positioned.fill(
            left: math.max(leftInset, insets.left) + 8,
            right: insets.right + 8,
            top: insets.top + 8,
            bottom: insets.bottom + 32,
            child: Align(
              alignment: Alignment.bottomRight,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 178),
                child: ListenableBuilder(
                  listenable: _notices,
                  builder: (context, _) => NoticeStack(
                    items: _notices.groups,
                    onDismissed: _notices.removeGroup,
                    itemBuilder: (group) => _RearNoticeCard(
                      key: ObjectKey(group),
                      item: group.latest,
                      count: group.items.length,
                      onTap: () => _expand(group),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RearNoticeCard extends StatefulWidget {
  const _RearNoticeCard({
    super.key,
    required this.item,
    required this.count,
    required this.onTap,
  });

  final _RearNotice item;
  final int count;
  final VoidCallback onTap;

  @override
  State<_RearNoticeCard> createState() => _RearNoticeCardState();
}

class _RearNoticeCardState extends State<_RearNoticeCard> {
  late final _icon = _channel.invokeMethod<Uint8List>(
    'noticeIcon',
    widget.item.packageName,
  );

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: NoticeCardFrame(
      count: widget.count,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: widget.onTap,
          child: NoticeCardContent(
            source: widget.item.source,
            title: widget.item.title,
            text: widget.item.text,
            icon: NoticeAppLogo(_icon),
            count: widget.count,
          ),
        ),
      ),
    ),
  );
}
