import 'dart:typed_data';

class OfflineVoice {
  Future<void> check() async {}
  bool get installed => false;
  Future<void> install(void Function(double?) progress) async =>
      throw UnsupportedError('离线音色暂不可用');
  Future<void> remove() async => throw UnsupportedError('离线音色暂不可用');
  Future<Uint8List> synthesize(String text) async =>
      throw UnsupportedError('离线音色暂不可用');
  Future<({String path, Future<void> Function() delete})> stageAudio(
    Uint8List wav,
  ) async => throw UnsupportedError('离线音色暂不可用');
  void dispose() {}
}
