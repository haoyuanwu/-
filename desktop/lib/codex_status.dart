import 'dart:convert';
import 'dart:io';
import 'dart:math';

class CodexStatus {
  final _sessions = <String, _Session>{};

  DateTime? lastCompletion;

  Map<String, Object?> read({String? codexHome}) {
    final env = Platform.environment;
    final home =
        codexHome ??
        env['CODEX_HOME'] ??
        '${env[Platform.isWindows ? 'USERPROFILE' : 'HOME']}/.codex';
    final now = DateTime.now();
    final candidates = <File, FileStat>{};
    for (final date in [now, DateTime(now.year, now.month, now.day - 1)]) {
      final month = date.month.toString().padLeft(2, '0');
      final day = date.day.toString().padLeft(2, '0');
      final directory = Directory('$home/sessions/${date.year}/$month/$day');
      try {
        for (final entry in directory.listSync(followLinks: false)) {
          if (entry is File &&
              entry.uri.pathSegments.last.startsWith('rollout-') &&
              entry.path.endsWith('.jsonl')) {
            candidates[entry] = entry.statSync();
          }
        }
      } on FileSystemException {
        // The folder may not exist or may be temporarily unavailable.
      }
    }
    final newest = candidates.entries.toList()
      ..sort((a, b) => b.value.modified.compareTo(a.value.modified));
    final activePaths = <String>{};
    for (final entry in newest.take(24)) {
      final file = entry.key;
      activePaths.add(file.path);
      try {
        final current = _sessions[file.path];
        if (current != null &&
            current.modified == entry.value.modified &&
            current.size == entry.value.size) {
          continue;
        }
        _sessions[file.path] = _readFile(file, entry.value, current);
      } on FileSystemException {
        // A rollout can be moved while Codex is running.
      }
    }
    _sessions.removeWhere((path, _) => !activePaths.contains(path));
    final recent = _sessions.values.toList()
      ..sort((a, b) => b.turnAt.compareTo(a.turnAt));
    lastCompletion = recent
        .map((item) => item.completedAt)
        .whereType<DateTime>()
        .fold<DateTime?>(
          null,
          (latest, at) => latest == null || at.isAfter(latest) ? at : latest,
        );
    var state = 'IDLE';
    if (recent.any(
      (item) =>
          item.pending.isNotEmpty &&
          now.difference(item.modified).inMinutes < 15,
    )) {
      state = 'QUESTION';
    } else if (recent.any(
      (item) =>
          item.state == 'THINKING' &&
          now.difference(item.modified).inMinutes < 15,
    )) {
      state = 'THINKING';
    } else if (recent.isNotEmpty &&
        now.difference(recent.first.turnAt).inSeconds < 30) {
      state = recent.first.state;
    }

    final usage = <String, Object>{};
    final byQuotaTime = recent.toList()
      ..sort((a, b) => b.quotaAt.compareTo(a.quotaAt));
    final nowSeconds = now.millisecondsSinceEpoch ~/ 1000;
    for (final session in byQuotaTime) {
      for (final entry in session.quotas.entries) {
        if (entry.value.reset > nowSeconds && !usage.containsKey(entry.key)) {
          usage[entry.key] = entry.value.used;
          usage['${entry.key}Reset'] = entry.value.reset;
        }
      }
    }
    return {'state': state, ...usage};
  }

  _Session _readFile(File file, FileStat stat, _Session? previous) {
    final start = max(0, stat.size - 262144);
    final reuse =
        previous != null &&
        previous.offset >= start &&
        previous.offset <= stat.size &&
        previous.size <= stat.size;
    final session = reuse ? previous : _Session();
    final offset = reuse ? session.offset : start;
    final stream = file.openSync();
    try {
      stream.setPositionSync(offset);
      final bytes = stream.readSync(stat.size - offset);
      var begin = 0;
      if (!reuse && offset > 0) {
        begin = bytes.indexOf(10) + 1;
        if (begin == 0) begin = bytes.length;
      }
      for (
        var end = bytes.indexOf(10, begin);
        end >= 0;
        end = bytes.indexOf(10, begin)
      ) {
        try {
          final value = jsonDecode(utf8.decode(bytes.sublist(begin, end)));
          if (value is Map<String, dynamic>) session.accept(value);
        } on FormatException {
          // Skip invalid records, keeping partial trailing records for next time.
        }
        begin = end + 1;
      }
      session.offset = offset + begin;
      session.modified = stat.modified;
      session.size = stat.size;
      return session;
    } finally {
      stream.closeSync();
    }
  }
}

