import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

class AgentMcp {
  AgentMcp(this.onChanged);

  static const port = 18793;
  static const completionDuration = Duration(seconds: 5);

  static String displayState(
    Set<String> states, {
    required String fallback,
    required bool recentlyCompleted,
  }) {
    if (recentlyCompleted &&
        states.contains('THINKING') &&
        !states.contains('QUESTION')) {
      return 'DONE';
    }
    return priority.take(4).firstWhere(states.contains, orElse: () => fallback);
  }

  static const versions = ['2025-11-25', '2025-06-18', '2025-03-26'];
  static const priority = [
    'QUESTION',
    'THINKING',
    'ERROR',
    'DONE',
    'STOPPED',
    'IDLE',
    'SLEEP',
  ];
  static const instructions =
      'Call set_eye_state when starting or resuming work, waiting for approval, '
      'finishing (DONE), failing (ERROR), or cancelling (STOPPED). '
      'Use the same session ID for all updates of a task.';
  static const _serverInfo = {'name': 'robot-eyes', 'version': '1.0.0'};
  static const _tool = {
    'name': 'set_eye_state',
    'description': instructions,
    'annotations': {
      'readOnlyHint': false,
      'destructiveHint': false,
      'idempotentHint': true,
      'openWorldHint': false,
    },
    'inputSchema': {
      'type': 'object',
      'properties': {
        'state': {'type': 'string', 'enum': priority},
        'session': {'type': 'string', 'maxLength': 64},
      },
      'required': ['state'],
      'additionalProperties': false,
    },
  };

  final void Function() onChanged;
  final _random = Random.secure();
  final _clients = <String, _Client>{};
  final _recentlyClosed = <String, ({String state, DateTime until})>{};
  HttpServer? _server;
  String _token = '';
  bool get running => _server != null;
  ({String name, DateTime at})? _lastReportingVerification;
  ({String name, DateTime at})? get lastReportingVerification {
    final verification = _lastReportingVerification;
    if (verification == null) return null;
    return (
      name: nameOf(verification.name) ?? verification.name,
      at: verification.at,
    );
  }

  Future<void> start(Directory directory) async {
    final key = File('${directory.path}/desktop-mcp.key');
    if (!key.existsSync()) {
      key.writeAsStringSync(_randomId(), flush: true);
      if (!Platform.isWindows) Process.runSync('/bin/chmod', ['600', key.path]);
    }
    _token = key.readAsStringSync().trim();
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(_token)) {
      throw const FormatException('桌面 MCP 密钥无效');
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    server.idleTimeout = const Duration(seconds: 10);
    _server = server;
    server.listen(_handle);
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
    _clients.clear();
    _recentlyClosed.clear();
    lastCompletion = null;
  }

  String _randomId() =>
      base64UrlEncode(List<int>.generate(32, (_) => _random.nextInt(256)))
          .replaceAll('=', '');

  static String? nameOf(Object? value) {
    if (value is! String) return null;
    final name = value.trim();
    if (name.isEmpty ||
        name.length > 64 ||
        RegExp(r'[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]')
            .hasMatch(name)) {
      return null;
    }
    final key = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    for (final known in ['WorkBuddy', 'OpenCode', 'OpenClaw', 'Codex']) {
      final product = known.toLowerCase();
      if (key == product || key == '${product}mcpclient') return known;
    }
    return name;
  }

