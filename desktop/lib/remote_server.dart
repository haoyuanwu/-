import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'agent_mcp.dart';
import 'codex_status.dart';
import 'model_connections.dart';
import 'phone_links.dart';
import 'tailscale_endpoint.dart';
import 'web_app.dart';

class RemoteServer {
  RemoteServer(this.directory, this.onChanged);

  static const port = 18792;
  static const servePort = 8443;
  static const labels = {
    'IDLE': '待机',
    'SLEEP': '休眠',
    'THINKING': '运行中',
    'QUESTION': '等待确认',
    'DONE': '已完成',
    'ERROR': '运行出错',
    'STOPPED': '已停止',
  };

  final Directory directory;
  late final webApp = WebApp(Directory('${directory.path}/web'));
  late final phoneLinks = PhoneLinks(directory, _usbPairing, () {
    if (running) onChanged(false);
  });
  late final modelConnections = ModelConnections(directory);
  final void Function(bool newMessage) onChanged;
  late final agentMcp = AgentMcp(_publishStatus);
  final _codex = CodexStatus();
  HttpServer? _server;
  Timer? _refresh;
  String token = '';
  String? agentMcpError;
  Map<String, Object?> status = const {'state': 'IDLE'};
  Map<String, String> agentStates = const {};
  List<Map<String, dynamic>> messages = [];

  bool get running => _server != null;
  Directory get _inbox => Directory('${directory.path}/inbox');

  static Directory defaultDirectory() {
    final env = Platform.environment;
    final base = Platform.isWindows
        ? env['LOCALAPPDATA'] ?? env['USERPROFILE']!
        : '${env['HOME']}/Library/Application Support';
    final current = Directory('$base/Robot Eyes');
    final legacy = Directory('$base/Rear Eyes');
    if (!current.existsSync() && legacy.existsSync()) return legacy;
    return current;
  }

