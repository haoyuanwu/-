import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

class ModelProfile {
  ModelProfile({
    required this.id,
    required String name,
    required String address,
    required String model,
    required String apiKey,
    required this.kind,
  }) : name = name.trim(),
       endpoint = _endpoint(address),
       model = model.trim(),
       apiKey = apiKey.trim() {
    if (this.name.isEmpty || this.name.length > 80) {
      throw const FormatException('请输入 1 到 80 个字符的连接名称。');
    }
    if (this.model.isEmpty || this.model.length > 200) {
      throw const FormatException('请输入模型名称或 ID。');
    }
    if (this.apiKey.length > 2048 ||
        this.apiKey.contains(RegExp(r'[^\x21-\x7e]'))) {
      throw const FormatException('访问密钥格式无效。');
    }
    if (kind != 'local' && kind != 'cloud') {
      throw const FormatException('连接类型无效。');
    }
  }

  final String id;
  final String name;
  final Uri endpoint;
  final String model;
  final String apiKey;
  final String kind;

  static Uri _endpoint(String address) {
    final uri = Uri.tryParse(address.trim());
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.scheme != 'https' &&
            !(uri.scheme == 'http' &&
                const ['127.0.0.1', 'localhost', '::1'].contains(uri.host)))) {
      throw const FormatException('请输入 HTTPS 地址，或本机模型的 HTTP 回环地址。');
    }
    final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    return uri.replace(
      path: path.endsWith('/chat/completions')
          ? path
          : '$path/chat/completions',
    );
  }

  Map<String, String> toJson() => {
    'id': id,
    'name': name,
    'url': endpoint.toString(),
    'model': model,
    'apiKey': apiKey,
    'kind': kind,
  };

  static ModelProfile fromJson(Object? value) {
    if (value is! Map ||
        ![
          'id',
          'name',
          'url',
          'model',
          'apiKey',
          'kind',
        ].every((key) => value[key] is String)) {
      throw const FormatException('模型连接配置无效。');
    }
    return ModelProfile(
      id: value['id'] as String,
      name: value['name'] as String,
      address: value['url'] as String,
      model: value['model'] as String,
      apiKey: value['apiKey'] as String,
      kind: value['kind'] as String,
    );
  }
}

class ModelConnections {
  ModelConnections(this.directory);

  final Directory directory;
  late List<ModelProfile> _profiles = _load();
  final _available = <String, bool>{};
  final _active = <String, HttpClient>{};
  final _cancelled = <HttpClient>{};
  String? loadError;
  static const _timeout = Duration(seconds: 45);
  static const _maxBody = 96 * 1024;
  static final _requestId = RegExp(r'^[a-zA-Z0-9_-]{1,64}$');

  File get _file => File('${directory.path}/model-connections.json');
  List<ModelProfile> get profiles => List.unmodifiable(_profiles);

  static String newId() {
    final random = Random.secure();
    return base64UrlEncode(List<int>.generate(18, (_) => random.nextInt(256)));
  }

  List<ModelProfile> _load() {
    try {
      if (!_file.existsSync()) return [];
      final data = jsonDecode(_file.readAsStringSync());
      if (data is! List) throw const FormatException();
      return data.map(ModelProfile.fromJson).toList();
    } on FormatException {
      loadError = '无法读取已保存的模型连接。';
    } on FileSystemException {
      loadError = '无法读取模型连接文件，请检查权限。';
    }
    return [];
  }

  void save(ModelProfile profile, {bool? tested}) {
    final next = [..._profiles];
    final index = next.indexWhere((value) => value.id == profile.id);
    if (index == -1) {
      if (next.length >= 20) throw const FormatException('最多保存 20 个模型连接。');
      next.add(profile);
    } else {
      final previous = next[index];
      next[index] = profile;
      if (previous.endpoint != profile.endpoint ||
          previous.model != profile.model ||
          previous.apiKey != profile.apiKey) {
        _available.remove(profile.id);
      }
    }
    _write(next);
    if (tested != null) _available[profile.id] = tested;
  }

  void remove(String id) {
    _write(_profiles.where((value) => value.id != id).toList());
    _available.remove(id);
  }

