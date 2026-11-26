import 'dart:convert';
import 'dart:io';

import 'model_connections.dart';

class PhoneModelBinding {
  const PhoneModelBinding({
    required this.id,
    required this.source,
    required this.model,
    this.target,
    this.revision,
    this.acknowledged,
    this.lastEdit,
    this.shared = const [],
    this.catalogGeneration,
    this.catalogAcknowledged,
  });

  final String id;
  final String source;
  final String model;
  // Empty selects the desktop default. Null leaves the phone's selection alone.
  final String? target;
  final String? revision;
  final String? acknowledged;
  final String? lastEdit;
  final List<String> shared;
  final String? catalogGeneration;
  final String? catalogAcknowledged;

  Map<String, Object> toJson() => {
    'id': id,
    'source': source,
    'model': model,
    'target': ?target,
    'revision': ?revision,
    'acknowledged': ?acknowledged,
    'lastEdit': ?lastEdit,
    if (shared.isNotEmpty) 'shared': shared,
    'catalogGeneration': ?catalogGeneration,
    'catalogAcknowledged': ?catalogAcknowledged,
  };

  static PhoneModelBinding read(Map value) => PhoneModelBinding(
    id: value['id'] as String,
    source: value['source'] as String,
    model: value['model'] as String,
    target: value['target'] as String?,
    revision: value['revision'] as String?,
    acknowledged: value['acknowledged'] as String?,
    lastEdit: value['lastEdit'] as String?,
    catalogGeneration: value['catalogGeneration'] as String?,
    catalogAcknowledged: value['catalogAcknowledged'] as String?,
    shared: value['shared'] is List
        ? (value['shared'] as List).whereType<String>().toList()
        : const [],
  );
}

enum CloudResolution { desktop, phone, mergeDesktop, mergePhone }

class CloudModelConflict {
  CloudModelConflict(this.desktop, this.phone, this.operation, this.target);
  final ModelProfile desktop;
  final ModelProfile phone;
  final String operation;
  final String? target;

  bool get keysDiffer => desktop.apiKey != phone.apiKey;
  Map<String, Object> get summary => {
    'desktopModel': desktop.model,
    'desktopHost': desktop.endpoint.host,
    'phoneModel': phone.model,
    'phoneHost': phone.endpoint.host,
    'keysDiffer': keysDiffer,
  };
}

class PhoneModelBindings {
  PhoneModelBindings(this.directory, this.models);

  final Directory directory;
  final ModelConnections models;
  File get _file => File('${directory.path}/phone-model-bindings.json');
  late Map<String, PhoneModelBinding> _phones = _load();
  final _seen = <String, DateTime>{};
  final _conflicts = <String, CloudModelConflict>{};
  static final _id = RegExp(r'^[a-zA-Z0-9_-]{16,64}$');
  static const _sources = {'desktop', 'cloud', 'lan', 'local'};

  List<PhoneModelBinding> get phones => _phones.values.toList(growable: false);
  bool online(PhoneModelBinding phone) {
    final seen = _seen[phone.id];
    return seen != null &&
        DateTime.now().difference(seen) < const Duration(seconds: 18);
  }

  ModelProfile? cloudProfile(String? target) => models.profiles
      .where((profile) => profile.id == target && _isCloud(profile))
      .firstOrNull;

  static bool _isCloud(ModelProfile profile) =>
      profile.kind == 'cloud' && profile.endpoint.scheme == 'https';

  List<ModelProfile> get cloudProfiles =>
      models.profiles.where(_isCloud).toList(growable: false);

  CloudModelConflict? conflictFor(String device) => _conflicts[device];

  List<ModelProfile> _sharedProfiles(PhoneModelBinding phone) => [
    for (final id in phone.shared) ?cloudProfile(id),
  ];

