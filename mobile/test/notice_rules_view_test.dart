import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rear_eyes_mobile/interaction.dart';
import 'package:rear_eyes_mobile/notice_rules_view.dart';
import 'package:rear_eyes_mobile/remote.dart';

void main() {
  testWidgets(
    'app picker excludes previously selected components outside the launcher catalog',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(RobotInteraction.bridge, (call) async {
        expect(call.method, 'notificationApps');
        return [
          {'id': 'calendar', 'name': '测试日历'},
        ];
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(RobotInteraction.bridge, null),
      );
      final interaction = RobotInteraction(RemoteClient(), () => null);
      addTearDown(interaction.dispose);
      interaction.saveNoticeChoices(const [
        NoticeChoice('system-service', '测试系统组件'),
      ], contacts: false);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: interaction,
              builder: (context, _) => NoticeRules(interaction),
            ),
          ),
        ),
      );
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      expect(find.text('测试系统组件'), findsNothing);
      await tester.enterText(find.byType(TextField), '不存在');
      await tester.pump();
      expect(find.text('没有匹配项，试试其他搜索词。'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '日历');
      await tester.pump();
      await tester.tap(find.text('测试日历'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('测试日历'), findsOneWidget);
      expect(interaction.selectedApps.single.id, 'calendar');
    },
  );

  test('contact filtering matches sender name and normalized phone number', () {
    const contact = NoticeChoice('1', '测试联系人', ['+86 138 0013 8000']);
    expect(contact.matchesSender('测试联系人'), isTrue);
    expect(contact.matchesSender('+8613800138000'), isTrue);
    expect(contact.matchesSender('陌生人 8613800138000'), isFalse);
  });
}
