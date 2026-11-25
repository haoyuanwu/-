import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rear_eyes_mobile/interaction.dart';
import 'package:rear_eyes_mobile/notice_rules_view.dart';
import 'package:rear_eyes_mobile/remote.dart';

class _Interaction extends RobotInteraction {
  _Interaction() : super(RemoteClient(), () => null);

  @override
  Future<List<NoticeChoice>> loadNoticeChoices({
    required bool contacts,
  }) async => contacts
      ? const [NoticeChoice('1', '测试联系人')]
      : const [NoticeChoice('calendar', '测试日历')];
}

void main() {
  testWidgets('app picker search and save updates the settings summary', (
    tester,
  ) async {
    final interaction = _Interaction();
    addTearDown(interaction.dispose);
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
    await tester.tap(find.text('添加').first);
    await tester.pumpAndSettle();
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
  });

  test('contact filtering matches sender name and normalized phone number', () {
    const contact = NoticeChoice('1', '测试联系人', ['+86 138 0013 8000']);
    expect(contact.matchesSender('测试联系人'), isTrue);
    expect(contact.matchesSender('+8613800138000'), isTrue);
    expect(contact.matchesSender('陌生人 8613800138000'), isFalse);
  });
}
