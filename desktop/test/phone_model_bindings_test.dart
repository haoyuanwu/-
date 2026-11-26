import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rear_eyes_desktop/model_connections.dart';
import 'package:rear_eyes_desktop/phone_model_bindings.dart';

void main() {
  test(
    'paired apps get the cloud catalog without changing their selection',
    () async {
      final directory = await Directory.systemTemp.createTemp('cloud-catalog-');
      addTearDown(() => directory.delete(recursive: true));
      final models = ModelConnections(directory);
      final bindings = PhoneModelBindings(directory, models);
      final device = ModelConnections.newId();
      ModelProfile cloud(String model) => ModelProfile(
        id: ModelConnections.newId(),
        name: model,
        address: 'https://cloud.example/v1',
        model: model,
        apiKey: 'test-key',
        kind: 'cloud',
        modelIds: [model, '$model-alternative'],
      );
      final one = cloud('one');
      final two = cloud('two');
      models.save(one);
      models.save(two);
      models.save(
        ModelProfile(
          id: ModelConnections.newId(),
          name: 'Local GGUF',
          address: '',
          model: 'local',
          apiKey: '',
          kind: 'local',
          localPath: 'private-model.gguf',
        ),
      );
      final report = {
        'device': device,
        'source': 'local',
        'model': '',
        'conflictSupport': '1',
      };
      final initial = bindings.exchange({...report, 'cloudCatalog': ''});
      expect(initial, isNot(contains('selection')));
      expect((initial['options'] as List).map((value) => value['id']), [
        one.id,
        two.id,
      ]);
      expect((initial['options'] as List).last['modelIds'], two.modelIds);
      expect(initial.toString(), isNot(contains('private-model.gguf')));

      final received = {...report, 'cloudCatalog': initial['catalogRevision']};
      expect(bindings.exchange(received), isNot(contains('options')));
      bindings.refreshCatalog(device);
      expect(bindings.catalogPending(bindings.phones.single), isTrue);
      final refreshed = bindings.exchange(received);
      expect(refreshed['options'], initial['options']);
      expect(refreshed, isNot(contains('selection')));

      final switched = bindings.exchange({
        ...received,
        'cloudCatalog': refreshed['catalogRevision'],
        'source': 'cloud',
        'model': two.model,
        'url': two.endpoint.toString(),
        'key': two.apiKey,
        'edit': ModelConnections.newId(),
      });
      expect(switched, isNot(contains('conflict')));
      expect(switched['selection'], containsPair('model', two.model));
      expect(bindings.phones.single.target, two.id);
      expect(bindings.catalogPending(bindings.phones.single), isFalse);
      expect(models.profiles.where((p) => p.kind == 'cloud'), [one, two]);
    },
  );

  for (final action in CloudResolution.values) {
    test(
      'reconnection keeps both changes until deciding ${action.name}',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'cloud-conflict-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final models = ModelConnections(directory);
        final device = ModelConnections.newId();
        final cloudId = ModelConnections.newId();
        ModelProfile desktop(String model) => ModelProfile(
          id: cloudId,
          name: '电脑云端',
          address: 'https://desktop.example/v1',
          model: model,
          apiKey: 'desktop-key',
          kind: 'cloud',
        );
        final bindings = PhoneModelBindings(directory, models);
        models.save(desktop('original'));
        final report = {
          'device': device,
          'source': 'desktop',
          'model': '',
          'conflictSupport': '1',
        };
        bindings.exchange(report);
        bindings.select(device, cloudId);
        final before = bindings.exchange(report);
        models.save(desktop('desktop-edited'));
        final offline = {
          ...report,
          'source': 'cloud',
          'model': 'phone-edited',
          'url': 'https://phone.example/v1/chat/completions',
          'key': 'phone-key',
          'seen': before['revision'],
          'edit': ModelConnections.newId(),
          'compare': ModelConnections.newId(),
        };
        final paused = bindings.exchange(offline);
        expect(paused, contains('conflict'));
        expect(paused, isNot(contains('selection')));
        expect(paused.toString(), isNot(contains('phone-key')));
        expect(paused.toString(), isNot(contains('desktop-key')));
        expect(models.profiles.single.model, 'desktop-edited');

        // A restarted desktop can reconstruct the pending choice from the phone's retry.
        final restarted = PhoneModelBindings(directory, models);
        restarted.exchange(offline);
        restarted.resolve(device, restarted.conflictFor(device)!, action);
        final received = restarted.exchange(offline);
        final merge =
            action == CloudResolution.mergeDesktop ||
            action == CloudResolution.mergePhone;
        final usesPhone =
            action == CloudResolution.phone ||
            action == CloudResolution.mergePhone;
        expect(
          received['selection'],
          containsPair('model', usesPhone ? 'phone-edited' : 'desktop-edited'),
        );
        expect(received, isNot(contains('conflict')));
        expect(models.profiles, hasLength(merge ? 2 : 1));
        if (merge) {
          final options = received['options'] as List;
          expect(
            options.map((entry) => entry['model']),
            containsAll(['desktop-edited', 'phone-edited']),
          );
        }
        // Resending the same offline report cannot re-open or re-apply a resolved decision.
        expect(restarted.exchange(offline), received);
      },
    );
  }

  test(
    'a phone can compare an unchanged cloud profile after reconnecting',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cloud-reconnect-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final models = ModelConnections(directory);
      final device = ModelConnections.newId();
      final id = ModelConnections.newId();
      ModelProfile desktop(String model) => ModelProfile(
        id: id,
        name: '云端',
        address: 'https://desktop.example/v1',
        model: model,
        apiKey: 'test-key',
        kind: 'cloud',
      );
      models.save(desktop('before'));
      final bound = PhoneModelBindings(directory, models);
      final report = {
        'device': device,
        'source': 'desktop',
        'model': '',
        'conflictSupport': '1',
      };
      bound.exchange(report);
      bound.select(device, id);
      final revision = bound.exchange(report)['revision'];
      models.save(desktop('after'));
      final restarted = PhoneModelBindings(directory, models);
      final returning = {
        ...report,
        'source': 'cloud',
        'model': 'before',
        'seen': revision,
      };
      expect(restarted.exchange(returning)['compareRequired'], isTrue);
      final comparison = {
        ...returning,
        'compare': ModelConnections.newId(),
        'url': 'https://desktop.example/v1/chat/completions',
        'key': 'test-key',
      };
      expect(restarted.exchange(comparison), contains('conflict'));
      restarted.resolve(
        device,
        restarted.conflictFor(device)!,
        CloudResolution.desktop,
      );
      expect(
        restarted.exchange(comparison)['selection'],
        containsPair('model', 'after'),
      );
    },
  );

  test('paired phones only receive their selected cloud model', () async {
    final directory = await Directory.systemTemp.createTemp('phone-models-');
    addTearDown(() => directory.delete(recursive: true));
    final models = ModelConnections(directory);
    final bindings = PhoneModelBindings(directory, models);
    final first = ModelConnections.newId();
    final second = ModelConnections.newId();
    final cloudId = ModelConnections.newId();
    ModelProfile cloud(String model, String key) => ModelProfile(
      id: cloudId,
      name: '测试云端',
      address: 'https://cloud.example/v1',
      model: model,
      apiKey: key,
      kind: 'cloud',
      modelIds: const ['cloud-one', 'cloud-alt'],
    );
    Map<String, Object?> report(String id, {String? seen, String? model}) =>
        bindings.exchange({
          'device': id,
          'source': model == null ? 'desktop' : 'cloud',
          'model': model ?? '',
          'seen': seen,
        });
    models.save(cloud('cloud-one', 'example-key-one'));
    report(first);
    report(second);
    bindings.select(first, cloudId);
    final sync = report(first);
    expect(sync['selection'], containsPair('key', 'example-key-one'));
    expect(report(second), isNot(contains('selection')));
    expect(bindings.pending(bindings.phones.first), isTrue);

    final acknowledged = report(
      first,
      seen: sync['revision'] as String,
      model: 'cloud-one',
    );
    expect(acknowledged, isNot(contains('selection')));
    expect(bindings.pending(bindings.phones.first), isFalse);
    expect(bindings.phones.first.model, 'cloud-one');
    models.selectModelId(cloudId, 'cloud-alt');
    final selected = report(
      first,
      seen: sync['revision'] as String,
      model: 'cloud-one',
    );
    expect(selected['selection'], containsPair('model', 'cloud-alt'));

    final edited = {
      'device': first,
      'source': 'cloud',
      'model': 'cloud-two',
      'url': 'https://cloud.example/v1',
      'key': 'example-key-two',
      'seen': selected['revision'],
      'edit': ModelConnections.newId(),
    };
    final received = bindings.exchange(edited);
    expect(models.profiles.single.id, cloudId);
    expect(models.profiles.single.model, 'cloud-two');
    expect(models.profiles.single.apiKey, 'example-key-two');
    expect(bindings.exchange(edited), received);

    final reopenedModels = ModelConnections(directory);
    final reopened = PhoneModelBindings(directory, reopenedModels);
    final revision = received['revision'] as String;
    final restored = reopened.exchange({
      'device': first,
      'source': 'cloud',
      'model': 'cloud-two',
      'seen': revision,
    });
    expect(restored, {'revision': revision});
    reopenedModels.save(cloud('cloud-three', 'example-key-three'));
    final refreshed = reopened.exchange({
      'device': first,
      'source': 'cloud',
      'model': 'cloud-two',
      'seen': revision,
    });
    expect(refreshed['selection'], containsPair('model', 'cloud-three'));
    expect(refreshed['revision'], isNot(revision));
    reopenedModels.remove(cloudId);
    expect(
      reopened.exchange({
        'device': first,
        'source': 'cloud',
        'model': 'cloud-three',
        'seen': refreshed['revision'],
      })['selection'],
      {'source': 'desktop'},
    );
    final bindingFile = File('${directory.path}/phone-model-bindings.json');
    expect(bindingFile.readAsStringSync(), isNot(contains('example-key')));
    reopened.exchange({
      'device': second,
      'source': 'local',
      'model': 'private-phone-model',
      'edit': ModelConnections.newId(),
    });
    expect(reopened.phones.last.source, 'local');
    expect(reopened.phones.last.model, isEmpty);
    expect(
      bindingFile.readAsStringSync(),
      isNot(contains('private-phone-model')),
    );
  });
}
