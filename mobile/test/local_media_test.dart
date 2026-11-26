import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rear_eyes_mobile/chat_reasoning.dart';
import 'package:rear_eyes_mobile/interaction.dart';
import 'package:rear_eyes_mobile/phone_model.dart';
import 'package:rear_eyes_mobile/remote.dart';
import 'package:robot_eyes_models/robot_eyes_models.dart';

class _LocalClient extends RemoteClient {
  final requests =
      <({List<Map<String, String>> messages, Map<int, GgufMedia> media})>[];

  @override
  Stream<ChatChunk> localMediaChat(
    PhoneModel profile,
    List<Map<String, String>> messages,
    Map<int, GgufMedia> media,
  ) async* {
    requests.add((messages: messages, media: media));
    yield (text: '附件已读取。', thinking: false);
  }
}

void main() {
  test('renamed mmproj cannot be validated as the main GGUF', () async {
    final directory = await Directory.systemTemp.createTemp('robot-eyes-gguf-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/model.gguf');
    final bytes = BytesBuilder()..add('GGUF'.codeUnits);
    void number(int value, int width) {
      final buffer = ByteData(width);
      if (width == 4) {
        buffer.setUint32(0, value, Endian.little);
      } else {
        buffer.setUint64(0, value, Endian.little);
      }
      bytes.add(buffer.buffer.asUint8List());
    }

    void string(String value) {
      number(value.length, 8);
      bytes.add(value.codeUnits);
    }

    number(3, 4);
    number(0, 8);
    number(1, 8);
    string('general.architecture');
    number(8, 4);
    string('clip');
    await file.writeAsBytes(bytes.takeBytes());
    await expectLater(checkGgufFile(file.path), throwsFormatException);
    await checkGgufFile(file.path, projector: true);
  });

  test(
    'local model capabilities round trip and legacy GGUF remains text only',
    () {
      final profile = PhoneModel.file(
        'model.gguf',
        'Local',
        projectorPath: 'mmproj.gguf',
        mediaTypes: {GgufMediaType.image, GgufMediaType.audio},
      );
      final restored = PhoneModel.fromJson(profile.toJson())!;
      expect(restored.projectorPath, 'mmproj.gguf');
      expect(restored.mediaTypes, profile.mediaTypes);
      expect(
        PhoneModel.fromJson(PhoneModel.file('old.gguf', 'Old').toJson())!
            .mediaTypes,
        isEmpty,
      );
      expect(
        () => PhoneModel.file(
          'old.gguf',
          'Old',
          mediaTypes: {GgufMediaType.audio},
        ),
        throwsFormatException,
      );
    },
  );

  testWidgets('attachment and follow-up both route to the local runtime', (
    tester,
  ) async {
    final client = _LocalClient();
    final interaction = RobotInteraction(client, () => null)
      ..readAnswers = false;
    addTearDown(interaction.dispose);
    final profile = PhoneModel.file(
      'model.gguf',
      'Local',
      projectorPath: 'mmproj.gguf',
      mediaTypes: {GgufMediaType.image},
    );
    interaction.configureModel(ModelSource.local, profile);
    final bytes = Uint8List.fromList([1, 2, 3]);
    interaction.setDraftMedia((
      type: GgufMediaType.audio,
      name: 'voice.wav',
      bytes: bytes,
    ));
    expect(interaction.draftMedia, isNull);
    interaction.setDraftMedia((
      type: GgufMediaType.image,
      name: 'scene.png',
      bytes: bytes,
    ));
    await interaction.send();
    await tester.pump();
    expect(client.requests.single.media[0]?.bytes, same(bytes));
    expect(interaction.question, contains('scene.png'));
    expect(interaction.draftMedia, isNull);
    expect(interaction.reply, '附件已读取。');

    await interaction.send('继续描述');
    await tester.pump();
    expect(client.requests.last.media[0]?.name, 'scene.png');
    expect(client.requests.last.messages.last['content'], '继续描述');
  });
}
