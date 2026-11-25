import 'dart:convert';
import 'dart:math';

import 'platform_io.dart'
    if (dart.library.js_interop) 'platform_web.dart'
    as platform;

enum EyeMood {
  stopped('已停止', 'STOPPED'),
  idle('待机', 'IDLE'),
  thinking('运行中', 'THINKING'),
  question('等待确认', 'QUESTION'),
  done('已完成', 'DONE'),
  error('运行出错', 'ERROR'),
  sleep('休眠', 'SLEEP'),
  focus('跟随', 'FOCUS'),
  hello('打招呼', 'HELLO'),
  idea('灵感', 'IDEA');

  const EyeMood(this.label, this.wire);
  final String label;
  final String wire;

  static const statusPriority = [
    question,
    thinking,
    error,
    done,
    stopped,
    idle,
    sleep,
  ];

  static EyeMood? statusFromWire(Object? value) {
    for (final mood in statusPriority) {
      if (mood.wire == value) return mood;
    }
    return null;
  }
}

class Pairing {
  Pairing._(this.url, this.token);

  final Uri url;
  final String token;

  factory Pairing.parse(String raw) {
    final json = jsonDecode(raw);
    final address = json is Map ? json['url'] : null;
    final token = json is Map ? json['token'] : null;
    final uri = address is String ? Uri.tryParse(address.trim()) : null;
    if (uri == null ||
        uri.scheme != 'https' ||
        !uri.host.endsWith('.ts.net') ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.port < 1 ||
        uri.port > 65535 ||
        token is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token)) {
      throw const FormatException('请粘贴完整的 Tailscale 配对配置');
    }
    return Pairing._(uri.replace(path: ''), token);
  }

  String encode() => jsonEncode({'url': url.toString(), 'token': token});
}

class UsageWindow {
  UsageWindow(this.used, this.reset);
  final int used;
  final int reset;

  int? get remaining =>
      DateTime.now().millisecondsSinceEpoch ~/ 1000 < reset ? 100 - used : null;
}

class Snapshot {
  Snapshot({
    this.state = EyeMood.idle,
    this.five,
    this.week,
    this.links = const [],
    this.updatedAt,
    this.error,
    this.ticket,
    this.rearSupported = false,
    this.agents = const {},
    this.logs = const [],
    this.nativePairing,
    this.remoteState,
  });

  factory Snapshot.read(Map<Object?, Object?> json, {bool remote = false}) {
    UsageWindow? quota(String key) {
      final percent = json[key];
      final reset = json['${key}Reset'];
      return percent is int &&
              percent >= 0 &&
              percent <= 100 &&
              reset is int &&
              reset > 0
          ? UsageWindow(percent, reset)
          : null;
    }

    final updated = json['updatedAt'];
    final agents = <String, EyeMood>{};
    final reported = json['agents'];
    if (reported is Map) {
      for (final entry in reported.entries) {
        final name = entry.key;
        final mood = EyeMood.statusFromWire(entry.value);
        if (name is String && name.trim().isNotEmpty && mood != null) {
          agents[name] = mood;
        }
      }
    }
    final state = EyeMood.statusFromWire(json['state']) ?? EyeMood.idle;
    return Snapshot(
      state: state,
      agents: agents,
      logs: (json['logs'] as List? ?? []).whereType<String>().toList(),
      nativePairing: json['pairing'] as String?,
      remoteState: remote ? state : EyeMood.statusFromWire(json['remoteState']),
      five: quota('five'),
      week: quota('week'),
      links: remote
          ? const ['TAILSCALE']
          : (json['connections'] as List? ?? []).cast<String>(),
      updatedAt: remote
          ? DateTime.now()
          : updated is int
          ? DateTime.fromMillisecondsSinceEpoch(updated)
          : null,
      error: json['error'] as String?,
      ticket: json['syncTicket'] as String?,
      rearSupported: json['rearSupported'] == true,
    );
  }

  final EyeMood state;
  final UsageWindow? five;
  final UsageWindow? week;
  final List<String> links;
  final DateTime? updatedAt;
  final String? error;
  final String? ticket;
  final bool rearSupported;
  final Map<String, EyeMood> agents;
  final List<String> logs;
  final String? nativePairing;
  final EyeMood? remoteState;
}

class RemoteClient {
  Future<Snapshot> fetch(Pairing pairing) async {
    final json = await _request(pairing, '/status');
    if (EyeMood.statusFromWire(json['state']) == null) {
      throw const FormatException('电脑返回的状态无效');
    }
    return Snapshot.read(json, remote: true);
  }

  Future<void> send(Pairing pairing, String id, String text) async {
    final json = await _request(pairing, '/messages', {'id': id, 'text': text});
    if (json['id'] != id) throw const FormatException('电脑返回的送达回执无效');
  }

  Future<Map<String, Object?>> _request(
    Pairing pairing,
    String path, [
    Map<String, String>? data,
  ]) async {
    final result = await platform.request(
      pairing.url.replace(path: path),
      pairing.token,
      data,
    );
    if (result.status != 200 && result.status != 201) {
      throw RemoteFailure(result.status);
    }
    final json = jsonDecode(result.body);
    if (json is! Map<String, Object?>) throw const FormatException('电脑返回的数据无效');
    return json;
  }

  static String messageId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return [
      hex.substring(0, 8),
      hex.substring(8, 12),
      hex.substring(12, 16),
      hex.substring(16, 20),
      hex.substring(20),
    ].join('-');
  }

  static String describe(Object error) => switch (error) {
    RemoteFailure(status: 401) => '配对密钥无效，请从电脑重新复制配置。',
    RemoteFailure(status: 409) => '这条消息的编号已使用，请重新输入。',
    RemoteFailure(status: 500) => '电脑无法保存消息，请检查桌面端。',
    FormatException(:final message) => message,
    _ => '连接失败，请检查 Tailscale 和电脑服务。',
  };
}

class RemoteFailure implements Exception {
  RemoteFailure(this.status);
  final int status;
}