class _Session {
  var modified = DateTime.fromMillisecondsSinceEpoch(0);
  var turnAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? completedAt;
  var quotaAt = DateTime.fromMillisecondsSinceEpoch(0);
  var offset = 0;
  var size = 0;
  var state = 'IDLE';
  bool failedTurn = false;
  final pending = <String, String>{};
  final quotas = <String, ({int used, int reset})>{};

  void accept(Map<String, dynamic> event) {
    final payload = event['payload'];
    final timestamp = event['timestamp'];
    if (payload is! Map || timestamp is! String) return;
    final at = DateTime.tryParse(timestamp);
    if (at == null) return;
    final kind = payload['type'];
    if (event['type'] == 'response_item') {
      final id = payload['call_id'];
      final name = payload['name'];
      if (kind == 'function_call' &&
          id is String &&
          (name == 'request_user_input' ||
              name == 'request_user_input_async')) {
        pending[id] = name as String;
      } else if (kind == 'function_call_output' && id is String) {
        if (pending[id] == 'request_user_input_async' &&
            payload['output'] is String) {
          try {
            final result = jsonDecode(payload['output'] as String);
            if (result is Map && result['accepted'] == true) return;
          } on FormatException {
            // A non-JSON outcome closes the pending request.
          }
        }
        pending.remove(id);
      } else if (kind == 'message' &&
          payload['role'] == 'user' &&
          pending.isNotEmpty) {
        _acceptReplies(payload['content']);
      }
      return;
    }
    if (event['type'] != 'event_msg') return;
    switch (kind) {
      case 'task_started':
      case 'turn_started':
        failedTurn = false;
        state = 'THINKING';
        turnAt = at;
      case 'task_complete':
      case 'turn_complete':
        state = failedTurn ? 'ERROR' : 'DONE';
        if (!failedTurn) completedAt = at;
        turnAt = at;
        pending.removeWhere((_, name) => name != 'request_user_input_async');
      case 'error':
        if (payload['will_retry'] == true || state != 'THINKING') return;
        failedTurn = true;
        state = 'ERROR';
        turnAt = at;
        pending.clear();
      case 'turn_aborted':
        state = failedTurn ? 'ERROR' : 'STOPPED';
        turnAt = at;
        pending.clear();
      case 'token_count':
        final limits = payload['rate_limits'];
        if (limits is! Map || limits['limit_id'] != 'codex') return;
        for (final window in [limits['primary'], limits['secondary']]) {
          if (window is! Map) continue;
          final key = const {
            300: 'five',
            10080: 'week',
          }[window['window_minutes']];
          final value = window['used_percent'];
          final reset = window['resets_at'];
          if (key != null &&
              value is num &&
              value >= 0 &&
              value <= 100 &&
              reset is int) {
            quotas[key] = (used: value.round(), reset: reset);
            quotaAt = at;
          }
        }
    }
  }

  void _acceptReplies(dynamic content) {
    if (content is! List) return;
    final pattern = RegExp(
      r'^<send_user_message_question_reply>([\s\S]*?)</send_user_message_question_reply>',
    );
    for (final item in content) {
      final text = item is Map ? item['text'] : null;
      if (text is! String) continue;
      final match = pattern.firstMatch(text);
      if (match == null) continue;
      final replies = jsonDecode(match.group(1)!);
      if (replies is! List) continue;
      for (final reply in replies) {
        if (reply is Map && reply['questionItemId'] is String) {
          final id = jsonDecode(reply['questionItemId'] as String);
          if (id is List && id.length >= 2) pending.remove(id[1]);
        }
      }
    }
  }
}
