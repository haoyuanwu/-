import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:llamadart/llamadart.dart' as llama;
import 'package:path_provider/path_provider.dart';

import 'media.dart';

typedef GgufFile = ({String path, String name});

const supportsGgufFiles = true;
const _storagePrefix = 'imported:';
bool _generating = false;

Future<Directory> _modelDirectory() async =>
    Directory('${(await getApplicationSupportDirectory()).path}/models');

Future<File> _modelFile(String path) async {
  if (!path.startsWith(_storagePrefix)) return File(path);
  final name = path.substring(_storagePrefix.length);
  if (!RegExp(r'^[a-zA-Z0-9_-]+\.gguf$').hasMatch(name)) {
    throw const FormatException('模型文件位置无效，请重新选择。');
  }
  return File('${(await _modelDirectory()).path}/$name');
}

const _projectorAsModel = FormatException(
  '这是配套投影文件。请先选择对话主模型，再在图像或语音输入下添加此文件。',
);

// Read metadata only. Tensor weights and model vocabulary can be very large.
bool _isProjector(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  if (bytes.length < 24) return false;
  final version = data.getUint32(4, Endian.little);
  if (version != 2 && version != 3) return false;
  const widths = [1, 1, 2, 2, 4, 4, 4, 1, 0, 0, 8, 8, 8];
  var offset = 24;
  int read(int width) {
    final value = width == 4
        ? data.getUint32(offset, Endian.little)
        : data.getUint64(offset, Endian.little);
    offset += width;
    return value;
  }

  String readString() {
    final length = read(8);
    if (length < 0 || length > bytes.length - offset)
      throw const FormatException();
    final start = offset;
    offset += length;
    return String.fromCharCodes(bytes, start, offset);
  }

  try {
    final count = data.getUint64(16, Endian.little);
    for (var i = 0; i < count && offset < bytes.length; i++) {
      final key = readString();
      final type = read(4);
      if (type == 8) {
        final value = readString();
        if (key == 'general.architecture' &&
                (value == 'clip' || value == 'mmproj') ||
            key == 'general.type' && value == 'mmproj') {
          return true;
        }
      } else if (type == 9) {
        final element = read(4);
        final length = read(8);
        if (length < 0 || element >= widths.length || element == 9)
          return false;
        if (element == 8) {
          for (var j = 0; j < length; j++) {
            readString();
          }
        } else {
          final width = widths[element];
          if (length > (bytes.length - offset) ~/ width) return false;
          offset += length * width;
        }
      } else if (type < widths.length) {
        offset += widths[type];
      } else {
        return false;
      }
    }
  } on RangeError {
    return false;
  } on FormatException {
    return false;
  }
  return false;
}

Future<void> _checkGguf(File file, {required bool projector}) async {
  try {
    final stream = await file.open();
    try {
      final bytes = await stream.read(projector ? 4 : 128 * 1024);
      if (bytes.length < 4 || String.fromCharCodes(bytes, 0, 4) != 'GGUF') {
        throw const FormatException('无法读取 GGUF 模型文件，请重新选择。');
      }
      if (!projector && _isProjector(bytes)) throw _projectorAsModel;
    } finally {
      await stream.close();
    }
  } on FileSystemException {
    throw const FormatException('无法读取 GGUF 模型文件，请重新选择。');
  }
}

Future<void> checkGgufFile(String path, {bool projector = false}) async =>
    _checkGguf(await _modelFile(path), projector: projector);

Future<void> discardImportedGguf(String path) async {
  if (!path.startsWith(_storagePrefix)) return;
  try {
    await (await _modelFile(path)).delete();
  } on FileSystemException {
    // The staged import may already be gone.
  }
}

Future<GgufFile?> pickGgufFile({bool projector = false}) async {
  final picked = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: const ['gguf'],
    dialogTitle: projector ? '选择 mmproj GGUF 文件' : '选择 GGUF 对话模型',
  );
  if (picked == null) return null;
  final name = picked.name.replaceFirst(
    RegExp(r'\.gguf$', caseSensitive: false),
    '',
  );
  if (!projector &&
      RegExp(
        r'(^|[^a-z0-9])mmproj([^a-z0-9]|$)',
        caseSensitive: false,
      ).hasMatch(name)) {
    throw _projectorAsModel;
  }
  final path = picked.path;
  if (Platform.isWindows || Platform.isLinux) {
    if (path == null) throw const FormatException('无法访问所选的模型文件。');
    await checkGgufFile(path, projector: projector);
    return (path: path, name: name);
  }

  final directory = await _modelDirectory();
  await directory.create(recursive: true);
  final id =
      '${DateTime.now().microsecondsSinceEpoch}-${math.Random.secure().nextInt(1 << 30)}.gguf';
  final partial = File('${directory.path}/$id.part');
  try {
    final output = partial.openWrite();
    try {
      await output.addStream(picked.readAsByteStream());
    } finally {
      await output.close();
    }
    await _checkGguf(partial, projector: projector);
    await partial.rename('${directory.path}/$id');
    return (path: '$_storagePrefix$id', name: name);
  } finally {
    if (await partial.exists()) await partial.delete();
  }
}

