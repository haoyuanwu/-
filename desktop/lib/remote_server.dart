import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:robot_eyes_models/lan_crypto.dart';

import 'agent_mcp.dart';
import 'codex_status.dart';
import 'model_connections.dart';
import 'phone_links.dart';
import 'phone_model_bindings.dart';
import 'tailscale_endpoint.dart';
import 'web_app.dart';

class RemoteServer {
  RemoteServer(this.directory, this.onChanged);

  static const port = 18792;
  static const lanPort = 18794;
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
  late final phoneModels = PhoneModelBindings(directory, modelConnections);
  final void Function(bool newMessage) onChanged;
  late final agentMcp = AgentMcp(_publishStatus);
  final _codex = CodexStatus();
  HttpServer? _server;
  HttpServer? _lanServer;
  RawDatagramSocket? _lanDiscovery;
  String? _lanCode;
  DateTime? _lanCodeExpiry;
  int _lanCodeAttempts = 0;
  bool _openingLan = false;
  Timer? _refresh;
  String token = '';
  String desktopId = '';
  LanCrypto? _lanCrypto;
  final _lanRequests = <String, int>{};
  String get desktopName {
    final name = Platform.localHostname.replaceFirst(
      RegExp(r'\.local$', caseSensitive: false),
      '',
    );
    return name.substring(0, min(80, name.length));
  }

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
    final identity = File('${directory.path}/desktop-id');
    if (!identity.existsSync()) {
      final random = Random.secure();
      identity.writeAsStringSync(
        List.generate(24, (_) => random.nextInt(16).toRadixString(16)).join(),
        flush: true,
      );
    }
    desktopId = identity.readAsStringSync().trim();
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
      _lanCrypto = await _loadLanCrypto();
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
      refreshPhoneLinks();
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
    final lanServer = _lanServer;
    _server = null;
    _lanServer = null;
    _lanDiscovery?.close();
    _lanDiscovery = null;
    _lanCode = null;
    _lanRequests.clear();
    phoneLinks.lanModelService = false;
    agentStates = const {};
    phoneLinks.stop();
    modelConnections.stop();
    await agentMcp.stop();
    await lanServer?.close(force: true);
    await server?.close(force: true);
  }

  Future<String?> _usbPairing() async {
    final address = await findTailscaleEndpoint(port, servePort);
    if (address == null || !running) return null;
    return jsonEncode({
      'url': address,
      'token': token,
      'desktopId': desktopId,
      'desktopName': desktopName,
    });
  }

  void refreshPhoneLinks() {
    if (!running) return;
    unawaited(_refreshLanService());
    unawaited(phoneLinks.push(status));
  }

  Future<void> _refreshLanService() async {
    final owner = _server;
    if (owner == null) return;
    if (_lanServer != null || _openingLan) return;
    _openingLan = true;
    try {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, lanPort);
      if (_server != owner) {
        await server.close(force: true);
        return;
      }
      _lanServer = server;
      phoneLinks.lanModelService = true;
      server.idleTimeout = const Duration(seconds: 10);
      server.listen((request) => _handle(request, lan: true));
      unawaited(phoneLinks.push(status));
      final discovery = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        lanPort,
        reuseAddress: false,
      );
      if (_server != owner) {
        discovery.close();
        return;
      }
      _lanDiscovery = discovery;
      final beacon = utf8.encode(
        jsonEncode({
          'service': 'robot-eyes:1',
          'name': desktopName,
          'id': desktopId,
        }),
      );
      discovery.listen((event) {
        if (event != RawSocketEvent.read) return;
        for (
          var datagram = discovery.receive();
          datagram != null;
          datagram = discovery.receive()
        ) {
          if (!_localPeer(datagram.address) ||
              datagram.data.length != 12 ||
              String.fromCharCodes(datagram.data) != 'robot-eyes:1') {
            continue;
          }
          discovery.send(beacon, datagram.address, datagram.port);
        }
      });
    } on SocketException {
      // The status channel remains usable if the local model port is occupied.
    } finally {
      _openingLan = false;
    }
  }

  String createLanCode() {
    final code = Random.secure().nextInt(100000000).toString().padLeft(8, '0');
    _lanCode = code;
    _lanCodeExpiry = DateTime.now().add(const Duration(minutes: 5));
    _lanCodeAttempts = 0;
    return code;
  }

  Future<LanCrypto> _loadLanCrypto() async {
    final file = File('${directory.path}/lan-crypto.key');
    if (!file.existsSync()) {
      final random = Random.secure();
      file.writeAsStringSync(
        base64UrlEncode(List.generate(32, (_) => random.nextInt(256))),
        flush: true,
      );
      if (!Platform.isWindows) {
        Process.runSync('/bin/chmod', ['600', file.path]);
      }
    }
    return LanCrypto.fromSeed(file.readAsStringSync().trim());
  }

  bool _localPeer(InternetAddress? address) {
    if (address == null || address.type != InternetAddressType.IPv4) {
      return false;
    }
    final b = address.rawAddress;
    return b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168) ||
        (b[0] == 169 && b[1] == 254);
  }

  Future<void> _pairLan(HttpRequest request, {required bool lan}) async {
    final peer = request.connectionInfo?.remoteAddress;
    final trusted = !lan && _authorized(request, 'Bearer $token');
    if ((lan && !_localPeer(peer)) || (!lan && !trusted)) {
      _reply(request.response, 401, {'error': 'pairing_required'});
      return;
    }
    final bytes = <int>[];
    await for (final chunk in request.timeout(const Duration(seconds: 4))) {
      if (bytes.length + chunk.length > 1024) throw const FormatException();
      bytes.addAll(chunk);
    }
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map || data['token'] is! String) throw const FormatException();
    final phoneToken = data['token'] as String;
    final address = lan ? peer!.address : data['address'];
    if (address is! String) throw const FormatException();
    final known = phoneLinks.hasPhoneToken('Bearer $phoneToken');
    final codeActive =
        _lanCode != null &&
        (_lanCodeExpiry?.isAfter(DateTime.now()) ?? false) &&
        _lanCodeAttempts < 8;
    if (lan && codeActive && (!known || data['code'] != null)) {
      _lanCodeAttempts++;
    }
    final usingCode = lan && codeActive && data['code'] == _lanCode;
    if (!(trusted || known || usingCode) ||
        !phoneLinks.registerLanPhone(
          address,
          phoneToken,
          trustedKey: usingCode || trusted,
          name: readPhoneName(data['phoneName']),
          phoneKey: LanCrypto.validKey(data['phoneKey'])
              ? data['phoneKey'] as String
              : null,
        )) {
      _reply(request.response, 401, {'error': 'pairing_required'});
      return;
    }
    if (usingCode) _lanCode = null;
    refreshPhoneLinks();
    final tail = lan
        ? await findTailscaleEndpoint(
            port,
            servePort,
          ).timeout(const Duration(seconds: 1), onTimeout: () => null)
        : null;
    _reply(request.response, 200, {
      'ok': true,
      'desktopId': desktopId,
      'desktopName': desktopName,
      'lanKey': _lanCrypto?.publicKey,
      'tailscale': ?tail,
    });
    onChanged(false);
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
    final now = DateTime.now();
    final cutoff = now.subtract(AgentMcp.completionDuration);
    var recentlyCompleted =
        (_codex.lastCompletion?.isAfter(cutoff) ?? false) ||
        (agentMcp.lastCompletion?.isAfter(cutoff) ?? false);
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
          "SELECT name, state, MAX(expires) AS expires FROM agents "
              "WHERE expires > strftime('%s','now') GROUP BY name, state;",
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
                final expires = row['expires'];
                if (state == 'DONE' && expires is num) {
                  recentlyCompleted |=
                      expires - 30 > cutoff.millisecondsSinceEpoch / 1000;
                }
              }
            }
          }
        }
      }
    }
    final states = {...agents.values, codexState};
    snapshot['state'] = AgentMcp.displayState(
      states,
      fallback: codexState == 'STOPPED' ? 'IDLE' : codexState,
      recentlyCompleted: recentlyCompleted,
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
      'desktopId': desktopId,
      'desktopName': desktopName,
      'lanKey': _lanCrypto?.publicKey,
      'agents': {for (final name in ordered.take(24)) name: agents[name]!},
      'models': modelConnections.publishedModels(),
      'at': DateTime.now().toUtc().toIso8601String(),
    };
  }

  bool _authorized(HttpRequest request, String? expected) {
    final values = request.headers[HttpHeaders.authorizationHeader];
    if (expected == null || values == null || values.length != 1) return false;
    final supplied = values.single;
    if (expected.length != supplied.length) return false;
    var difference = 0;
    for (var index = 0; index < expected.length; index++) {
      difference |= expected.codeUnitAt(index) ^ supplied.codeUnitAt(index);
    }
    return difference == 0;
  }

  Future<void> _handle(HttpRequest request, {bool lan = false}) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    try {
      final path = request.uri.path;
      final headers = request.headers[HttpHeaders.authorizationHeader];
      final authorization = headers?.length == 1 ? headers!.single : null;
      if (path == '/lan/pair' && request.method == 'POST') {
        await _pairLan(request, lan: lan);
        return;
      }
      if (!lan &&
          path == '/lan/tailscale-pairing' &&
          request.method == 'POST') {
        if (authorization == null || !phoneLinks.hasPhoneToken(authorization)) {
          _reply(response, 401, {'error': 'pairing_required'});
        } else {
          await _encryptedExchange(
            request,
            phoneLinks.keyFor(authorization),
            (_) => {'token': token, 'desktopId': desktopId},
          );
        }
        return;
      }
      final modelApi = path == '/ai/models' || path == '/ai/chat';
      final api = lan
          ? path == '/status' || path == '/ai/phone-model' || modelApi
          : path == '/status' ||
                path == '/messages' ||
                path == '/ai/phone-model' ||
                modelApi;
      if (!lan && !api && await webApp.serve(request)) return;
      if (!api) {
        _reply(response, 404, {'error': 'not_found'});
      } else if (lan
          ? !phoneLinks.isLanPhone(authorization, request.connectionInfo?.remoteAddress)
          : !_authorized(request, 'Bearer $token')) {
        _reply(response, 401, {'error': 'invalid_token'});
      } else if (request.uri.path == '/status' && request.method == 'GET') {
        if (lan) {
          phoneLinks.recordLanPhone(authorization!);
        } else {
          final name = request.headers['x-robot-eyes-phone-name']?.firstOrNull;
          phoneLinks.recordTailscalePhone(
            request.headers['x-robot-eyes-phone-id']?.firstOrNull,
            name == null ? null : _decodePhoneName(name),
          );
        }
        _reply(
          response,
          200,
          lan
              ? {
                  ...status,
                  'modelApi': 1,
                  'configSync': phoneLinks.keyFor(authorization) != null,
                }
              : status,
        );
      } else if (request.uri.path == '/messages' && request.method == 'POST') {
        await _receive(request);
      } else if (path == '/ai/models' && request.method == 'GET') {
        _reply(response, 200, {'models': modelConnections.publishedModels()});
      } else if (path == '/ai/phone-model' && request.method == 'POST') {
        if (lan) {
          await _encryptedExchange(
            request,
            phoneLinks.keyFor(authorization),
            phoneModels.exchange,
          );
          onChanged(false);
        } else {
          await _exchangePhoneModel(request);
        }
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

  String? _decodePhoneName(String value) {
    if (value.length > 512) return null;
    try {
      return Uri.decodeComponent(value);
    } on ArgumentError {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<void> _encryptedExchange(
    HttpRequest request,
    String? key,
    Map<String, Object?> Function(Map<String, Object?>) exchange,
  ) async {
    final crypto = _lanCrypto;
    if (crypto == null || key == null) {
      _reply(request.response, 403, {'error': 'lan_key_required'});
      return;
    }
    final bytes = <int>[];
    await for (final chunk in request.timeout(const Duration(seconds: 5))) {
      if (bytes.length + chunk.length > 18 * 1024) {
        throw const FormatException();
      }
      bytes.addAll(chunk);
    }
    final envelope = jsonDecode(utf8.decode(bytes));
    final id = envelope is Map ? envelope['id'] : null;
    if (id is! String || !RegExp(r'^[a-f0-9-]{36}$').hasMatch(id)) {
      throw const FormatException();
    }
    final context = 'Robot Eyes ${request.uri.path} $id';
    final box = await crypto.withPeer(key);
    final payload = await box.open(envelope, '$context request');
    final now = DateTime.now().millisecondsSinceEpoch;
    final at = payload.remove('at');
    _lanRequests.removeWhere((_, expires) => expires <= now);
    if (at is! int ||
        (now - at).abs() > 120000 ||
        _lanRequests.containsKey(id)) {
      throw const FormatException();
    }
    if (_lanRequests.length >= 512) {
      _reply(request.response, 429, {'error': 'busy'});
      return;
    }
    _lanRequests[id] = now + 240000;
    _reply(
      request.response,
      200,
      await box.seal(exchange(payload), '$context response'),
    );
  }

  Future<void> _exchangePhoneModel(HttpRequest request) async {
    final bytes = <int>[];
    await for (final chunk in request.timeout(const Duration(seconds: 5))) {
      if (bytes.length + chunk.length > 12 * 1024) {
        _reply(request.response, 413, {'error': 'message_too_large'});
        return;
      }
      bytes.addAll(chunk);
    }
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map<String, Object?>) throw const FormatException();
    _reply(request.response, 200, phoneModels.exchange(data));
    onChanged(false);
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