  String? _revision(PhoneModelBinding phone) {
    if (phone.target == null && phone.shared.isEmpty) return null;
    final profile = cloudProfile(phone.target);
    return [
      phone.revision ?? 'idle',
      profile?.revision ?? 'desktop',
      ..._sharedProfiles(phone).map((item) => item.revision),
    ].join('.');
  }

  bool pending(PhoneModelBinding phone) =>
      _revision(phone) != phone.acknowledged;

  String _catalogRevision(String? generation, List<ModelProfile> catalog) => [
    generation ?? 'catalog',
    ...catalog.map((profile) => profile.revision),
  ].join('.');

  bool catalogPending(PhoneModelBinding phone) =>
      phone.catalogAcknowledged != null &&
      phone.catalogAcknowledged !=
          _catalogRevision(phone.catalogGeneration, cloudProfiles);

  void refreshCatalog(String device) {
    final phone = _phones[device];
    if (phone == null) throw const FormatException('找不到已配对的手机。');
    _save(
      PhoneModelBinding.read({
        ...phone.toJson(),
        'catalogGeneration': ModelConnections.newId(),
        'catalogAcknowledged': phone.catalogAcknowledged ?? '',
      }),
    );
  }

  void select(String device, String target) {
    final phone = _phones[device];
    if (phone == null || (target.isNotEmpty && cloudProfile(target) == null)) {
      throw const FormatException('找不到手机或云端模型。');
    }
    _save(
      PhoneModelBinding(
        id: device,
        source: phone.source,
        model: phone.model,
        target: target,
        revision: ModelConnections.newId(),
        acknowledged: phone.acknowledged,
        lastEdit: phone.lastEdit,
        shared: {...phone.shared, if (target.isNotEmpty) target}.toList(),
        catalogGeneration: phone.catalogGeneration,
        catalogAcknowledged: phone.catalogAcknowledged,
      ),
    );
  }

  static bool _matches(ModelProfile first, ModelProfile second) =>
      first.endpoint == second.endpoint &&
      first.model == second.model &&
      first.apiKey == second.apiKey;

  ModelProfile _storePhoneProfile(
    ModelProfile incoming, [
    ModelProfile? replace,
  ]) {
    final existing = cloudProfiles
        .where((item) => _matches(item, incoming))
        .firstOrNull;
    if (replace == null && existing != null) return existing;
    if (replace != null && _matches(replace, incoming)) return replace;
    final result = ModelProfile(
      id: replace?.id ?? incoming.id,
      name: replace?.name ?? incoming.name,
      address: incoming.endpoint.toString(),
      model: incoming.model,
      apiKey: incoming.apiKey,
      kind: 'cloud',
      modelIds:
          replace != null &&
              replace.endpoint == incoming.endpoint &&
              replace.apiKey == incoming.apiKey
          ? replace.modelIds
          : const [],
    );
    models.save(result);
    return result;
  }

  void resolve(
    String device,
    CloudModelConflict conflict,
    CloudResolution choice,
  ) {
    final phone = _phones[device];
    final current = cloudProfile(conflict.desktop.id);
    if (phone == null ||
        !identical(_conflicts[device], conflict) ||
        current?.revision != conflict.desktop.revision ||
        phone.target != conflict.target) {
      throw const FormatException('云端配置已变化，请重新查看冲突。');
    }
    final shared = {...phone.shared};
    final ModelProfile selected;
    switch (choice) {
      case CloudResolution.desktop:
        selected = conflict.desktop;
      case CloudResolution.phone:
        selected = _storePhoneProfile(conflict.phone, conflict.desktop);
      case CloudResolution.mergeDesktop:
      case CloudResolution.mergePhone:
        final fromPhone = _storePhoneProfile(conflict.phone);
        shared.addAll([conflict.desktop.id, fromPhone.id]);
        selected = choice == CloudResolution.mergePhone
            ? fromPhone
            : conflict.desktop;
    }
    _save(
      PhoneModelBinding(
        id: device,
        source: phone.source,
        model: phone.model,
        target: selected.id,
        revision: ModelConnections.newId(),
        acknowledged: phone.acknowledged,
        lastEdit: conflict.operation,
        shared: shared.toList(),
        catalogGeneration: phone.catalogGeneration,
        catalogAcknowledged: phone.catalogAcknowledged,
      ),
    );
    _conflicts.remove(device);
  }

