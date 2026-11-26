import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rear_eyes_mobile/interaction.dart';
import 'package:rear_eyes_mobile/main.dart';

void main() {
  testWidgets(
    'home prioritizes display and groups settings on separate routes',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final messenger = tester.binding.defaultBinaryMessenger;
      final events = MethodChannel(RobotInteraction.events.name);
      messenger.setMockMethodCallHandler(native, (_) async => null);
      messenger.setMockMethodCallHandler(RobotInteraction.bridge, (call) async {
        if (call.method == 'capabilities') return {'notifications': true};
        if (call.method == 'notificationAccess') return true;
        return null;
      });
      messenger.setMockMethodCallHandler(events, (_) async => null);
      addTearDown(() {
        for (final channel in [native, RobotInteraction.bridge, events]) {
          messenger.setMockMethodCallHandler(channel, null);
        }
      });

      await tester.pumpWidget(const RearEyesMobile());
      await tester.pump();
      expect(
        tester.getTopLeft(find.text('主屏横屏显示')).dy,
        lessThan(tester.getTopLeft(find.text('对话')).dy),
      );
      expect(find.text('桌面模型连接'), findsOneWidget);
      expect(find.text('未配对'), findsOneWidget);
      expect(find.text('自动睡眠'), findsNothing);
      expect(find.text('模型设置'), findsNothing);

      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.text('模型设置'), findsOneWidget);
      await tester.tap(find.text('显示'));
      await tester.pumpAndSettle();
      expect(find.text('自动睡眠'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      await tester.tap(find.text('语音与提醒'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('提醒规则'));
      await tester.pumpAndSettle();
      expect(find.text('管理通知访问权限'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('最近提醒'));
      await tester.pumpAndSettle();
      expect(find.text('暂无提醒'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
