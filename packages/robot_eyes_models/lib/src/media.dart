import 'dart:typed_data';

enum GgufMediaType {
  image('图像', ['jpg', 'jpeg', 'png']),
  audio('语音', ['wav', 'mp3']);

  const GgufMediaType(this.label, this.extensions);

  final String label;
  final List<String> extensions;
}

typedef GgufMedia = ({GgufMediaType type, String name, Uint8List bytes});
