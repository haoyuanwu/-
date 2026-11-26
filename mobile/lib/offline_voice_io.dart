import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

const _modelName = 'sherpa-onnx-zipvoice-distill-int8-zh-en-emilia';
const _release = 'https://github.com/k2-fsa/sherpa-onnx/releases/download';
const _modelSize = 109162785;
const _vocoderSize = 54157409;
const _downloadSize = _modelSize + _vocoderSize;
const _modelHash =
    '77219c8b40f4ee8d73a7f902305ff6c1128ef9b54461c41b4ca6ed890b6c2803';
const _vocoderHash =
    'bcb3b970e384161c4d634f0bb9e999ff1c471b34c9bc0b1049a5014065ed3cc0';
const _vocoderName = 'vocos_24khz.onnx';
const _referenceAsset = 'assets/zipvoice_reference.pcm';
const _referenceRate = 16000;
const _referenceText = '场景在金字塔上展示，不同的金字塔被点亮。';
const _files = [
  'encoder.int8.onnx',
  'decoder.int8.onnx',
  _vocoderName,
  'lexicon.txt',
  'tokens.txt',
];

class OfflineVoice {
  String? _modelPath;
  Future<SendPort>? _worker;
  HttpClient? _downloadClient;

  bool get installed => _modelPath != null;

  Future<Directory> _modelDirectory() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/voice/$_modelName');
  }

  Future<void> check() async {
    final directory = await _modelDirectory();
    if (await _isComplete(directory.path)) {
      _modelPath = directory.path;
      await _removeLegacyModel(directory.parent);
    }
  }

  Future<void> install(void Function(double?) progress) async {
    if (installed) return;
    final directory = await _modelDirectory();
    await directory.parent.create(recursive: true);
    final staging = await directory.parent.createTemp('voice-download-');
    try {
      final archive = File('${staging.path}/model.tar.bz2');
      final vocoder = File('${staging.path}/$_vocoderName');
      await _download(
        archive,
        '$_release/tts-models/$_modelName.tar.bz2',
        _modelSize,
        (size) => progress(size / _downloadSize),
      );
      await _download(
        vocoder,
        '$_release/vocoder-models/$_vocoderName',
        _vocoderSize,
        (size) => progress((_modelSize + size) / _downloadSize),
      );
      progress(null);
      await _unpackInBackground(archive.path, staging.path);
      final unpacked = Directory('${staging.path}/$_modelName');
      if (await directory.exists()) await directory.delete(recursive: true);
      await unpacked.rename(directory.path);
      _modelPath = directory.path;
      await _removeLegacyModel(directory.parent);
    } finally {
      await staging.delete(recursive: true);
    }
  }

  Future<void> remove() async {
    final directory = await _modelDirectory();
    _modelPath = null;
    final startup = _worker;
    _worker = null;
    if (startup != null) {
      final stopped = ReceivePort();
      try {
        final worker = await startup;
        worker.send(stopped.sendPort);
        await stopped.first;
      } catch (_) {
        // A failed startup never opened the model files.
      } finally {
        stopped.close();
      }
    }
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } catch (_) {
      await check();
      rethrow;
    }
  }

  Future<void> _download(
    File destination,
    String url,
    int expectedSize,
    void Function(int) progress,
  ) async {
    const timeout = Duration(seconds: 30);
    final client = HttpClient()..connectionTimeout = timeout;
    _downloadClient = client;
    final output = destination.openWrite();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw const HttpException('模型服务器返回错误');
      }
      var size = 0;
      await output.addStream(
        response.timeout(timeout).map((chunk) {
          size += chunk.length;
          if (size > expectedSize) throw const FormatException('模型大小不符');
          progress(size);
          return chunk;
        }),
      );
      if (size != expectedSize) throw const FormatException('模型下载不完整');
    } finally {
      _downloadClient = null;
      client.close(force: true);
      await output.close();
    }
  }

  Future<Uint8List> synthesize(String text) async {
    final path = _modelPath;
    if (path == null) throw StateError('离线语音模型尚未安装');
    final startup = _worker ??= _startWorker(path);
    final SendPort worker;
    try {
      worker = await startup;
    } catch (_) {
      if (identical(_worker, startup)) _worker = null;
      rethrow;
    }
    final reply = ReceivePort();
    try {
      worker.send((reply.sendPort, text));
      final result = await reply.first;
      if (result is TransferableTypedData) {
        return result.materialize().asUint8List();
      }
      throw StateError(result as String);
    } finally {
      reply.close();
    }
  }

  Future<({String path, Future<void> Function() delete})> stageAudio(
    Uint8List wav,
  ) async {
    final cache = await getTemporaryDirectory();
    final directory = await cache.createTemp('voice-playback-');
    Future<void> delete() async => directory.delete(recursive: true);
    try {
      final file = await File('${directory.path}/speech.wav').writeAsBytes(wav);
      return (path: file.path, delete: delete);
    } catch (_) {
      await delete();
      rethrow;
    }
  }

  void dispose() {
    _downloadClient?.close(force: true);
    _worker?.then((port) => port.send(null), onError: (Object _) {});
  }
}

