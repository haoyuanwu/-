import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rear_eyes_desktop/model_connections.dart';

void main() {
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
        'name': 'Ollama',
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
