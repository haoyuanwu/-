import 'dart:async';

import 'package:flutter/foundation.dart';

const noticeStackTransitionDuration = Duration(milliseconds: 280);
const noticeGroupingWindow = Duration(milliseconds: 1500);

class NoticeGroup<T extends Object> {
  NoticeGroup._(T item, this._source) : _items = [item];

  final String? _source;
  final List<T> _items;
  List<T> get items => List.unmodifiable(_items);
  T get latest => _items.last;

  Timer? _timer;
  final _elapsed = Stopwatch();
  Duration _remaining = NoticeQueue.displayDuration;

  void _freeze() {
    _timer?.cancel();
    _timer = null;
    _remaining -= _elapsed.elapsed;
    _elapsed
      ..stop()
      ..reset();
  }
}

class NoticeQueue<T extends Object> extends ChangeNotifier {
  static const pendingLimit = 24;
  static const displayDuration = Duration(seconds: 9);

  final _visible = <NoticeGroup<T>>[];
  NoticeGroup<T>? _recent;
  Timer? _grouping;
  var _pauseCount = 0;
  var _disposed = false;

  List<NoticeGroup<T>> get groups => List.unmodifiable(_visible);
  List<T> get visible =>
      List.unmodifiable(_visible.map((group) => group.latest));
  T? get latest => _visible.lastOrNull?.latest;

  void add(T item, {String? source}) {
    if (_visible.any((group) => group._items.contains(item))) return;
    final recent = _recent;
    if (source != null &&
        _grouping?.isActive == true &&
        recent?._source == source) {
      recent!._items.add(item);
      recent._freeze();
      recent._remaining = displayDuration;
      _start(recent);
    } else {
      final group = NoticeGroup._(item, source);
      _visible.add(group);
      _recent = group;
      _start(group);
    }
    notifyListeners();
    _grouping?.cancel();
    if (source != null && _recent != null) {
      _grouping = Timer(noticeGroupingWindow, () => _recent = null);
    }
  }

  void endGrouping() {
    _grouping?.cancel();
    _recent = null;
  }

  void pause() {
    if (_pauseCount++ != 0) return;
    for (final group in _visible) {
      group._freeze();
    }
  }

  void resume() {
    if (_disposed || _pauseCount == 0 || --_pauseCount != 0) return;
    for (final group in _visible) {
      _start(group);
    }
  }

  void _start(NoticeGroup<T> group) {
    if (_pauseCount != 0) return;
    group._elapsed.start();
    group._timer = Timer(group._remaining, () => removeGroup(group));
  }

  void remove(T item) {
    final group = _visible
        .where((group) => group._items.contains(item))
        .firstOrNull;
    if (group != null) removeGroup(group);
  }

  void removeGroup(NoticeGroup<T> group) {
    if (!_visible.remove(group)) return;
    group._freeze();
    if (identical(_recent, group)) _recent = null;
    notifyListeners();
  }

  void clear() {
    if (_visible.isEmpty) return;
    _reset();
    notifyListeners();
  }

  void _reset() {
    for (final group in _visible) {
      group._freeze();
    }
    endGrouping();
    _visible.clear();
  }

  @override
  void dispose() {
    _disposed = true;
    _reset();
    super.dispose();
  }
}
