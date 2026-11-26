import 'package:robot_eyes_models/robot_eyes_models.dart';

enum ModelSource {
  desktop('电脑默认'),
  cloud('云端模型'),
  local('本机模型');

  const ModelSource(this.label);
  final String label;
}

class PhoneModel {
  PhoneModel(
    this.source,
    String address,
    String model,
    String key, {
    Iterable<String> modelIds = const [],
  }) : endpoint = _endpoint(source, address.trim()),
       localPath = null,
       projectorPath = null,
       mediaTypes = const {},
       model = model.trim(),
       key = key.trim(),
       modelIds = List.unmodifiable(modelIds.toSet()) {
    if (this.model.isEmpty || this.model.length > 200) {
      throw const FormatException('请输入模型 ID。');
    }
    if (this.key.length > 2048 || RegExp(r'[^\x21-\x7e]').hasMatch(this.key)) {
      throw const FormatException('访问密钥格式无效。');
    }
  }

  PhoneModel.file(
    String path,
    String name, {
    this.projectorPath,
    Set<GgufMediaType> mediaTypes = const {},
  }) : source = ModelSource.local,
       localPath = path,
       endpoint = Uri(scheme: 'file', path: path),
       model = name.trim(),
       key = '',
       mediaTypes = Set.unmodifiable(mediaTypes),
       modelIds = const [] {
    if (path.isEmpty || model.isEmpty || model.length > 200) {
      throw const FormatException('请选择本机 GGUF 模型文件。');
    }
    if (this.mediaTypes.isNotEmpty &&
        (projectorPath?.isNotEmpty != true || projectorPath == path)) {
      throw const FormatException('请选择模型配套的 mmproj 文件。');
    }
  }

  final ModelSource source;
  final Uri endpoint;
  final String model;
  final String key;
  final String? localPath;
  final String? projectorPath;
  final Set<GgufMediaType> mediaTypes;
  final List<String> modelIds;

  static Uri _endpoint(ModelSource source, String address) {
    final uri = Uri.tryParse(address);
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.port < 1 ||
        uri.port > 65535) {
      throw const FormatException('请输入有效的 HTTP 或 HTTPS 模型地址。');
    }
    final host = uri.host.toLowerCase();
    final loopback = const {'localhost', '127.0.0.1', '::1'}.contains(host);
    switch (source) {
      case ModelSource.cloud:
        if (uri.scheme != 'https') {
          throw const FormatException('云端模型需要 HTTPS 地址。');
        }
      case ModelSource.local:
        if (!loopback) {
          throw const FormatException('本机模型需要手机上的回环地址。');
        }
      case ModelSource.desktop:
        throw const FormatException('请在电脑上设置默认模型。');
    }
    final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    return uri.replace(
      path: path.endsWith('/chat/completions')
          ? path
          : '${path.isEmpty ? '/v1' : path}/chat/completions',
    );
  }

  Map<String, Object> toJson() => {
    'source': source.name,
    if (localPath case final path?)
      'path': path
    else
      'url': endpoint.toString(),
    'model': model,
    'key': key,
    if (mediaTypes.isNotEmpty) ...{
      'projectorPath': projectorPath!,
      'mediaTypes': [for (final type in mediaTypes) type.name],
    },
    if (modelIds.isNotEmpty) 'modelIds': modelIds,
  };

  static PhoneModel? fromJson(Object? value) {
    if (value is! Map) return null;
    final source = ModelSource.values
        .where((source) => source.name == value['source'])
        .firstOrNull;
    if (source == ModelSource.local) {
      if (value case {'path': final String path, 'model': final String name}) {
        final projector = value['projectorPath'];
        final types = value['mediaTypes'];
        return PhoneModel.file(
          path,
          name,
          projectorPath: projector is String ? projector : null,
          mediaTypes:
              projector is String &&
                  projector.isNotEmpty &&
                  projector != path &&
                  types is List
              ? {
                  for (final type in GgufMediaType.values)
                    if (types.contains(type.name)) type,
                }
              : const {},
        );
      }
    }
    if (source == null ||
        value['url'] is! String ||
        value['model'] is! String ||
        value['key'] is! String) {
      return null;
    }
    return PhoneModel(
      source,
      value['url'],
      value['model'],
      value['key'],
      modelIds: value['modelIds'] is List
          ? (value['modelIds'] as List).whereType<String>()
          : const [],
    );
  }

  bool sameCloud(PhoneModel other) =>
      source == ModelSource.cloud &&
      other.source == ModelSource.cloud &&
      endpoint == other.endpoint &&
      model == other.model &&
      key == other.key;
}

class SavedCloudModel {
  const SavedCloudModel(this.id, this.name, this.profile);

  final String id;
  final String name;
  final PhoneModel profile;

  Map<String, Object> toJson() => {...profile.toJson(), 'id': id, 'name': name};

  static SavedCloudModel? read(Object? value) {
    if (value is! Map || value['id'] is! String || value['name'] is! String) {
      return null;
    }
    final profile = PhoneModel.fromJson(value);
    if (profile?.source != ModelSource.cloud) return null;
    return SavedCloudModel(value['id'], value['name'], profile!);
  }
}

typedef CloudConflictSummary = ({
  String desktopModel,
  String desktopHost,
  String phoneModel,
  String phoneHost,
  bool keysDiffer,
});

class PhoneModelSync {
  const PhoneModelSync({
    this.revision,
    this.selection,
    this.profile,
    this.options,
    this.catalogRevision,
    this.conflict,
    this.compareRequired = false,
  });

  final String? revision;
  final ModelSource? selection;
  final PhoneModel? profile;
  final List<SavedCloudModel>? options;
  final String? catalogRevision;
  final CloudConflictSummary? conflict;
  final bool compareRequired;
}
