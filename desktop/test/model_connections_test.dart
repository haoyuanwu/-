import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rear_eyes_desktop/model_connections.dart';

class _CatalogTransport extends Fake implements HttpClient {
  _CatalogTransport(this.client, this.port, this.requested);

  final HttpClient client;
  final int port;
  final List<Uri> requested;

  @override
  set connectionTimeout(Duration? value) => client.connectionTimeout = value;

  @override
  Future<HttpClientRequest> getUrl(Uri url) {
    requested.add(url);
    return client.getUrl(
      url.replace(scheme: 'http', host: '127.0.0.1', port: port),
    );
  }

  @override
  void close({bool force = false}) => client.close(force: force);
}

class _CatalogOverrides extends HttpOverrides {
  _CatalogOverrides(this.port, this.requested);

  final int port;
  final List<Uri> requested;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _CatalogTransport(super.createHttpClient(context), port, requested);
}

void main() {
  test('desktop relay normalizes reasoning and compatible reply formats', () async {
    final directory = await Directory.systemTemp.createTemp('model-stream-');
    addTearDown(() => directory.delete(recursive: true));
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => upstream.close(force: true));
    var scenario = 0;
    upstream.listen((request) async {
      await request.drain<void>();
      final reply = request.response;
      if (scenario == 1) {
        reply.headers.contentType = ContentType.json;
        reply.write('{"choices":[{"message":{"content":"完整 JSON 正文"},'
            '"finish_reason":"stop"}]}');
      } else {
        reply.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
        reply.writeln('data: {"choices":[{"delta":{"reasoning_content":"先检查"}}]}');
        reply.writeln('data: {"choices":[{"delta":{"reasoning_content":"先检查，再回答"}}]}');
        if (scenario == 2) {
          reply.writeln('data: {"choices":[{"delta":{},"finish_reason":"length"}]}');
        } else {
          reply.writeln('data: {"choices":[{"delta":{"content":'
              '[{"type":"text","text":"<think>先检查，再回答</think>正式正文"}]}}]}');
        }
        reply.writeln('data: [DONE]');
      }
      await reply.close();
    });

    final models = ModelConnections(directory);
    addTearDown(models.stop);
    models.save(ModelProfile(
      id: 'fixture',
      name: 'Fixture',
      address: 'http://127.0.0.1:${upstream.port}/v1',
      model: 'fixture',
      apiKey: '',
      kind: 'local',
    ));
    final relay = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => relay.close(force: true));
    relay.listen((request) async {
      await models.chat(request);
      await request.response.close();
    });
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    Future<List<dynamic>> request() async {
      final req = await client.post('127.0.0.1', relay.port, '/ai/chat');
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'model': 'fixture',
        'includeReasoning': true,
        'messages': [{'role': 'user', 'content': '测试'}],
      }));
      return (await req.close())
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .map(jsonDecode)
          .toList();
    }

    expect(await request(), [
      {'reasoning': '先检查'},
      {'reasoning': '，再回答'},
      {'text': '正式正文'},
      {'done': true},
    ]);
    scenario = 1;
    expect(await request(), [
      {'text': '完整 JSON 正文'},
      {'done': true},
    ]);
    scenario = 2;
    expect((await request()).last, containsPair('error', contains('输出长度上限')));
  });

  test(
    'local service discovers and remembers Ollama-compatible model IDs',
    () async {
      final directory = await Directory.systemTemp.createTemp('local-catalog-');
      addTearDown(() => directory.delete(recursive: true));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      String? requestedPath;
      var catalog = ['qwen:4b', 'llama:8b'];
      server.listen((request) async {
        requestedPath = request.uri.path;
        if (requestedPath == '/api/show') {
          final requestBody = jsonDecode(
            await utf8.decoder.bind(request).join(),
          );
          if (request.method != 'POST' || requestBody['model'] != 'qwen:4b') {
            request.response.statusCode = HttpStatus.badRequest;
          } else {
            request.response.write(
              jsonEncode({'parameters': 'temperature 0.6\nnum_ctx 4096'}),
            );
          }
        } else {
          request.response.write(
            jsonEncode({
              'data': [
                for (final id in catalog) {'id': id},
              ],
            }),
          );
        }
        await request.response.close();
      });
      final address = 'http://127.0.0.1:${server.port}';
      final connections = ModelConnections(directory);
      final ids = await connections.fetchModelIds(
        address: address,
        apiKey: '',
        cloud: false,
      );
      expect(requestedPath, '/v1/models');
      expect(ids, ['llama:8b', 'qwen:4b']);
      expect(
        await connections.readLocalModelParameters(
          address: address,
          model: 'qwen:4b',
          apiKey: '',
        ),
        'temperature 0.6\nnum_ctx 4096',
      );
      connections.save(
        ModelProfile(
          id: 'local-service',
          kind: 'local',
          name: 'Ollama',
          address: address,
          model: 'qwen',
          apiKey: '',
          modelIds: ids,
        ),
      );
      final reopened = ModelConnections(directory);
      expect(reopened.profiles.single.localPath, isNull);
      expect(reopened.profiles.single.endpoint.path, '/v1/chat/completions');
      expect(reopened.profiles.single.modelIds, ids);
      catalog = ['qwen:latest', 'llama:8b'];
      expect(
        await reopened.syncLocalServiceModels(reopened.profiles.single),
        isTrue,
      );
      expect(reopened.profiles.single.model, 'qwen:latest');
      expect(reopened.profiles.single.name, 'Ollama');
      expect(reopened.publishedModels().single['name'], 'qwen:latest');
      catalog = ['replacement:8b'];
      expect(
        await reopened.syncLocalServiceModels(reopened.profiles.single),
        isTrue,
      );
      expect(reopened.profiles.single.modelIds, ['replacement:8b']);
      expect(reopened.profiles.single.model, 'qwen:latest');
      expect(reopened.availability('local-service'), isFalse);
      reopened.selectModelId('local-service', 'replacement:8b');
      expect(reopened.profiles.single.model, 'replacement:8b');
      final updated = ModelConnections(directory).profiles.single;
      expect(updated.modelIds, ['replacement:8b']);
    },
  );

  test(
    'cloud model discovery keeps choices and switches the saved connection',
    () async {
      final directory = await Directory.systemTemp.createTemp('cloud-catalog-');
      addTearDown(() => directory.delete(recursive: true));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      String? authorization;
      var status = HttpStatus.ok;
      server.listen((request) async {
        authorization = request.headers.value(HttpHeaders.authorizationHeader);
        request.response.statusCode = status;
        request.response.write(
          '{"data":[{"id":"beta"},{"id":"alpha"},{"id":"beta"},{"id":""}]}',
        );
        await request.response.close();
      });
      final requests = <Uri>[];
      final models = ModelConnections(directory);
      await HttpOverrides.runWithHttpOverrides(() async {
        final ids = await models.fetchModelIds(
          cloud: true,
          address: 'https://cloud.example',
          apiKey: 'test-key',
        );
        expect(requests.single, Uri.parse('https://cloud.example/v1/models'));
        expect(authorization, 'Bearer test-key');
        expect(ids, ['alpha', 'beta']);
        models.save(
          ModelProfile(
            id: 'cloud',
            name: '测试云端',
            address: 'https://cloud.example',
            model: 'alpha',
            apiKey: 'test-key',
            kind: 'cloud',
            modelIds: ids,
          ),
        );
        final resumed = ModelConnections(directory);
        final original = resumed.profiles.single;
        resumed.selectModelId('cloud', 'beta');
        final selected = resumed.profiles.single;
        expect(selected.model, 'beta');
        expect(selected.modelIds, ['alpha', 'beta']);
        expect(selected.apiKey, original.apiKey);
        expect(selected.revision, isNot(original.revision));
        expect(resumed.publishedModels().single, isNot(contains('modelIds')));

        status = HttpStatus.unauthorized;
        await expectLater(
          models.fetchModelIds(
            cloud: true,
            address: 'https://cloud.example/v1/chat/completions',
            apiKey: 'invalid',
          ),
          throwsA(
            isA<ModelFailure>().having(
              (failure) => failure.message,
              'message',
              contains('密钥'),
            ),
          ),
        );
        expect(requests.last, requests.first);
      }, _CatalogOverrides(server.port, requests));
    },
  );

  test(
    'model catalog probe publishes connection changes without chatting',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'robot-eyes-model-test',
      );
      addTearDown(() => directory.delete(recursive: true));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var status = HttpStatus.ok;
      var catalogModel = 'test';
      final requests = <(String, String)>[];
      server.listen((request) async {
        requests.add((request.method, request.uri.path));
        request.response.statusCode = status;
        request.response.write('{"data": [{"id": "$catalogModel"}]}');
        await request.response.close();
      });
      final models = ModelConnections(directory);
      addTearDown(models.stop);
      models.save(
        ModelProfile(
          id: 'local',
          name: 'Ollama',
          address: 'http://127.0.0.1:${server.port}/v1',
          model: 'test',
          apiKey: 'local-test-key',
          kind: 'local',
        ),
      );

      var change = Completer<void>();
      models.startMonitoring(() {
        if (!change.isCompleted) change.complete();
      });
      await change.future.timeout(const Duration(seconds: 4));
      expect(models.publishedModels().single, {
        'id': 'local',
        'name': 'test',
        'kind': 'local',
        'available': true,
      });

      change = Completer<void>();
      status = HttpStatus.serviceUnavailable;
      await change.future.timeout(const Duration(seconds: 8));
      expect(models.availability('local'), isFalse);

      change = Completer<void>();
      status = HttpStatus.ok;
      await change.future.timeout(const Duration(seconds: 8));
      expect(models.availability('local'), isTrue);

      change = Completer<void>();
      catalogModel = 'another-model';
      models.refreshAvailability();
      await change.future.timeout(const Duration(seconds: 4));
      expect(models.availability('local'), isFalse);
      expect(requests, everyElement(('GET', '/v1/models')));

      models.remove('local');
      expect(models.publishedModels(), isEmpty);
    },
  );
}