  void setDefault(String id) {
    final profile = _profiles.where((value) => value.id == id).firstOrNull;
    if (profile == null || identical(profile, _profiles.firstOrNull)) return;
    _write([profile, ..._profiles.where((value) => value.id != id)]);
  }

  void _write(List<ModelProfile> next) {
    directory.createSync(recursive: true);
    final pending = File('${_file.path}.${newId()}.tmp');
    try {
      pending.createSync(exclusive: true);
      if (!Platform.isWindows) {
        final result = Process.runSync('/bin/chmod', ['600', pending.path]);
        if (result.exitCode != 0) {
          throw FileSystemException('无法限制模型密钥文件权限', pending.path);
        }
      }
      pending.writeAsStringSync(jsonEncode(next), flush: true);
      pending.renameSync(_file.path);
    } finally {
      if (pending.existsSync()) pending.deleteSync();
    }
    _profiles = next;
    loadError = null;
  }

  bool? availability(String id) => _available[id];

  List<Map<String, Object>> publishedModels() => [
    for (final profile in _profiles)
      {
        'id': profile.id,
        'name': profile.name,
        'kind': profile.kind,
        if (_available[profile.id] case final bool available)
          'available': available,
      },
  ];

  Future<void> test(ModelProfile profile) async {
    final client = _client();
    try {
      await for (final chunk in _completion(client, profile, [
        {'role': 'user', 'content': 'Reply with OK.'},
      ])) {
        if (!chunk.thinking) break;
      }
    } finally {
      client.close(force: true);
    }
  }

  void stop() {
    for (final client in _active.values) {
      _cancelled.add(client);
      client.close(force: true);
    }
    _active.clear();
  }

  void cancelRequest(String? id) {
    final client = _active[id];
    if (client == null) return;
    _cancelled.add(client);
    client.close(force: true);
  }

  Future<void> chat(HttpRequest request) async {
    final response = request.response;
    final bytes = BytesBuilder(copy: false);
    Object? payload;
    try {
      await for (final chunk in request.timeout(const Duration(seconds: 8))) {
        if (bytes.length + chunk.length > _maxBody) {
          return _reject(response, HttpStatus.requestEntityTooLarge, '消息过长。');
        }
        bytes.add(chunk);
      }
      payload = jsonDecode(utf8.decode(bytes.takeBytes()));
    } on FormatException {
      return _reject(response, HttpStatus.badRequest, '消息格式无效。');
    } on TimeoutException {
      return _reject(response, HttpStatus.requestTimeout, '读取消息超时。');
    }
    final model = payload is Map ? payload['model'] : null;
    final messages = payload is Map ? _messages(payload['messages']) : null;
    final rawId = payload is Map ? payload['requestId'] : null;
    if (model is! String ||
        messages == null ||
        (rawId != null && (rawId is! String || !_requestId.hasMatch(rawId)))) {
      return _reject(response, HttpStatus.badRequest, '消息格式无效。');
    }
    final profile = _profiles.where((value) => value.id == model).firstOrNull;
    if (profile == null) {
      return _reject(response, HttpStatus.notFound, '该模型连接已移除。');
    }
    final id = rawId as String? ?? newId();
    if (_active.containsKey(id)) {
      return _reject(response, HttpStatus.conflict, '请求已在运行。');
    }
    if (_active.length >= 4) {
      return _reject(response, HttpStatus.serviceUnavailable, '桌面端正在处理其他请求。');
    }

    final client = _client();
    _active[id] = client;
    response.headers.contentType = ContentType(
      'application',
      'x-ndjson',
      charset: 'utf-8',
    );
    response.headers.set('X-Accel-Buffering', 'no');
    response.bufferOutput = false;
    void downstreamClosed() {
      if (identical(_active[id], client)) cancelRequest(id);
    }

    unawaited(
      response.done.then<void>(
        (_) => downstreamClosed(),
        onError: (Object _, StackTrace _) => downstreamClosed(),
      ),
    );
    try {
      final includeReasoning =
          payload is Map && payload['includeReasoning'] == true;
      await for (final chunk in _completion(client, profile, messages)) {
        if (chunk.thinking && !includeReasoning) continue;
        final field = chunk.thinking ? 'reasoning' : 'text';
        response.writeln(jsonEncode({field: chunk.text}));
        await response.flush();
      }
      if (!_cancelled.contains(client)) {
        _available[profile.id] = true;
        response.writeln(jsonEncode({'done': true}));
      }
    } on ModelFailure catch (error) {
      if (!_cancelled.contains(client)) {
        _available[profile.id] = false;
        response.writeln(jsonEncode({'error': error.message}));
      }
    } finally {
      _cancelled.remove(client);
      if (identical(_active[id], client)) _active.remove(id);
      client.close(force: true);
    }
  }