  void load() {
    directory.createSync(recursive: true);
    phoneLinks.load();
    final key = File('${directory.path}/pairing.key');
    if (!key.existsSync()) {
      final random = Random.secure();
      final bytes = List<int>.generate(32, (_) => random.nextInt(256));
      key.writeAsStringSync(
        base64UrlEncode(bytes).replaceAll('=', ''),
        flush: true,
      );
      if (!Platform.isWindows) Process.runSync('/bin/chmod', ['600', key.path]);
    }
    token = key.readAsStringSync().trim();
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token)) {
      throw const FormatException('配对密钥无效');
    }
    final inbox = _inbox;
    inbox.createSync(recursive: true);
    messages = [];
    for (final entry in inbox.listSync(followLinks: false)) {
      if (entry is! File || !entry.path.endsWith('.json')) continue;
      try {
        final item = jsonDecode(entry.readAsStringSync());
        if (item is Map<String, dynamic> &&
            item['id'] is String &&
            item['text'] is String &&
            item['at'] is String) {
          messages.add(item);
        }
      } on FormatException {
        // A manually edited or damaged file must not block the inbox.
      }
    }
    messages.sort(
      (first, second) =>
          (first['at'] as String).compareTo(second['at'] as String),
    );
  }

  Future<void> start() async {
    if (running) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    try {
      load();
      agentMcpError = null;
      try {
        await agentMcp.start(directory);
      } on SocketException {
        agentMcpError = '无法启动 MCP，请检查端口 ${AgentMcp.port}。';
      } on FileSystemException {
        agentMcpError = '无法读取或保存桌面 MCP 密钥。';
      } on FormatException {
        agentMcpError = '桌面 MCP 密钥无效。';
      }
      _update();
      server.idleTimeout = const Duration(seconds: 10);
      _server = server;
      server.listen(_handle);
      unawaited(phoneLinks.push(status));
      _refresh = Timer.periodic(
        const Duration(seconds: 3),
        (_) => _publishStatus(),
      );
      modelConnections.startMonitoring(_publishStatus);
    } catch (_) {
      await agentMcp.stop();
      await server.close(force: true);
      rethrow;
    }
  }

  Future<void> stop() async {
    _refresh?.cancel();
    final server = _server;
    _server = null;
    agentStates = const {};
    phoneLinks.stop();
    modelConnections.stop();
    await agentMcp.stop();
    await server?.close(force: true);
  }

  Future<String?> _usbPairing() async {
    final address = await findTailscaleEndpoint(port, servePort);
    if (address == null || !running) return null;
    return jsonEncode({'url': address, 'token': token});
  }

  void refreshPhoneLinks() {
    if (running) unawaited(phoneLinks.push(status));
  }

  void _publishStatus() {
    if (!running) return;
    _update();
    refreshPhoneLinks();
    onChanged(false);
  }

  void _update() {
    final snapshot = _codex.read();
    final codexState = snapshot['state'] as String;
    final agents = agentMcp.states();
    if (Platform.isMacOS) {
      final env = Platform.environment;
      final path = '${env['HOME']}/.local/state/reareyes/agents.sqlite3';
      if (File(path).existsSync()) {
        final result = Process.runSync('/usr/bin/sqlite3', [
          '-readonly',
          '-json',
          '-cmd',
          '.timeout 100',
          path,
          "SELECT DISTINCT name, state FROM agents WHERE expires > strftime('%s','now');",
        ]);
        if (result.exitCode == 0) {
          final rows = (result.stdout as String).trim();
          if (rows.isNotEmpty) {
            for (final row in jsonDecode(rows) as List) {
              final name = AgentMcp.nameOf(row['name']);
              final state = row['state'];
              if (name != null &&
                  state is String &&
                  labels.containsKey(state)) {
                AgentMcp.mergeState(agents, name, state);
              }
            }
          }
        }
      }
    }
    final states = {...agents.values, codexState};
    snapshot['state'] = AgentMcp.priority
        .take(4)
        .firstWhere(
          states.contains,
          orElse: () => codexState == 'STOPPED' ? 'IDLE' : codexState,
        );
    AgentMcp.mergeState(agents, 'Codex', codexState);
    final ordered = agents.keys.toList()
      ..sort((a, b) {
        final byState = AgentMcp.priority
            .indexOf(agents[a]!)
            .compareTo(AgentMcp.priority.indexOf(agents[b]!));
        return byState != 0 ? byState : a.compareTo(b);
      });
    agentStates = {for (final name in ordered) name: agents[name]!};
    status = {
      ...snapshot,
      'agents': {for (final name in ordered.take(24)) name: agents[name]!},
      'models': modelConnections.publishedModels(),
      'at': DateTime.now().toUtc().toIso8601String(),
    };
  }

  bool _authorized(HttpRequest request) {
    final values = request.headers[HttpHeaders.authorizationHeader];
    if (values == null || values.length != 1) return false;
    final expected = 'Bearer $token';
    final supplied = values.single;
    if (expected.length != supplied.length) return false;
    var difference = 0;
    for (var index = 0; index < expected.length; index++) {
      difference |= expected.codeUnitAt(index) ^ supplied.codeUnitAt(index);
    }
    return difference == 0;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    try {
      final path = request.uri.path;
      final api =
          path == '/status' ||
          path == '/messages' ||
          path == '/ai/models' ||
          path == '/ai/chat';
      if (!api && await webApp.serve(request)) return;
      if (!api) {
        _reply(response, 404, {'error': 'not_found'});
      } else if (!_authorized(request)) {
        _reply(response, 401, {'error': 'invalid_token'});
      } else if (request.uri.path == '/status' && request.method == 'GET') {
        _reply(response, 200, status);
      } else if (request.uri.path == '/messages' && request.method == 'POST') {
        await _receive(request);
      } else if (path == '/ai/models' && request.method == 'GET') {
        _reply(response, 200, {'models': modelConnections.publishedModels()});
      } else if (path == '/ai/chat' && request.method == 'POST') {
        await modelConnections.chat(request);
      } else if (path == '/ai/chat' && request.method == 'DELETE') {
        modelConnections.cancelRequest(request.uri.queryParameters['id']);
        response.statusCode = HttpStatus.noContent;
      } else {
        _reply(response, 404, {'error': 'not_found'});
      }
    } on TimeoutException {
      _reply(response, 408, {'error': 'timeout'});
    } on FormatException {
      _reply(response, 400, {'error': 'invalid_message'});
    } on FileSystemException {
      _reply(response, 500, {'error': 'storage_error'});
    } on IOException {
      // The client disconnected before the exchange finished.
    } finally {
      try {
        await response.close();
      } on IOException {
        // The client can safely retry with the same message ID.
      }
    }
  }

  Future<void> _receive(HttpRequest request) async {
    final response = request.response;
    final bytes = <int>[];
    await for (final chunk in request.timeout(const Duration(seconds: 5))) {
      if (bytes.length + chunk.length > 16384) {
        _reply(response, 413, {'error': 'message_too_large'});
        return;
      }
      bytes.addAll(chunk);
    }
    final value = jsonDecode(utf8.decode(bytes));
    final id = value is Map ? value['id'] : null;
    final text = value is Map ? value['text'] : null;
    if (id is! String ||
        !RegExp(r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$')
            .hasMatch(id) ||
        text is! String ||
        text.trim().isEmpty ||
        text.length > 2000) {
      throw const FormatException('invalid message');
    }
    for (final message in messages) {
      if (message['id'] != id) continue;
      if (message['text'] != text.trim()) {
        _reply(response, 409, {'error': 'id_conflict'});
      } else {
        _reply(response, 200, {'id': id, 'at': message['at']});
      }
      return;
    }
    final at = DateTime.now().toUtc().toIso8601String();
    final message = <String, dynamic>{'id': id, 'text': text.trim(), 'at': at};
    final destination = '${_inbox.path}/$id.json';
    final pending = File('$destination.tmp');
    pending.writeAsStringSync(jsonEncode(message), flush: true);
    pending.renameSync(destination);
    messages.add(message);
    _reply(response, 201, {'id': id, 'at': at});
    onChanged(true);
  }

  void _reply(HttpResponse response, int code, Map<String, Object?> data) {
    response.statusCode = code;
    response.write(jsonEncode(data));
  }
}