  static String url() => Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: port,
    path: '/mcp',
  ).toString();

  String configuration({bool includeCredential = false}) =>
      const JsonEncoder.withIndent('  ').convert({
        'mcpServers': {
          'robot-eyes': {
            'type': 'streamableHttp',
            'url': url(),
            'headers': {
              'Authorization': includeCredential
                  ? 'Bearer $_token'
                  : 'Bearer ••••••••',
            },
          },
        },
      });

  String setupPrompt(String skill) =>
      '''
请在你当前使用的 AI 客户端中配置 Robot Eyes，并实际执行下面的安装和验证步骤。

1. 识别当前客户端和实际运行环境。Robot Eyes 的 MCP 在运行桌面端的同一台电脑上监听回环地址，MCP 客户端需能访问该地址。
2. 将下方通用配置转换为当前客户端支持的 Streamable HTTP 格式，合并到其用户级 MCP 设置，保留其他服务器和现有设置。复用已有的 robot-eyes 条目。按客户端支持的方式保存 Authorization，密钥只写入 MCP 所需的本机配置或凭据存储。
3. 将下方文件完整保存为客户端用户级 Skills 目录中的 robot-eyes-reporting/SKILL.md，启用该 Skill，并按客户端支持的方式让它应用于后续任务。如果客户端只有持久规则，将 Skill 正文合并到用户级任务规则。
4. 用客户端加载 robot-eyes，验证能列出 set_eye_state，并用独立的测试 session 调用 IDLE，确认返回成功。桌面端「桌面 AI MCP」会显示最近验证的客户端和时间。说明安装位置和验证结果。若客户端需要重启、授权或无法访问本机服务，请指出待完成的步骤。答复中不要输出密钥。

通用 MCP 配置

```json
${configuration(includeCredential: true)}
```

robot-eyes-reporting/SKILL.md

````markdown
${skill.trimRight()}
````
''';

  /// Groups initialized HTTP sessions by client name, independent of task state.
  List<({String name, DateTime lastSeen})> connectedClients() {
    _prune(DateTime.now());
    final clients = <String, ({String name, DateTime lastSeen})>{};
    for (final client in _clients.values) {
      if (!client.ready) continue;
      final productName = client.productName;
      final key = productName.toLowerCase();
      final previous = clients[key];
      clients[key] = (
        name: previous?.name ?? productName,
        lastSeen: previous != null && previous.lastSeen.isAfter(client.seen)
            ? previous.lastSeen
            : client.seen,
      );
    }
    return clients.values.toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
  }

  DateTime? lastCompletion;

  Map<String, String> states() {
    final now = DateTime.now();
    _prune(now);
    final states = <String, String>{};
    _recentlyClosed.removeWhere((_, task) => !task.until.isAfter(now));
    for (final entry in _recentlyClosed.entries) {
      mergeState(states, nameOf(entry.key) ?? entry.key, entry.value.state);
    }
    for (final client in _clients.values) {
      if (!client.ready) continue;
      client.tasks.removeWhere((_, task) => !task.until.isAfter(now));
      final state = priority.firstWhere(
        (state) => client.tasks.values.any((task) => task.state == state),
        orElse: () => 'IDLE',
      );
      mergeState(states, client.productName, state);
    }
    return states;
  }

  static void mergeState(
    Map<String, String> states,
    String name,
    String state,
  ) {
    final matchingName = states.keys.firstWhere(
      (existing) => existing.toLowerCase() == name.toLowerCase(),
      orElse: () => name,
    );
    final old = states[matchingName];
    if (old == null || priority.indexOf(state) < priority.indexOf(old)) {
      states[matchingName] = state;
    }
  }

  void _prune(DateTime now) {
    _clients.removeWhere(
      (_, client) => now.difference(client.seen) >= const Duration(hours: 2),
    );
  }

  bool _authorized(HttpRequest request) {
    final values = request.headers[HttpHeaders.authorizationHeader];
    if (values == null || values.length != 1) return false;
    final supplied = values.single;
    final expected = 'Bearer $_token';
    if (supplied.length != expected.length) return false;
    var difference = 0;
    for (var i = 0; i < expected.length; i++) {
      difference |= supplied.codeUnitAt(i) ^ expected.codeUnitAt(i);
    }
    return difference == 0;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    try {
      final host = request.headers.value(HttpHeaders.hostHeader);
      if (request.headers['origin'] != null ||
          (host != '127.0.0.1:$port' && host != 'localhost:$port')) {
        response.statusCode = 403;
      } else if (request.uri.path != '/mcp') {
        response.statusCode = 404;
      } else if (!_authorized(request)) {
        response.statusCode = 401;
        response.headers.set(HttpHeaders.wwwAuthenticateHeader, 'Bearer');
      } else if (request.method == 'DELETE') {
        final removed = _clients.remove(
          request.headers.value('mcp-session-id'),
        );
        response.statusCode = removed == null ? 404 : 204;
        if (removed != null) {
          _retainClosedState(removed);
          onChanged();
        }
      } else if (request.method != 'POST') {
        response.statusCode = 405;
        response.headers.set(HttpHeaders.allowHeader, 'POST, DELETE');
      } else if (request.headers.contentType?.mimeType != 'application/json') {
        response.statusCode = 415;
      } else {
        final bytes = <int>[];
        await for (final chunk in request.timeout(const Duration(seconds: 5))) {
          if (bytes.length + chunk.length > 16384) {
            response.statusCode = 413;
            return;
          }
          bytes.addAll(chunk);
        }
        _dispatch(request, jsonDecode(utf8.decode(bytes)));
      }
    } on TimeoutException {
      response.statusCode = 408;
    } on FormatException {
      _error(response, null, -32700, 'Parse error', status: 400);
    } on HttpException {
      response.statusCode = 400;
    } on IOException {
      // The local client disconnected.
    } finally {
      try {
        await response.close();
      } on IOException {
        // The local client disconnected.
      }
    }
  }

  void _dispatch(HttpRequest request, Object? body) {
    final response = request.response;
    final id = body is Map ? body['id'] : null;
    final method = body is Map ? body['method'] : null;
    if (body is! Map ||
        body['jsonrpc'] != '2.0' ||
        method is! String ||
        (id != null && id is! String && id is! num)) {
      _error(response, null, -32600, 'Invalid request', status: 400);
      return;
    }
    final rawParams = body['params'];
    final params = rawParams is Map ? rawParams : const {};
    final now = DateTime.now();
    _prune(now);
    if (method == 'initialize' && id != null) {
      final info = params['clientInfo'];
      final clientName =
          nameOf(request.uri.queryParameters['client']) ??
          nameOf(info is Map ? info['title'] : null) ??
          nameOf(info is Map ? info['name'] : null);
      if (clientName == null || params['protocolVersion'] is! String) {
        _error(
          response,
          id,
          -32602,
          'Client name and protocol version required',
        );
        return;
      }
      if (_clients.length >= 64) {
        _error(response, id, -32000, 'Too many MCP connections', status: 503);
        return;
      }
      final version = versions.contains(params['protocolVersion'])
          ? params['protocolVersion'] as String
          : versions.first;
      final session = _randomId();
      _clients[session] = _Client(clientName, version, now);
      response.headers.set('mcp-session-id', session);
      _reply(response, id, {
        'protocolVersion': version,
        'serverInfo': _serverInfo,
        'capabilities': {'tools': <String, Object?>{}},
        'instructions': instructions,
      });
      return;
    }
    final session = request.headers.value('mcp-session-id');
    final client = _clients[session];
    if (client == null) {
      _error(
        response,
        id,
        -32001,
        'MCP session required',
        status: session == null ? 400 : 404,
      );
      return;
    }
    final version = request.headers.value('mcp-protocol-version');
    if (version != null && version != client.version) {
      _error(response, id, -32602, 'Unsupported protocol version', status: 400);
      return;
    }
    client.seen = now;
    if (!client.ready &&
        (method == 'notifications/initialized' || id != null)) {
      client.ready = true;
      onChanged();
    }
    if (id == null) {
      response.statusCode = 202;
      return;
    }
    switch (method) {
      case 'ping':
        _reply(response, id, {});
      case 'tools/list':
        _reply(response, id, {
          'tools': [_tool],
        });
      case 'tools/call':
        if (params['name'] != 'set_eye_state') {
          _error(response, id, -32602, 'Unknown tool');
          return;
        }
        _reply(response, id, _setState(client, params['arguments'], now));
      default:
        _error(response, id, -32601, 'Method not found');
    }
  }

  void _retainClosedState(_Client client) {
    final now = DateTime.now();
    final states = client.tasks.values
        .where((task) => task.until.isAfter(now))
        .map((task) => task.state)
        .toSet();
    final String state;
    if (states.contains('ERROR')) {
      state = 'ERROR';
    } else if (states.any(const {'THINKING', 'QUESTION', 'STOPPED'}.contains)) {
      state = 'STOPPED';
    } else {
      return;
    }
    final productName = client.productName;
    if (_recentlyClosed.length >= 64 &&
        !_recentlyClosed.containsKey(productName)) {
      _recentlyClosed.remove(_recentlyClosed.keys.first);
    }
    _recentlyClosed[productName] = (
      state: state,
      until: now.add(const Duration(seconds: 30)),
    );
  }

  Map<String, Object?> _setState(_Client client, Object? args, DateTime now) {
    final state = args is Map ? args['state'] : null;
    final task = args is Map && args.containsKey('session')
        ? args['session']
        : 'default';
    if (state is! String ||
        !priority.contains(state) ||
        task is! String ||
        task.isEmpty ||
        task.length > 64 ||
        (args as Map).keys.any((key) => key != 'state' && key != 'session')) {
      return _toolResult(
        'Provide a valid state and optional session ID.',
        error: true,
      );
    }
    final productName = client.productName;
    _recentlyClosed.removeWhere(
      (name, _) =>
          (nameOf(name) ?? name).toLowerCase() == productName.toLowerCase(),
    );
    client.tasks.removeWhere((_, task) => !task.until.isAfter(now));
    if (state == 'IDLE' || state == 'SLEEP') {
      client.tasks.remove(task);
    } else {
      if (client.tasks.length >= 64 && !client.tasks.containsKey(task)) {
        return _toolResult('Too many active tasks.', error: true);
      }
      final lifetime = state == 'QUESTION' || state == 'THINKING'
          ? const Duration(minutes: 15)
          : const Duration(seconds: 30);
      if (state == 'DONE' && client.tasks[task]?.state != 'DONE') {
        lastCompletion = now;
      }
      client.tasks[task] = (state: state, until: now.add(lifetime));
    }
    if (!client.reportingVerified) {
      client.reportingVerified = true;
      _lastReportingVerification = (name: productName, at: now);
    }
    onChanged();
    return _toolResult('$productName: $state');
  }

  Map<String, Object?> _toolResult(String text, {bool error = false}) => {
    'isError': error,
    'content': [
      {'type': 'text', 'text': text},
    ],
  };

  void _reply(HttpResponse response, Object? id, Map<String, Object?> result) {
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}));
  }

  void _error(
    HttpResponse response,
    Object? id,
    int code,
    String message, {
    int status = 200,
  }) {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      }),
    );
  }
}

class _Client {
  _Client(this.name, this.version, this.seen);

  final String name;
  String get productName => AgentMcp.nameOf(name) ?? name;
  final String version;
  DateTime seen;
  bool ready = false;
  bool reportingVerified = false;
  final tasks = <String, ({String state, DateTime until})>{};
}