  void _reject(HttpResponse response, int code, String text) {
    response.statusCode = code;
    response.write(jsonEncode({'error': text}));
  }

  List<Map<String, String>>? _messages(Object? value) {
    if (value is! List || value.isEmpty || value.length > 40) return null;
    final messages = <Map<String, String>>[];
    for (final item in value) {
      final role = item is Map ? item['role'] : null;
      final text = item is Map ? item['content'] : null;
      if (role is! String ||
          (role != 'user' && role != 'assistant') ||
          text is! String ||
          text.trim().isEmpty ||
          text.length > 16000) {
        return null;
      }
      messages.add({'role': role, 'content': text});
    }
    return messages.last['role'] == 'user' ? messages : null;
  }

  HttpClient _client() =>
      HttpClient()..connectionTimeout = const Duration(seconds: 8);

  Stream<({String text, bool thinking})> _completion(
    HttpClient client,
    ModelProfile profile,
    List<Map<String, String>> messages,
  ) async* {
    try {
      final request = await client.postUrl(profile.endpoint).timeout(_timeout);
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      if (profile.apiKey.isNotEmpty) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${profile.apiKey}',
        );
      }
      request.write(
        jsonEncode({
          'model': profile.model,
          'messages': messages,
          'stream': true,
        }),
      );
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw ModelFailure(switch (response.statusCode) {
          401 || 403 => '模型服务拒绝访问，请检查密钥。',
          404 => '找不到模型或接口，请检查地址和模型 ID。',
          429 => '模型服务繁忙或已达到限额。',
          _ => '模型服务未接受请求（HTTP ${response.statusCode}）。',
        });
      }
      var size = 0;
      var receivedText = false;
      var finished = false;
      final lines = response
          .timeout(_timeout)
          .map((chunk) {
            size += chunk.length;
            if (size > 2 * 1024 * 1024) {
              throw const ModelFailure('模型回复超过大小限制。');
            }
            return chunk;
          })
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in lines) {
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data == '[DONE]') {
          finished = true;
          break;
        }
        if (data.isEmpty) continue;
        final value = jsonDecode(data);
        if (value is Map && value['error'] != null) {
          throw const ModelFailure('模型服务返回错误。');
        }
        final choices = value is Map ? value['choices'] : null;
        final choice = choices is List ? choices.firstOrNull : null;
        if (choice is! Map) continue;
        finished = finished || choice['finish_reason'] != null;
        final delta = choice['delta'];
        final text = delta is Map ? delta['content'] : null;
        final reasoning = delta is Map
            ? delta['reasoning_content'] ?? delta['reasoning']
            : null;
        if (reasoning is String && reasoning.isNotEmpty) {
          yield (text: reasoning, thinking: true);
        }
        if (text is String && text.isNotEmpty) {
          receivedText = true;
          yield (text: text, thinking: false);
        }
      }
      if (!receivedText) throw const ModelFailure('模型未返回可显示的文字。');
      if (!finished) throw const ModelFailure('模型连接在回复完成前中断。');
    } on TimeoutException {
      throw const ModelFailure('等待模型回复超时。');
    } on IOException {
      throw const ModelFailure('无法连接模型服务。');
    } on StateError {
      throw const ModelFailure('模型连接已关闭。');
    } on FormatException {
      throw const ModelFailure('模型返回了无法读取的数据。');
    }
  }
}

class ModelFailure implements Exception {
  const ModelFailure(this.message);

  final String message;
}
