import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rear_eyes_desktop/model_connections.dart';
import 'package:rear_eyes_desktop/model_connections_panel.dart';
import 'package:rear_eyes_desktop/phone_model_bindings.dart';

class _LocalModels extends ModelConnections {
  _LocalModels(super.directory);

  @override
  Future<List<String>> fetchModelIds({
    required String address,
    required String apiKey,
    required bool cloud,
    bool allowEmpty = false,
  }) async => ['qwen:latest'];

  @override
  Future<String?> readLocalModelParameters({
    required String address,
    required String apiKey,
    required String model,
  }) async => 'temperature 0.7';
}

void main() {
  testWidgets('add chooses a type and the editor keeps it fixed', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('robot-eyes-models-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final connections = _LocalModels(directory);
    final localPath = '${directory.path}/local.gguf';
    File(localPath).writeAsStringSync('GGUF');
    connections.save(
      ModelProfile(
        id: 'local',
        name: '测试模型',
        address: '',
        model: 'local',
        apiKey: '',
        kind: 'local',
        localPath: localPath,
      ),
    );
    connections.save(
      ModelProfile(
        id: 'ollama',
        name: '我的 Ollama',
        address: 'http://127.0.0.1:11434/v1',
        model: 'qwen:latest',
        apiKey: '',
        kind: 'local',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelConnectionsPanel(
            connections,
            PhoneModelBindings(directory, connections),
          ),
        ),
      ),
    );
    expect(find.text('qwen:latest'), findsOneWidget);
    expect(find.byTooltip('管理 qwen:latest'), findsOneWidget);

    Future<void> tap(String text) async {
      await tester.tap(find.text(text));
      await tester.pumpAndSettle();
    }

    await tap('添加模型');
    expect(find.text('本地模型文件'), findsOneWidget);
    await tap('本地模型服务');
    expect(find.text('添加本地模型服务'), findsOneWidget);
    expect(find.text('http://127.0.0.1:11434/v1'), findsWidgets);
    expect(find.text('获取模型列表'), findsOneWidget);
    expect(find.text('模型运行参数（只读）'), findsOneWidget);
    expect(find.text('temperature 0.7'), findsOneWidget);
    expect(find.text('选择 GGUF 主模型'), findsNothing);
    await tap('关闭');
    await tap('添加模型');
    await tap('云端模型');
    expect(find.text('添加云端模型'), findsOneWidget);
    expect(find.text('服务地址'), findsOneWidget);
    expect(find.text('选择 GGUF 主模型'), findsNothing);
    await tap('关闭');

    await tap('测试模型');
    expect(find.text('编辑本地模型文件'), findsOneWidget);
    expect(find.byType(SegmentedButton<String>), findsNothing);
    expect(find.text('选择 GGUF 主模型'), findsOneWidget);
    await tap('关闭');

    await tester.tap(find.byTooltip('管理 测试模型'));
    await tester.pumpAndSettle();
    await tap('删除模型');
    await tap('删除');
    expect(connections.profiles.map((profile) => profile.id), ['ollama']);
    expect(File(localPath).existsSync(), isTrue);

    await tester.tap(find.byTooltip('管理 qwen:latest'));
    await tester.pumpAndSettle();
    await tap('删除模型');
    await tap('删除');
    expect(connections.profiles, isEmpty);
    await tap('添加模型');
    await tap('本地模型服务');
    await tap('保存');
    final restored = ModelConnections(directory).profiles.single;
    expect(restored.isLocalService, isTrue);
    expect(restored.model, 'qwen:latest');
    expect(
      restored.endpoint.toString(),
      'http://127.0.0.1:11434/v1/chat/completions',
    );
  });
}