Future<GgufMedia?> pickGgufMedia(GgufMediaType type) async {
  const limit = 8 * 1024 * 1024;
  final file = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: type.extensions,
    dialogTitle: '选择${type.label}文件',
  );
  if (file == null) return null;
  if ((file.lengthSync() ?? 0) > limit) {
    throw const FormatException('附件不能超过 8 MB。');
  }
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in file.readAsByteStream()) {
    if (chunk.length > limit - bytes.length) {
      throw const FormatException('附件不能超过 8 MB。');
    }
    bytes.add(chunk);
  }
  if (bytes.isEmpty) throw const FormatException('所选附件为空。');
  return (type: type, name: file.name, bytes: bytes.takeBytes());
}

Future<llama.LlamaEngine> _loadEngine(
  String path,
  String? projectorPath,
) async {
  await checkGgufFile(path);
  if (projectorPath != null)
    await checkGgufFile(projectorPath, projector: true);
  return llama.LlamaEngine.load(
    llama.LlamaModel(
      llama.ModelSource.path((await _modelFile(path)).path),
      projector: projectorPath == null
          ? null
          : llama.ModelSource.path((await _modelFile(projectorPath)).path),
    ),
    params: llama.ModelParams(
      contextSize: 4096,
      gpuLayers: Platform.isAndroid ? 0 : llama.ModelParams.maxGpuLayers,
    ),
  );
}

void _beginModelOperation() {
  if (_generating) throw const FormatException('本地模型正在回复，请稍后重试。');
  _generating = true;
}

Future<void> _releaseEngine(llama.LlamaEngine? engine) async {
  try {
    await engine?.dispose();
  } finally {
    _generating = false;
  }
}

Future<void> _requireMedia(
  llama.LlamaEngine engine,
  Set<GgufMediaType> types,
) async {
  for (final type in types) {
    final supported = await switch (type) {
      GgufMediaType.image => engine.supportsVision,
      GgufMediaType.audio => engine.supportsAudio,
    };
    if (!supported) {
      throw FormatException('当前模型和 mmproj 不支持${type.label}输入。');
    }
  }
}

Future<void> checkGgufMediaSupport(
  String path,
  String projectorPath,
  Set<GgufMediaType> types,
) async {
  _beginModelOperation();
  llama.LlamaEngine? engine;
  try {
    engine = await _loadEngine(path, projectorPath);
    await _requireMedia(engine, types);
  } on llama.LlamaException {
    throw const FormatException('无法加载多模态模型，请检查 mmproj 是否匹配及设备内存。');
  } finally {
    await _releaseEngine(engine);
  }
}

llama.LlamaChatMessage _chatMessage(
  Map<String, String> message,
  GgufMedia? media,
) {
  final role = message['role'] == 'assistant'
      ? llama.LlamaChatRole.assistant
      : llama.LlamaChatRole.user;
  final text = message['content']!;
  if (media == null)
    return llama.LlamaChatMessage.fromText(role: role, text: text);
  return llama.LlamaChatMessage.withContent(
    role: role,
    content: [
      switch (media.type) {
        GgufMediaType.image => llama.LlamaImageContent(bytes: media.bytes),
        GgufMediaType.audio => llama.LlamaAudioContent(bytes: media.bytes),
      },
      llama.LlamaTextContent(text),
    ],
  );
}

Stream<String> ggufChat(
  String path,
  List<Map<String, String>> messages, {
  String? projectorPath,
  Map<int, GgufMedia> media = const {},
}) async* {
  if (media.isNotEmpty && projectorPath == null) {
    throw const FormatException('请为本机模型配置匹配的 mmproj 文件。');
  }
  _beginModelOperation();
  llama.LlamaEngine? engine;
  try {
    engine = await _loadEngine(path, media.isEmpty ? null : projectorPath);
    await _requireMedia(engine, {for (final item in media.values) item.type});
    final stream = engine
        .create(
          [
            for (final (index, message) in messages.indexed)
              _chatMessage(message, media[index]),
          ],
          enableThinking: false,
          params: const llama.GenerationParams(maxTokens: 768),
        )
        .textDeltas();
    var hasAnswer = false;
    await for (final text in stream) {
      hasAnswer = hasAnswer || text.trim().isNotEmpty;
      yield text;
    }
    if (!hasAnswer) throw const FormatException('本地模型没有返回文字。');
  } on llama.LlamaException {
    throw const FormatException('无法运行此本地模型，请检查 GGUF 格式和设备内存。');
  } on FileSystemException {
    throw const FormatException('无法访问模型文件，请重新选择。');
  } finally {
    await _releaseEngine(engine);
  }
}
