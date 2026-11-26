import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rear_eyes_mobile/interaction.dart';
import 'package:rear_eyes_mobile/model_settings_view.dart';
import 'package:rear_eyes_mobile/phone_model.dart';
import 'package:rear_eyes_mobile/remote.dart';

class _CatalogClient extends RemoteClient {
  @override
  Future<List<String>> cloudModelIds(String address, String key) async => [
    'chat-medium',
    'chat-large',
  ];
}

void main() {
  testWidgets(
    'model subpages track selection and add cloud models in a dialog',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final interaction = RobotInteraction(_CatalogClient(), () => null);
      addTearDown(interaction.dispose);
      final current = PhoneModel(
        ModelSource.cloud,
        'https://one.test',
        'one',
        '',
      );
      final synced = PhoneModel(
        ModelSource.cloud,
        'https://two.test',
        'two',
        '',
      );
      final local = PhoneModel.file('/models/local.gguf', 'local');
      interaction.savedCloudModels = [SavedCloudModel('two', 'Two', synced)];
      interaction.configureModel(ModelSource.cloud, current);
      interaction.rememberLocalModel(local);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => openModelSettings(context, interaction),
                child: const Text('打开设置'),
              ),
            ),
          ),
        ),
      );

      Future<void> tap(String text) async {
        await tester.tap(find.text(text));
        await tester.pumpAndSettle();
      }

      Future<void> back() async {
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
      }

      bool selected(String text) => tester
          .widget<ListTile>(
            find.ancestor(of: find.text(text), matching: find.byType(ListTile)),
          )
          .selected;

      await tap('打开设置');
      expect(find.text('当前使用 · one'), findsOneWidget);
      await tap('云端模型');
      expect(selected('one'), isTrue);
      expect(selected('two'), isFalse);
      await tap('two');
      expect(selected('two'), isTrue);
      expect(interaction.phoneModel, synced);

      await tap('添加');
      expect(find.text('添加云端模型'), findsOneWidget);
      await tap('取消');
      expect(selected('two'), isTrue);
      await tap('添加');
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'https://new.test/v1');
      await tap('获取模型列表');
      await tester.tap(find.byType(DropdownMenu<String>));
      await tester.pumpAndSettle();
      await tap('chat-large');
      await tap('保存并使用');
      expect(selected('chat-large'), isTrue);
      expect(interaction.phoneModel!.modelIds, ['chat-medium', 'chat-large']);

      await back();
      expect(find.text('当前使用 · chat-large'), findsOneWidget);
      await tap('本机模型');
      expect(selected('local'), isFalse);
      await tap('local');
      expect(selected('local'), isTrue);
      expect(interaction.phoneModel, local);
      await tap('添加');
      expect(find.text('选择 GGUF 主模型'), findsOneWidget);
      expect(find.text('选择 mmproj 文件'), findsNothing);
      await tap('图像输入');
      await tap('语音输入');
      expect(find.text('选择 mmproj 文件'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存并使用'))
            .onPressed,
        isNull,
      );
      await tap('取消');
      await back();
      expect(find.text('当前使用 · local'), findsOneWidget);
      await tap('本机模型');
      await tester.tap(find.byTooltip('管理 local'));
      await tester.pumpAndSettle();
      await tap('删除模型');
      await tap('取消');
      expect(selected('local'), isTrue);
      await tester.tap(find.byTooltip('管理 local'));
      await tester.pumpAndSettle();
      await tap('删除模型');
      await tap('删除');
      expect(find.text('local'), findsNothing);
      expect(interaction.localProfiles, isEmpty);
      expect(interaction.modelSource, ModelSource.desktop);
      expect(interaction.phoneModel, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
