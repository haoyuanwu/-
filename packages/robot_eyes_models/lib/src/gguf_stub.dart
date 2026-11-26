import 'media.dart';

typedef GgufFile = ({String path, String name});

const supportsGgufFiles = false;

Future<GgufFile?> pickGgufFile({bool projector = false}) async =>
    throw const FormatException('请在 Robot Eyes 原生 App 中选择模型文件。');

Future<void> checkGgufFile(String path, {bool projector = false}) async =>
    throw const FormatException('请在 Robot Eyes 原生 App 中使用本地模型。');

Future<void> discardImportedGguf(String path) async {}

Stream<String> ggufChat(
  String path,
  List<Map<String, String>> messages, {
  String? projectorPath,
  Map<int, GgufMedia> media = const {},
}) async* {
  await checkGgufFile(path);
}

Future<void> checkGgufMediaSupport(
  String path,
  String projectorPath,
  Set<GgufMediaType> types,
) => checkGgufFile(path);

Future<GgufMedia?> pickGgufMedia(GgufMediaType type) async =>
    throw const FormatException('请在 Robot Eyes 原生 App 中添加附件。');
