import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:robot_eyes_models/robot_eyes_models.dart';

class ModelProfile {
  ModelProfile({
    required this.id,
    required String name,
    required String address,
    required String model,
    required String apiKey,
    required this.kind,
    String? revision,
    Iterable<String> modelIds = const [],
    this.localPath,
    this.projectorPath,
    Set<GgufMediaType> mediaTypes = const {},
  }) : name = name.trim(),
       endpoint = localPath == null
           ? _endpoint(address)
           : Uri(scheme: 'file', path: localPath),
       model = model.trim(),
       apiKey = _validatedApiKey(apiKey),
       modelIds = List.unmodifiable(modelIds.toSet()),
       mediaTypes = Set.unmodifiable(mediaTypes),
       revision = revision ?? ModelConnections.newId() {
    if (this.name.isEmpty || this.name.length > 80) {
      throw const FormatException('请输入 1 到 80 个字符的连接名称。');
    }
    if (this.model.isEmpty || this.model.length > 200) {
      throw const FormatException('请输入模型名称或 ID。');
    }
    if (kind != 'local' && kind != 'cloud') {
      throw const FormatException('连接类型无效。');
    }
    if (localPath != null && (kind != 'local' || localPath!.isEmpty)) {
      throw const FormatException('请选择本机 GGUF 模型文件。');
    }
    if (this.mediaTypes.isNotEmpty &&
        (localPath == null ||
            projectorPath?.isNotEmpty != true ||
            projectorPath == localPath)) {
      throw const FormatException('请选择主模型配套的 mmproj 文件。');
    }
  }

  final String id;
  final String name;
  final Uri endpoint;
  final String model;
  final String apiKey;
  final String kind;
  final String revision;
  final List<String> modelIds;
  final String? localPath;
  final String? projectorPath;
  final Set<GgufMediaType> mediaTypes;

  bool get isLocalService => kind == 'local' && localPath == null;

  String get displayName => isLocalService ? model : name;

  static String _validatedApiKey(String apiKey) {
    final key = apiKey.trim();
    if (key.length > 2048 || key.contains(RegExp(r'[^\x21-\x7e]'))) {
      throw const FormatException('访问密钥格式无效。');
    }
    return key;
  }

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
    final rawPath = uri.path.replaceFirst(RegExp(r'/+$'), '');
    final path = rawPath.isEmpty ? '/v1' : rawPath;
    return uri.replace(
      path: path.endsWith('/chat/completions')
          ? path
          : '$path/chat/completions',
    );
  }

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'url': endpoint.toString(),
    'model': model,
    'apiKey': apiKey,
    'kind': kind,
    'revision': revision,
    'localPath': ?localPath,
    if (mediaTypes.isNotEmpty) ...{
      'projectorPath': projectorPath!,
      'mediaTypes': [for (final type in mediaTypes) type.name],
    },
    if (localPath == null && modelIds.isNotEmpty) 'modelIds': modelIds,
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
      revision: value['revision'] is String
          ? value['revision'] as String
          : value['id'] as String,
      modelIds: value['modelIds'] is List && value['localPath'] == null
          ? (value['modelIds'] as List).whereType<String>()
          : const [],
      localPath: value['localPath'] is String
          ? value['localPath'] as String
          : null,
      projectorPath: value['projectorPath'] is String
          ? value['projectorPath'] as String
          : null,
      mediaTypes: value['mediaTypes'] is List
          ? {
              for (final type in GgufMediaType.values)
                if ((value['mediaTypes'] as List).contains(type.name)) type,
            }
          : const {},
    );
  }
}

class ModelConnections {
  ModelConnections(this.directory);