  Map<String, Object> _cloudConfig(
    ModelProfile profile, {
    bool catalog = false,
  }) => {
    'source': 'cloud',
    'url': profile.endpoint.toString(),
    'model': profile.model,
    'key': profile.apiKey,
    if (catalog && profile.modelIds.isNotEmpty)
      'modelIds': profile.modelIds.take(128).toList(),
  };

  Map<String, Object?> exchange(Map<String, Object?> request) {
    final device = request['device'];
    final source = request['source'];
    final model = request['model'];
    final seen = request['seen'];
    final edit = request['edit'];
    final compare = request['compare'];
    final catalogSeen = request['cloudCatalog'];
    if (device is! String ||
        !_id.hasMatch(device) ||
        source is! String ||
        !_sources.contains(source) ||
        model is! String ||
        model.length > 200 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(model) ||
        (seen != null && (seen is! String || seen.length > 2048)) ||
        (catalogSeen != null &&
            (catalogSeen is! String || catalogSeen.length > 2048)) ||
        (compare != null && (compare is! String || !_id.hasMatch(compare))) ||
        (edit != null && (edit is! String || !_id.hasMatch(edit)))) {
      throw const FormatException('手机模型同步数据无效。');
    }
    final previous = _phones[device];
    if (previous == null && _phones.length >= 24) {
      throw const FormatException('已达到手机绑定数量上限。');
    }
    var target = previous?.target;
    var revision = previous?.revision;
    var lastEdit = previous?.lastEdit;
    final shared = <String>{...?previous?.shared};
    final knownRevision = previous == null ? null : _revision(previous);
    final initialCatalog = cloudProfiles;
    final catalogKnown =
        catalogSeen is String &&
        catalogSeen.isNotEmpty &&
        catalogSeen.split('.').skip(1).join('.') ==
            initialCatalog.map((profile) => profile.revision).join('.');
    Map<String, Object> catalogUpdate() {
      if (catalogSeen == null) return const {};
      final catalog = cloudProfiles;
      final revision = _catalogRevision(previous?.catalogGeneration, catalog);
      return {
        'catalogRevision': revision,
        if (catalogSeen != revision)
          'options': [
            for (final item in catalog)
              {
                ..._cloudConfig(item, catalog: true),
                'id': item.id,
                'name': item.name,
              },
          ],
      };
    }

    final operation = edit is String ? edit : compare as String?;
    if (operation != null && operation != lastEdit) {
      if (source == 'cloud') {
        final address = request['url'];
        final key = request['key'];
        if (address is! String ||
            address.length > 2048 ||
            key is! String ||
            Uri.tryParse(address)?.scheme != 'https') {
          throw const FormatException('手机云端模型需要 HTTPS 地址。');
        }
        final profile = ModelProfile(
          id: ModelConnections.newId(),
          name: '手机 · ${model.length > 73 ? model.substring(0, 73) : model}',
          address: address,
          model: model,
          apiKey: key,
          kind: 'cloud',
        );
        final bound = cloudProfile(target);
        final alternate =
            (catalogSeen != null
                    ? initialCatalog
                    : previous == null
                    ? const <ModelProfile>[]
                    : _sharedProfiles(previous))
                .where((item) => _matches(item, profile))
                .firstOrNull;
        final desktop =
            bound ?? (target == null ? cloudProfiles.firstOrNull : null);
        final selectedFromCatalog = catalogSeen != null && alternate != null;
        final addingToKnownCatalog =
            catalogKnown && request['add'] == '1' && compare == null;
        final needsChoice =
            desktop != null &&
            !_matches(desktop, profile) &&
            ((bound == null && !selectedFromCatalog && !addingToKnownCatalog) ||
                seen != knownRevision ||
                (compare != null && alternate == null) ||
                _conflicts.containsKey(device));
        if (needsChoice) {
          final old = _conflicts[device];
          if (old == null ||
              old.operation != operation ||
              old.desktop.revision != desktop.revision ||
              !_matches(old.phone, profile)) {
            _conflicts[device] = CloudModelConflict(
              desktop,
              profile,
              operation,
              target,
            );
          }
          _seen[device] = DateTime.now();
          if (previous == null) {
            _save(PhoneModelBinding(id: device, source: source, model: model));
          }
          if (request['conflictSupport'] != '1') {
            throw const FormatException('云端模型配置有冲突，请在电脑处理。');
          }
          return {
            'revision': seen,
            'conflict': _conflicts[device]!.summary,
            ...catalogUpdate(),
          };
        }
        final matchesUnbound =
            target == null && desktop != null && _matches(desktop, profile);
        if (edit != null ||
            (compare != null && (alternate != null || matchesUnbound))) {
          target =
              (alternate ??
                      _storePhoneProfile(
                        profile,
                        request['add'] == '1' ? null : bound,
                      ))
                  .id;
          shared.add(target);
          revision = ModelConnections.newId();
        }
      } else if (edit != null) {
        target = null;
        revision = null;
      }
      _conflicts.remove(device);
      lastEdit = operation;
    } else if (source == 'cloud' &&
        previous != null &&
        knownRevision != seen &&
        cloudProfile(target) != null &&
        !online(previous) &&
        request['conflictSupport'] == '1' &&
        operation == null) {
      return {'revision': seen, 'compareRequired': true};
    }
    final phone = PhoneModelBinding(
      id: device,
      source: source,
      model: source == 'cloud' ? model : '',
      target: target,
      revision: revision,
      acknowledged: seen is String ? seen : null,
      lastEdit: lastEdit,
      shared: shared.toList(),
      catalogGeneration: previous?.catalogGeneration,
      catalogAcknowledged:
          catalogSeen as String? ?? previous?.catalogAcknowledged,
    );
    _save(phone);
    _seen[device] = DateTime.now();
    final effective = _revision(phone);
    final profile = cloudProfile(target);
    return {
      'revision': effective,
      if (target != null && effective != seen)
        'selection': profile == null
            ? {'source': 'desktop'}
            : _cloudConfig(profile, catalog: true),
      if (catalogSeen == null && effective != seen)
        'options': [
          for (final item in _sharedProfiles(phone))
            {..._cloudConfig(item), 'id': item.id, 'name': item.name},
        ],
      ...catalogUpdate(),
    };
  }

  Map<String, PhoneModelBinding> _load() {
    if (!_file.existsSync()) return {};
    final entries = jsonDecode(_file.readAsStringSync());
    if (entries is! List) throw const FormatException('手机模型绑定文件无效。');
    try {
      return {
        for (final item in entries.map(
          (value) => PhoneModelBinding.read(value as Map),
        ))
          item.id: item,
      };
    } on TypeError {
      throw const FormatException('手机模型绑定文件无效。');
    }
  }

  void _save(PhoneModelBinding phone) {
    if (jsonEncode(_phones[phone.id]?.toJson()) == jsonEncode(phone.toJson())) {
      return;
    }
    final next = {..._phones, phone.id: phone};
    directory.createSync(recursive: true);
    final file = File('${_file.path}.${ModelConnections.newId()}.tmp');
    try {
      file.writeAsStringSync(
        jsonEncode(next.values.map((value) => value.toJson()).toList()),
        flush: true,
      );
      file.renameSync(_file.path);
    } finally {
      if (file.existsSync()) file.deleteSync();
    }
    _phones = next;
  }
}