Future<void> _removeLegacyModel(Directory parent) async {
  final legacy = Directory('${parent.path}/kokoro-int8-multi-lang-v1_1');
  try {
    if (await FileSystemEntity.type(legacy.path, followLinks: false) ==
        FileSystemEntityType.directory) {
      await legacy.delete(recursive: true);
    }
  } on FileSystemException {
    // Cleanup can be retried the next time the installed model is checked.
  }
}

Future<bool> _isComplete(String directory) async {
  for (final name in _files) {
    final file = File('$directory/$name');
    if (!await file.exists() || await file.length() == 0) return false;
  }
  return true;
}

Future<void> _unpackInBackground(String archivePath, String outputPath) =>
    Isolate.run(() => _unpack(archivePath, outputPath));

Future<void> _unpack(String archivePath, String outputPath) async {
  for (final (path, expected) in [
    (archivePath, _modelHash),
    ('$outputPath/$_vocoderName', _vocoderHash),
  ]) {
    final digest = await sha256.bind(File(path).openRead()).single;
    if (digest.toString() != expected) {
      throw const FormatException('模型文件校验失败');
    }
  }
  await extractFileToDisk(archivePath, outputPath, verify: true);
  final modelPath = '$outputPath/$_modelName';
  await File('$outputPath/$_vocoderName').rename('$modelPath/$_vocoderName');
  if (!await _isComplete(modelPath)) {
    throw const FormatException('离线语音模型缺少必要文件');
  }
}

Future<SendPort> _startWorker(String path) async {
  final pcm = await rootBundle.load(_referenceAsset);
  if (pcm.lengthInBytes == 0 || pcm.lengthInBytes.isOdd) {
    throw const FormatException('离线参考音频无效');
  }
  final reference = Float32List(pcm.lengthInBytes ~/ 2);
  for (var i = 0; i < reference.length; i++) {
    reference[i] = pcm.getInt16(i * 2, Endian.little) / 32768;
  }
  final ready = ReceivePort();
  try {
    await Isolate.spawn(_voiceWorker, (ready.sendPort, path, reference));
    return await ready.first as SendPort;
  } finally {
    ready.close();
  }
}

Future<void> _voiceWorker((SendPort, String, Float32List) startup) async {
  final (ready, path, reference) = startup;
  final requests = ReceivePort();
  ready.send(requests.sendPort);
  sherpa.OfflineTts? tts;
  SendPort? stopped;
  try {
    await for (final request in requests) {
      if (request == null) break;
      if (request is SendPort) {
        stopped = request;
        break;
      }
      final (reply, text) = request as (SendPort, String);
      try {
        final engine = tts ??= _openModel(path);
        final mark = text[text.length - 1];
        final (speed, pauseMs) = switch (mark) {
          '?' || '？' => (0.94, 210),
          '!' || '！' => (1.02, 180),
          '.' || '。' => (0.97, 160),
          _ => (0.97, 80),
        };
        final audio = engine.generateWithConfig(
          text: text,
          config: sherpa.OfflineTtsGenerationConfig(
            referenceAudio: reference,
            referenceSampleRate: _referenceRate,
            referenceText: _referenceText,
            numSteps: 4,
            speed: speed,
            silenceScale: 0.5,
          ),
        );
        if (audio.samples.isEmpty) throw StateError('未合成可播放的语音');
        reply.send(
          TransferableTypedData.fromList([_encodeWav(audio, pauseMs)]),
        );
      } catch (error) {
        reply.send(error.toString());
      }
    }
  } finally {
    requests.close();
    tts?.free();
    stopped?.send(null);
  }
}

sherpa.OfflineTts _openModel(String path) {
  sherpa.initBindings();
  return sherpa.OfflineTts(
    sherpa.OfflineTtsConfig(
      model: sherpa.OfflineTtsModelConfig(
        numThreads: 2,
        zipvoice: sherpa.OfflineTtsZipVoiceModelConfig(
          encoder: '$path/encoder.int8.onnx',
          decoder: '$path/decoder.int8.onnx',
          vocoder: '$path/$_vocoderName',
          tokens: '$path/tokens.txt',
          lexicon: '$path/lexicon.txt',
        ),
      ),
    ),
  );
}

Uint8List _encodeWav(sherpa.GeneratedAudio audio, int pauseMs) {
  final pauseSamples = audio.sampleRate * pauseMs ~/ 1000;
  final length = (audio.samples.length + pauseSamples) * 2;
  final wav = ByteData(44 + length)
    ..setUint32(0, 0x52494646) // RIFF
    ..setUint32(4, 36 + length, Endian.little)
    ..setUint32(8, 0x57415645) // WAVE
    ..setUint32(12, 0x666d7420) // fmt
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, 1, Endian.little)
    ..setUint32(24, audio.sampleRate, Endian.little)
    ..setUint32(28, audio.sampleRate * 2, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little)
    ..setUint32(36, 0x64617461) // data
    ..setUint32(40, length, Endian.little);
  for (var i = 0; i < audio.samples.length; i++) {
    final sample = audio.samples[i].clamp(-1.0, 1.0);
    wav.setInt16(44 + i * 2, (sample * 32767).round(), Endian.little);
  }
  return wav.buffer.asUint8List();
}