  final Directory directory;
  late List<ModelProfile> _profiles = _load();
  final _available = <String, bool>{};
  final _probes = <String, HttpClient>{};
  final _nextProbe = <String, DateTime>{};
  Timer? _monitor;
  void Function()? _onChanged;
  static const _probeTimeout = Duration(seconds: 4);
  static const _pollInterval = Duration(seconds: 5);
  final _active = <String, HttpClient>{};
  final _streams =
      <HttpClient, StreamIterator<({String text, bool thinking})>>{};
  final _cancelled = <HttpClient>{};
  String? loadError;
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
    final previous = index == -1 ? null : next[index];
    if (previous == null) {
      if (next.length >= 20) throw const FormatException('最多保存 20 个模型连接。');
      next.add(profile);
    } else {
      next[index] = profile;
    }
    _write(next);
    _resetProbe(profile.id);
    if (previous?.endpoint != profile.endpoint ||
        previous?.model != profile.model ||
        previous?.apiKey != profile.apiKey) {
      _available.remove(profile.id);
    }
    if (tested != null) _available[profile.id] = tested;
    _onChanged?.call();
    _poll();
  }

  void remove(String id) {
    _write(_profiles.where((value) => value.id != id).toList());
    _available.remove(id);
    _resetProbe(id);
    _onChanged?.call();
  }

  void setDefault(String id) {
    final profile = _profiles.where((value) => value.id == id).firstOrNull;
    if (profile == null || identical(profile, _profiles.firstOrNull)) return;
    _write([profile, ..._profiles.where((value) => value.id != id)]);
    _onChanged?.call();
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

  void selectModelId(String profileId, String model) {
    final profile = profiles.where((item) => item.id == profileId).firstOrNull;
    if (profile == null ||
        profile.localPath != null ||
        !profile.modelIds.contains(model)) {
      throw const FormatException('模型列表已变化，请重新选择。');
    }
    if (profile.model == model) return;
    save(
      ModelProfile(
        id: profile.id,
        name: profile.name,
        address: profile.endpoint.toString(),
        model: model,
        apiKey: profile.apiKey,
        kind: profile.kind,
        modelIds: profile.modelIds,
      ),
    );
  }

  Future<List<String>> fetchModelIds({
    required String address,
    required String apiKey,
    required bool cloud,
    bool allowEmpty = false,
  }) async {
    final endpoint = ModelProfile._endpoint(address);
    if (cloud && endpoint.scheme != 'https') {
      throw const FormatException('云端模型需要 HTTPS 地址。');
    }
    final key = ModelProfile._validatedApiKey(apiKey);
    final client = _client();
    try {
      final (status, ids) = await _readCatalog(
        _modelsEndpoint(endpoint),
        client,
        key,
      ).timeout(const Duration(seconds: 12));
      if (status != HttpStatus.ok) {
        throw ModelFailure(switch (status) {
          401 || 403 => '无法读取模型列表，请检查密钥和权限。',
          404 || 405 => '该服务未提供模型列表，请手动填写模型 ID。',
          _ => '获取模型列表失败（HTTP $status）。',
        });
      }
      if (ids == null) throw const ModelFailure('模型列表格式无效或响应过大。');
      if (ids.isEmpty && !allowEmpty) {
        throw const ModelFailure('服务未返回可用的模型 ID。');
      }
      return ids.toList()..sort();
    } on TimeoutException {
      throw const ModelFailure('获取模型列表超时，请重试。');
    } on IOException {
      throw ModelFailure(
        cloud ? '无法连接云端服务，请检查接口地址和网络。' : '无法连接本地模型服务，请检查服务是否已启动和地址是否正确。',
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> syncLocalServiceModels(ModelProfile profile) async {
    if (!profile.isLocalService) return false;
    final ids = await fetchModelIds(
      address: profile.endpoint.toString(),
      apiKey: profile.apiKey,
      cloud: false,
      allowEmpty: true,
    );
    if (!_profiles.any((current) => identical(current, profile))) return false;
    final catalogModel = _catalogModel(profile, ids);
    final model = catalogModel ?? profile.model;
    final available = catalogModel != null;
    if (model == profile.model &&
        ids.length == profile.modelIds.length &&
        ids.every(profile.modelIds.contains)) {
      _setAvailability(profile.id, available);
    } else {
      save(
        ModelProfile(
          id: profile.id,
          name: profile.name,
          address: profile.endpoint.toString(),
          model: model,
          apiKey: profile.apiKey,
          kind: profile.kind,
          modelIds: ids,
        ),
        tested: available,
      );
    }
    return true;
  }

  String? _catalogModel(ModelProfile profile, Iterable<String> ids) {
    if (ids.contains(profile.model)) return profile.model;
    // Ollama can accept a bare name while its catalog lists the :latest tag.
    final tagged = '${profile.model}:latest';
    return profile.isLocalService && ids.contains(tagged) ? tagged : null;
  }

  Future<String?> readLocalModelParameters({
    required String address,
    required String model,
    required String apiKey,
  }) async {
    final endpoint = ModelProfile._endpoint(address);
    final modelId = model.trim();
    if (modelId.isEmpty || modelId.length > 200) {
      throw const FormatException('请选择或填写模型 ID。');
    }
    final key = ModelProfile._validatedApiKey(apiKey);
    final uri = endpoint.replace(
      path: endpoint.path.replaceFirst(
        RegExp(r'(?:/v1)?/chat/completions$'),
        '/api/show',
      ),
    );
    final client = _client();
    try {
      return await (() async {
        final request = await client.postUrl(uri);
        request.followRedirects = false;
        request.headers.contentType = ContentType.json;
        if (key.isNotEmpty) {
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
        }
        request.write(jsonEncode({'model': modelId}));
        final response = await request.close();
        if (const {404, 405, 501}.contains(response.statusCode)) return null;
        if (response.statusCode != HttpStatus.ok) {
          throw ModelFailure('无法读取模型参数（HTTP ${response.statusCode}）。');
        }
        final data = await _readJsonObject(response);
        if (data == null) throw const ModelFailure('无法读取模型参数响应。');
        return switch (data['parameters']) {
          final String parameters => parameters.trim(),
          null => data.containsKey('details') ? '' : null,
          _ => throw const ModelFailure('模型参数格式无效。'),
        };
      })().timeout(const Duration(seconds: 12));
    } on TimeoutException {
      throw const ModelFailure('读取模型参数超时。');
    } on IOException {
      throw const ModelFailure('无法连接本地服务读取模型参数。');
    } finally {
      client.close(force: true);
    }
  }

  void refreshAvailability() {
    _nextProbe.clear();
    _poll();
  }

  List<Map<String, Object>> publishedModels() => [
    for (final profile in _profiles)
      {
        'id': profile.id,
        'name': profile.displayName,
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

  void startMonitoring(void Function() onChanged) {
    if (_monitor != null) return;
    _onChanged = onChanged;
    _monitor = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
    _poll();
  }

  void _resetProbe(String id) {
    _probes.remove(id)?.close(force: true);
    _nextProbe.remove(id);
  }

  void _poll() {
    if (_monitor == null) return;
    final now = DateTime.now();
    for (final profile in _profiles) {
      final next = _nextProbe[profile.id];
      if (_probes.containsKey(profile.id) ||
          (next != null && now.isBefore(next))) {
        continue;
      }
      _nextProbe[profile.id] = now.add(
        profile.kind == 'local' ? _pollInterval : const Duration(seconds: 30),
      );
      final client = HttpClient()..connectionTimeout = _probeTimeout;
      _probes[profile.id] = client;
      unawaited(_probe(profile, client));
    }
  }

  Future<void> _probe(ModelProfile profile, HttpClient client) async {
    bool? available;
    try {
      available = await _checkConnection(
        profile,
        client,
      ).timeout(_probeTimeout);
    } on IOException {
      available = false;
    } on TimeoutException {
      available = false;
    } finally {
      client.close(force: true);
    }
    if (!identical(_probes[profile.id], client)) return;
    _probes.remove(profile.id);
    if (available != null) _setAvailability(profile.id, available);
  }

  Future<bool?> _checkConnection(
    ModelProfile profile,
    HttpClient client,
  ) async {
    if (profile.localPath case final path?) {
      try {
        await checkGgufFile(path);
        return true;
      } on FormatException {
        return false;
      }
    }
    final endpoint = _modelsEndpoint(profile.endpoint);
    final (status, ids) = await _readCatalog(endpoint, client, profile.apiKey);
    // Some compatible gateways expose completions without a model catalog.
    if (const {404, 405, 429, 501}.contains(status)) return null;
    if (status != HttpStatus.ok) return false;
    return ids == null ? null : _catalogModel(profile, ids) != null;
  }

  Uri _modelsEndpoint(Uri endpoint) => endpoint.replace(
    path: endpoint.path.replaceFirst(RegExp(r'/chat/completions$'), '/models'),
  );

  Future<(int, Set<String>?)> _readCatalog(
    Uri endpoint,
    HttpClient client, [
    String apiKey = '',
  ]) async {
    final request = await client.getUrl(endpoint);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (apiKey.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    }
    final response = await request.close();
    final status = response.statusCode;
    if (status != HttpStatus.ok) return (status, null);
    final data = (await _readJsonObject(response))?['data'];
    if (data is! List) return (status, null);
    return (
      status,
      {
        for (final entry in data)
          if (entry case {'id': final String id}
              when id.isNotEmpty && id == id.trim() && id.length <= 200)
            id,
      },
    );
  }

  Future<Map<String, Object?>?> _readJsonObject(
    HttpClientResponse response,
  ) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      if (bytes.length + chunk.length > 1024 * 1024) return null;
      bytes.add(chunk);
    }
    try {
      final json = jsonDecode(utf8.decode(bytes.takeBytes()));
      return json is Map<String, Object?> ? json : null;
    } on FormatException {
      return null;
    }
  }

  void _setAvailability(String id, bool available) {
    if (_available[id] == available) return;
    _available[id] = available;
    _onChanged?.call();
  }

  void _recordChatResult(ModelProfile profile, bool available) {
    if (!_profiles.any((current) => identical(current, profile))) return;
    _probes.remove(profile.id)?.close(force: true);
    _setAvailability(profile.id, available);
  }

  void stop() {
    _monitor?.cancel();
    _monitor = null;
    _onChanged = null;
    for (final client in _probes.values) {
      client.close(force: true);
    }
    _probes.clear();
    _nextProbe.clear();
    _available.clear();
    for (final client in _active.values) {
      _cancelled.add(client);
      unawaited(_streams[client]?.cancel());
      client.close(force: true);
    }
    _active.clear();
  }

  void cancelRequest(String? id) {
    final client = _active[id];
    if (client == null) return;
    _cancelled.add(client);
    unawaited(_streams[client]?.cancel());
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
      final stream = StreamIterator(_completion(client, profile, messages));
      _streams[client] = stream;
      while (await stream.moveNext()) {
        final chunk = stream.current;
        if (chunk.thinking && !includeReasoning) continue;
        final field = chunk.thinking ? 'reasoning' : 'text';
        response.writeln(jsonEncode({field: chunk.text}));
        await response.flush();
      }
      if (!_cancelled.contains(client)) {
        _recordChatResult(profile, true);
        response.writeln(jsonEncode({'done': true}));
      }
    } on ModelFailure catch (error) {
      if (!_cancelled.contains(client)) {
        _recordChatResult(profile, false);
        response.writeln(jsonEncode({'error': error.message}));
      }
    } finally {
      await _streams.remove(client)?.cancel();
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
      if (profile.localPath case final path?) {
        try {
          await for (final text in ggufChat(path, messages)) {
            yield (text: text, thinking: false);
          }
        } on FormatException catch (failure) {
          throw ModelFailure(failure.message);
        }
        return;
      }
      final request = await client.postUrl(profile.endpoint).timeout(const Duration(seconds: 8));
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
      final response = await request.close().timeout(modelResponseTimeout);
      if (response.statusCode != HttpStatus.ok) {
        throw ModelFailure(switch (response.statusCode) {
          401 || 403 => '模型服务拒绝访问，请检查密钥。',
          404 => '找不到模型或接口，请检查地址和模型 ID。',
          429 => '模型服务繁忙或已达到限额。',
          _ => '模型服务未接受请求（HTTP ${response.statusCode}）。',
        });
      }
      var size = 0;
      final lines = response
          .timeout(modelResponseTimeout)
          .map((chunk) {
            size += chunk.length;
            if (size > 2 * 1024 * 1024) {
              throw const ModelFailure('模型回复超过大小限制。');
            }
            return chunk;
          })
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final chunk in readChatCompletion(lines)) {
        yield chunk;
      }
    } on ChatCompletionFailure catch (error) {
      throw ModelFailure(error.message);
    } on TimeoutException {
      throw const ModelFailure('模型服务连续 120 秒未返回数据，已停止等待。');
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
