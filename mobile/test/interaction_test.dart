import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rear_eyes_mobile/chat_reasoning.dart';
import 'package:rear_eyes_mobile/desk_voice_feedback.dart';
import 'package:rear_eyes_mobile/interaction.dart';
import 'package:rear_eyes_mobile/interaction_view.dart';
import 'package:rear_eyes_mobile/phone_model.dart';
import 'package:rear_eyes_mobile/remote.dart';
import 'package:rear_eyes_mobile/reply_frame.dart';

class _LoopbackHttpOverrides extends HttpOverrides {}

class _PhoneModelSync extends RemoteClient {
  final reports = <Map<String, String>>[];
  bool offline = false;
  PhoneModelSync response = const PhoneModelSync();
  Completer<PhoneModelSync>? pendingResponse;
  PhoneModel? used;

  @override
  Future<PhoneModelSync> syncPhoneModel(
    Pairing pairing,
    Map<String, String> state,
  ) async {
    reports.add(state);
    if (offline) throw const SocketException('offline');
    if (pendingResponse case final pending?) {
      pendingResponse = null;
      return pending.future;
    }
    return response;
  }

  @override
  Stream<ChatChunk> directChat(
    PhoneModel profile,
    List<Map<String, String>> messages,
  ) async* {
    used = profile;
    yield (text: '云端回复。', thinking: false);
  }
}

class _Desktop extends RemoteClient {
  final answers = <StreamController<ChatChunk>>[];
  final requests = <String>[];
  final cancelled = <String>[];
  final requestConnections = <Pairing>[];
  final cancelConnections = <Pairing>[];
  var useCloudDefault = false;

  @override
  Future<List<DesktopModel>> models(Pairing pairing) async {
    const list = [
      DesktopModel(id: 'local', name: '本地模型', local: true, available: true),
      DesktopModel(id: 'cloud', name: '云端模型', local: false, available: true),
    ];
    return useCloudDefault ? list.reversed.toList() : list;
  }

  @override
  Stream<ChatChunk> chat(
    Pairing pairing,
    DesktopModel model,
    List<Map<String, String>> messages,
    String requestId,
  ) {
    requests.add(requestId);
    requestConnections.add(pairing);
    final answer = StreamController<ChatChunk>();
    answers.add(answer);
    return answer.stream;
  }

  @override
  Future<void> cancelChat(Pairing pairing, String requestId) async {
    cancelled.add(requestId);
    cancelConnections.add(pairing);
  }

  @override
  Stream<ChatChunk> directChat(
    PhoneModel profile,
    List<Map<String, String>> messages,
  ) => Stream.fromIterable([
    (text: '单独返回的推理', thinking: true),
    (text: '<thi', thinking: false),
    (text: 'nk>标签里的推理</th', thinking: false),
    (text: 'ink>直连回复。', thinking: false),
  ]);
}

void main() {
  test('pairing and manual refresh update the catalog without replacing local selection', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final events = MethodChannel(RobotInteraction.events.name);
    messenger.setMockMethodCallHandler(RobotInteraction.bridge, (call) async {
      if (call.method == 'capabilities') return <String, Object>{};
      return null;
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(RobotInteraction.bridge, null);
      messenger.setMockMethodCallHandler(events, null);
    });

    final desktop = _PhoneModelSync();
    Pairing? pairing;
    final interaction = RobotInteraction(desktop, () => pairing);
    addTearDown(interaction.dispose);
    await interaction.initialize();
    final local = PhoneModel.file('/data/private-model.gguf', 'phone-local');
    interaction.configureModel(ModelSource.local, local);
    final cloud = PhoneModel(
      ModelSource.cloud,
      'https://cloud.example/v1',
      'cloud',
      'key',
    );
    final pending = Completer<PhoneModelSync>();
    desktop.pendingResponse = pending;
    desktop.response = PhoneModelSync(
      catalogRevision: 'catalog-two',
      options: [SavedCloudModel('cloud', 'Cloud', cloud)],
    );
    pairing = Pairing.parse(
      '{"url":"https://desk.example.ts.net","token":"${'a' * 43}"}',
    );
    interaction.resetConnection();
    await Future<void>.delayed(Duration.zero);
    expect(desktop.reports.single, containsPair('cloudCatalog', ''));
    final refresh = interaction.syncPhoneModel(force: true);
    pending.complete(
      const PhoneModelSync(catalogRevision: 'catalog-one', options: []),
    );
    await refresh;

    expect(desktop.reports, hasLength(2));
    expect(desktop.reports.last, containsPair('cloudCatalog', 'catalog-one'));
    expect(desktop.reports.last, containsPair('source', 'local'));
    expect(desktop.reports.last, isNot(contains('url')));
    expect(interaction.cloudProfiles, [cloud]);
    expect(interaction.phoneModel, local);
    expect(interaction.phoneModelSyncLabel, '已与电脑同步');
  });

  test(
    'the phone applies desktop cloud credentials and retries offline edits',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final events = MethodChannel(RobotInteraction.events.name);
      String? saved;
      messenger.setMockMethodCallHandler(RobotInteraction.bridge, (call) async {
        if (call.method == 'capabilities') return <String, Object>{};
        if (call.method == 'saveSettings') saved = call.arguments as String;
        return null;
      });
      messenger.setMockMethodCallHandler(events, (_) async => null);
      addTearDown(() {
        messenger.setMockMethodCallHandler(RobotInteraction.bridge, null);
        messenger.setMockMethodCallHandler(events, null);
      });
      final desktop = _PhoneModelSync();
      final pairing = Pairing.parse(
        '{"url":"https://desk.example.ts.net","token":"${'a' * 43}"}',
      );
      final interaction = RobotInteraction(desktop, () => pairing);
      addTearDown(interaction.dispose);
      await interaction.initialize();
      desktop.response = PhoneModelSync(
        revision: 'desktop-selection',
        selection: ModelSource.cloud,
        profile: PhoneModel(
          ModelSource.cloud,
          'https://cloud.example/v1',
          'cloud-a',
          'key-a',
        ),
      );
      await interaction.syncPhoneModel(force: true);
      expect(desktop.reports.single['source'], 'desktop');
      expect(interaction.modelSource, ModelSource.cloud);
      expect(interaction.phoneModel?.key, 'key-a');
      final applied = interaction.phoneModelUpdate;
      expect(applied?.message, '已从电脑同步模型 · cloud-a');
      await interaction.syncPhoneModel(force: true);
      expect(interaction.phoneModelUpdate, applied);
      await interaction.send('你好');
      await Future<void>.delayed(Duration.zero);
      expect(desktop.used?.model, 'cloud-a');
      expect(interaction.reply, '云端回复。');

      desktop.offline = true;
      interaction.configureModel(
        ModelSource.cloud,
        PhoneModel(
          ModelSource.cloud,
          'https://cloud.example/v1',
          'cloud-b',
          'key-b',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final pendingEdit = desktop.reports.last['edit'];
      expect(pendingEdit, isNotNull);
      expect(interaction.phoneModelSyncLabel, '待同步到电脑');
      desktop.offline = false;
      desktop.response = const PhoneModelSync(
        conflict: (
          desktopModel: 'cloud-a-edited',
          desktopHost: 'cloud.example',
          phoneModel: 'cloud-b',
          phoneHost: 'cloud.example',
          keysDiffer: true,
        ),
      );
      await interaction.syncPhoneModel(force: true);
      expect(interaction.phoneModel?.model, 'cloud-b');
      expect(interaction.phoneModelConflict?.desktopModel, 'cloud-a-edited');
      expect(interaction.phoneModelSyncLabel, '云端配置不同，等待处理');
      expect(interaction.phoneModelUpdate, applied);
      final comparison = desktop.reports.last['compare'];
      expect(comparison, isNotNull);

      desktop.response = PhoneModelSync(
        revision: 'phone-selection',
        selection: ModelSource.cloud,
        profile: interaction.phoneModel,
        options: [
          SavedCloudModel(
            'desktop',
            '电脑配置',
            PhoneModel(
              ModelSource.cloud,
              'https://cloud.example/v1',
              'cloud-a-edited',
              'key-a',
            ),
          ),
          SavedCloudModel('phone', '手机配置', interaction.phoneModel!),
        ],
      );
      await interaction.syncPhoneModel(force: true);
      expect(desktop.reports.last, containsPair('seen', 'desktop-selection'));
      expect(desktop.reports.last, containsPair('edit', pendingEdit));
      expect(desktop.reports.last, containsPair('model', 'cloud-b'));
      expect(desktop.reports.last, containsPair('key', 'key-b'));
      expect(desktop.reports.last, containsPair('compare', comparison));
      expect(interaction.phoneModelSyncLabel, '已与电脑同步');
      expect(interaction.phoneModelConflict, isNull);
      expect(interaction.savedCloudModels.map((item) => item.profile.model), [
        'cloud-a-edited',
        'cloud-b',
      ]);
      expect(jsonDecode(saved!)['phoneModelSync']['edit'], isNull);
      expect(jsonDecode(saved!)['phoneModelSync']['options'], hasLength(2));

      desktop.response = const PhoneModelSync();
      interaction.configureModel(
        ModelSource.local,
        PhoneModel(
          ModelSource.local,
          'http://127.0.0.1:11434/v1',
          'phone-only',
          'phone-key',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(desktop.reports.last, containsPair('source', 'local'));
      expect(desktop.reports.last, containsPair('model', ''));
      expect(desktop.reports.last, isNot(contains('url')));
      expect(desktop.reports.last, isNot(contains('key')));
    },
  );

  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'notification speech announces sender, SMS excerpts and verification codes',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final events = MethodChannel(RobotInteraction.events.name);
      String? verification = '短信\n验证码：482096，订单号 997766。';
      final utterances = <String>[];
      messenger.setMockMethodCallHandler(RobotInteraction.bridge, (call) async {
        switch (call.method) {
          case 'capabilities':
            return {'speech': true};
          case 'notificationDetails':
            return verification;
          case 'speak':
            utterances.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
      messenger.setMockMethodCallHandler(events, (_) async => null);
      addTearDown(() {
        messenger.setMockMethodCallHandler(RobotInteraction.bridge, null);
        messenger.setMockMethodCallHandler(events, null);
      });
      final interaction = RobotInteraction(RemoteClient(), () => null);
      addTearDown(interaction.dispose);
      final initialization = interaction.initialize();
      await tester.pump();
      await initialization;
      interaction.setReadNotices(true);

      Future<void> send(Map<String, Object> event) async {
        await messenger.handlePlatformMessage(
          events.name,
          const StandardMethodCodec().encodeSuccessEnvelope(event),
          (_) {},
        );
        await tester.pump();
      }

      Future<void> notice(String id, Map<String, Object> fields) async {
        await send({'type': 'notification', 'id': id, 'app': '微信', ...fields});
        await tester.pump(const Duration(milliseconds: 1500));
        await tester.pump();
      }

      await notice('ordinary', {'sender': '小明', 'text': '晚上见！'});
      expect(utterances.last, '小明在微信对你说：晚上见！');
      await send({'type': 'speechDone'});
      await notice('empty', {'sender': '小明'});
      expect(utterances.last, '小明在微信给你发消息了。');
      await send({'type': 'speechDone'});
      final opening = '短信内容' * 12 + '短信';
      await notice('sms', {
        'app': '信息',
        'sender': '快递',
        'sms': true,
        'text': '$opening这一段不播报',
      });
      expect(utterances.last, '收到来自快递的短信，内容是：$opening，后面还有内容。');
      await send({'type': 'speechDone'});
      await notice('code', {'verification': true});
      expect(utterances.last, '收到验证码为，4 8 2 0 9 6。');
      expect(interaction.recentNotices.first.text, isEmpty);
      await send({'type': 'speechDone'});
      verification = null;
      await notice('hidden-code', {'verification': true});
      expect(utterances.last, '收到一条验证消息。');
    },
  );

  testWidgets('the conversation speaker is in the app bar and persists', (
    tester,
  ) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    final events = MethodChannel(RobotInteraction.events.name);
    String? saved;
    messenger.setMockMethodCallHandler(RobotInteraction.bridge, (call) async {
      if (call.method == 'capabilities') return {'speech': true};
      if (call.method == 'loadSettings') return saved;
      if (call.method == 'saveSettings') saved = call.arguments as String;
      return null;
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(RobotInteraction.bridge, null);
      messenger.setMockMethodCallHandler(events, null);
    });
    final interaction = RobotInteraction(RemoteClient(), () => null);
    addTearDown(interaction.dispose);
    await interaction.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return TextButton(
              onPressed: () => openConversation(context, interaction),
              child: const Text('打开对话'),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('打开对话'));
    await tester.pumpAndSettle();
    final speaker = find.descendant(
      of: find.byType(AppBar),
      matching: find.byTooltip('关闭自动朗读'),
    );
    expect(speaker, findsOneWidget);
    await tester.tap(speaker);
    await tester.pump();
    expect(find.byTooltip('开启自动朗读'), findsOneWidget);
    expect(jsonDecode(saved!)['readAnswers'], isFalse);

    final restarted = RobotInteraction(RemoteClient(), () => null);
    addTearDown(restarted.dispose);
    await restarted.initialize();
    expect(restarted.readAnswers, isFalse);
  });

  testWidgets('notice signal animates in and dismisses', (tester) async {
    final interaction = RobotInteraction(RemoteClient(), () => null);
    addTearDown(interaction.dispose);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: NoticeSignal(interaction))),
    );
    interaction.notice = (
      source: '测试应用',
      title: '首页新通知',
      text: '测试正文',
      verification: false,
      id: 'test',
      eventKey: 'test:1',
      packageName: null,
    );
    interaction.notifyListeners();
    await tester.pump();
    final title = find.text('首页新通知');
    await tester.pump(const Duration(milliseconds: 100));
    final fade = find.ancestor(
      of: title,
      matching: find.byType(FadeTransition),
    );
    expect(
      tester.widget<FadeTransition>(fade.first).opacity.value,
      inExclusiveRange(0, 1),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<FadeTransition>(fade.first).opacity.value, 1);
    interaction.clearNotice();
    await tester.pumpAndSettle();
    expect(title, findsNothing);
  });

  testWidgets('consecutive notices share a card, speech and paused expiry', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final events = MethodChannel(RobotInteraction.events.name);
    final spoken = <String>[];
    messenger.setMockMethodCallHandler(RobotInteraction.bridge, (call) async {
      if (call.method == 'speak') {
        spoken.add((call.arguments as Map)['text'] as String);
      }
      return switch (call.method) {
        'capabilities' => {'notifications': true, 'speech': true},
        'notificationAccess' => true,
        _ => null,
      };
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(RobotInteraction.bridge, null);
      messenger.setMockMethodCallHandler(events, null);
    });
    final interaction = RobotInteraction(RemoteClient(), () => null);
    addTearDown(interaction.dispose);
    final pending = interaction.initialize();
    await tester.pump();
    await pending;
    interaction.readNotices = true;
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: NoticeSignal(interaction))),
    );

    Future<void> emit(String package, String title, String body) =>
        messenger.handlePlatformMessage(
          events.name,
          const StandardMethodCodec().encodeSuccessEnvelope({
            'type': 'notification',
            'app': package == 'chat.app' ? '聊天应用' : '其他应用',
            'package': package,
            'id': title,
            'title': title,
            'text': body,
          }),
          (_) {},
        );

    await emit('chat.app', '第一条标题', '第一条正文');
    await tester.pump(const Duration(milliseconds: 250));
    await emit('chat.app', '第二条标题', '第二条正文');
    await tester.pumpAndSettle();

    expect(interaction.noticeQueue.groups.single.items, hasLength(2));
    expect(find.text('2 条'), findsOneWidget);
    expect(find.text('第一条标题'), findsNothing);
    expect(find.text('第二条标题'), findsOneWidget);
    expect(spoken, isEmpty);

    await tester.pump(const Duration(milliseconds: 1500));
    expect(spoken, ['聊天应用有2条新消息。第一条正文。第二条正文']);
    await emit('other.app', '另一应用通知', '其他应用正文');
    await tester.pumpAndSettle();
    expect(interaction.noticeQueue.groups, hasLength(2));

    await tester.tap(find.text('第二条标题'));
    await tester.pumpAndSettle();
    expect(find.text('第一条标题'), findsOneWidget);
    expect(find.text('第一条正文'), findsOneWidget);
    await tester.pump(const Duration(seconds: 12));
    expect(interaction.noticeQueue.groups, hasLength(2));

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('第一条标题'), findsNothing);
    expect(find.text('另一应用通知'), findsOneWidget);
    await tester.pump(const Duration(seconds: 9));
    await tester.pumpAndSettle();
    expect(interaction.noticeQueue.groups, isEmpty);
  });

  testWidgets('notice stack scrolls only when the cards exceed its height', (
    tester,
  ) async {
    final interaction = RobotInteraction(RemoteClient(), () => null);
    addTearDown(interaction.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomRight,
            child: SizedBox(
              width: 270,
              height: 180,
              child: NoticeSignal(interaction),
            ),
          ),
        ),
      ),
    );

    void add(int number) => interaction.noticeQueue.add((
      source: '测试应用',
      title: '提醒 $number',
      text: '通知正文',
      verification: false,
      id: '$number',
      eventKey: '$number:1',
      packageName: null,
    ));

    add(1);
    await tester.pumpAndSettle();
    final list = find.byType(Scrollable);
    final position = tester.state<ScrollableState>(list).position;
    expect(position.maxScrollExtent, 0);
    final first = find.text('提醒 1');
    final firstBaseline = tester.getTopLeft(first).dy;
    add(2);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(first).dy, lessThan(firstBaseline));
    for (var number = 3; number <= 7; number++) {
      add(number);
    }
    await tester.pumpAndSettle();
    expect(interaction.noticeQueue.groups, hasLength(7));
    expect(position.maxScrollExtent, greaterThan(0));
    expect(find.text('提醒 7').hitTestable(), findsOneWidget);
    await tester.drag(list, const Offset(0, 380));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
    expect(first.hitTestable(), findsOneWidget);
    await tester.pump(const Duration(seconds: 9));
    await tester.pumpAndSettle();
    expect(interaction.noticeQueue.groups, isEmpty);
  });

  testWidgets('swiping the middle notice lowers only the cards above it', (
    tester,
  ) async {
    final interaction = RobotInteraction(RemoteClient(), () => null);
    addTearDown(interaction.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomRight,
            child: SizedBox(width: 270, child: NoticeSignal(interaction)),
          ),
        ),
      ),
    );

    for (var i = 1; i <= 3; i++) {
      interaction.noticeQueue.add((
        source: '测试应用',
        title: '提醒 $i',
        text: '通知正文',
        verification: false,
        id: '$i',
        eventKey: '$i:1',
        packageName: null,
      ));
    }
    await tester.pumpAndSettle();
    final top = find.text('提醒 1');
    final middle = find.text('提醒 2');
    final bottom = find.text('提醒 3');
    final topPosition = tester.getTopLeft(top).dy;
    final middlePosition = tester.getTopLeft(middle).dy;
    final bottomPosition = tester.getTopLeft(bottom).dy;

    await tester.drag(middle, const Offset(-330, 0));
    await tester.pumpAndSettle();
    expect(middle, findsOneWidget);

    await tester.drag(middle, const Offset(330, 0));
    await tester.pump();
    final positions = <double>[];
    for (var frame = 0; frame < 22; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      positions.add(tester.getTopLeft(top).dy);
      expect(tester.getTopLeft(bottom).dy, closeTo(bottomPosition, .01));
    }
    expect(
      positions.any((y) => y > topPosition && y < middlePosition),
      isTrue,
      reason: '$positions',
    );

    await tester.pumpAndSettle();
    expect(middle, findsNothing);
    expect(tester.getTopLeft(top).dy, closeTo(middlePosition, .01));
    expect(tester.getTopLeft(bottom).dy, closeTo(bottomPosition, .01));
  });

  testWidgets(
    'verification notice opens directly to just the code when available',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final events = MethodChannel(RobotInteraction.events.name);
      String? message = '短信\n【服务】验证码：482096，订单号 997766。';
      var requests = 0;
      messenger.setMockMethodCallHandler(RobotInteraction.bridge, (call) async {
        if (call.method == 'notificationDetails') {
          requests++;
          return message;
        }
        return call.method == 'capabilities' ? <String, Object>{} : null;
      });
      messenger.setMockMethodCallHandler(events, (_) async => null);
      addTearDown(() {
        messenger.setMockMethodCallHandler(RobotInteraction.bridge, null);
        messenger.setMockMethodCallHandler(events, null);
      });
      final interaction = RobotInteraction(RemoteClient(), () => null);
      addTearDown(interaction.dispose);
      await interaction.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(width: 280, child: NoticeSignal(interaction)),
            ),
          ),
        ),
      );
      interaction.notice = (
        source: '短信',
        title: '收到验证消息',
        text: '',
        verification: true,
        id: 'verification',
        eventKey: 'verification:1',
        packageName: null,
      );
      interaction.notifyListeners();
      await tester.pumpAndSettle();
      expect(requests, 0);
      await tester.tap(find.text('收到验证消息'));
      await tester.pump();
      expect(
        tester
            .widget<FadeTransition>(
              find
                  .ancestor(
                    of: find.byTooltip('关闭'),
                    matching: find.byType(FadeTransition),
                  )
                  .first,
            )
            .opacity
            .value,
        0,
      );
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(find.text('482096'), findsOneWidget);
      expect(find.textContaining('订单号'), findsNothing);
      expect(find.text('查看验证内容'), findsNothing);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(find.text('收到验证消息'), findsOneWidget);
      message = 'Service\nA12B34 is your Example verification code.';
      expect(await interaction.noticeCode(interaction.notice!), 'A12B34');
      message = '短信\n验证码：******，订单号 997766。';
      expect(await interaction.noticeCode(interaction.notice!), isNull);
      message = null;
      await tester.tap(find.text('收到验证消息'));
      await tester.pumpAndSettle();
      expect(find.text('验证码不可用'), findsOneWidget);
    },
  );

  testWidgets('opening the source app closes the expanded notice', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <Object?>[];
    messenger.setMockMethodCallHandler(RobotInteraction.bridge, (call) async {
      if (call.method == 'openNoticeApp') {
        calls.add(call.arguments);
        return calls.length == 1 ? 'permission' : 'opened';
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(RobotInteraction.bridge, null),
    );
    final interaction = RobotInteraction(RemoteClient(), () => null);
    addTearDown(interaction.dispose);
    final initialization = interaction.initialize();
    await tester.pump();
    await initialization;
    interaction.notice = (
      source: '测试应用',
      title: '新提醒',
      text: '通知内容',
      verification: false,
      id: 'test-notice',
      eventKey: 'test:1',
      packageName: 'test.app',
    );
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: NoticeSignal(interaction))),
    );
    await tester.tap(find.text('新提醒'));
    await tester.pumpAndSettle();

    expect(find.text('问 AI'), findsNothing);
    await tester.tap(find.text('打开 App'));
    await tester.pumpAndSettle();
    expect(find.text('开启贴边返回便签'), findsOneWidget);
    await tester.tap(find.text('直接打开'));
    await tester.pumpAndSettle();

    expect(calls, [
      {'id': 'test-notice', 'package': 'test.app', 'withShortcut': true},
      {'id': 'test-notice', 'package': 'test.app', 'withShortcut': false},
    ]);
    expect(find.byTooltip('关闭'), findsNothing);
    expect(find.text('新提醒'), findsNothing);
    expect(interaction.notice, isNull);
  });

  testWidgets('long notice stays scrollable with large text in landscape', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 375);
    addTearDown(tester.view.reset);
    final interaction = RobotInteraction(RemoteClient(), () => null);
    addTearDown(interaction.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData.fromView(tester.view).copyWith(
            disableAnimations: true,
            textScaler: const TextScaler.linear(2),
          ),
          child: Scaffold(body: NoticeSignal(interaction)),
        ),
      ),
    );
    interaction.notice = (
      source: '短信',
      title: '长通知',
      text: List.filled(15, '这是一条需要滚动才能读完的提醒。').join('\n'),
      verification: false,
      id: null,
      eventKey: 'long:1',
      packageName: null,
    );
    interaction.notifyListeners();
    await tester.pumpAndSettle();
    await tester.tap(find.text('长通知'));
    await tester.pumpAndSettle();
    final action = find.text('问 AI');
    await tester.ensureVisible(action);
    await tester.pumpAndSettle();
    expect(action.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(find.text('AI 对话'), findsOneWidget);
    expect(interaction.draft, interaction.notice?.text);
  });

  testWidgets('chat opens as a page with reasoning collapsed', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final interaction = RobotInteraction(_Desktop(), () => null);
    addTearDown(interaction.dispose);
    interaction.configureModel(
      ModelSource.local,
      PhoneModel(ModelSource.local, 'http://127.0.0.1:8080/v1', 'test', ''),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => openConversation(context, interaction),
            child: const Text('说话'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('说话'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'AI 对话'), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);

    final composer = find.byType(TextField);
    final send = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '发送',
    );
    expect(tester.widget<IconButton>(send).onPressed, isNull);
    await tester.enterText(composer, '你好');
    await tester.pump();
    expect(tester.getBottomLeft(send).dy, greaterThan(770));
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(find.text('直连回复。', findRichText: true), findsOneWidget);
    expect(find.text('单独返回的推理标签里的推理'), findsNothing);
    await tester.tap(find.text('思考过程'));
    await tester.pumpAndSettle();
    expect(find.text('单独返回的推理标签里的推理'), findsOneWidget);
    expect(find.byTooltip('复制回复'), findsOneWidget);
    await tester.tap(find.byTooltip('新对话'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '新对话'));
    await tester.pumpAndSettle();
    expect(find.text('想聊点什么？'), findsOneWidget);
    expect(find.text('直连回复。', findRichText: true), findsNothing);
    tester.view.physicalSize = const Size(844, 390);
    tester.view.viewInsets = const FakeViewPadding(bottom: 200);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('stopping a reply removes only its reasoning card', (
    tester,
  ) async {
    final desktop = _Desktop();
    final pairing = Pairing.parse(
      '{"url":"https://desk.example.ts.net","token":"${'a' * 43}"}',
    );
    final interaction = RobotInteraction(desktop, () => pairing);
    addTearDown(interaction.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => openConversation(context, interaction),
            child: const Text('打开对话'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开对话'));
    await tester.pumpAndSettle();
    await interaction.send('第一轮');
    desktop.answers.single
      ..add((text: '第一轮思考', thinking: true))
      ..add((text: '第一轮回复', thinking: false));
    unawaited(desktop.answers.single.close());
    await tester.pumpAndSettle();

    await interaction.send('第二轮');
    desktop.answers.last
      ..add((text: '第二轮思考', thinking: true))
      ..add((text: '已输出的正文', thinking: false));
    await tester.pump();
    expect(find.text('思考过程'), findsNWidgets(2));

    await tester.tap(find.byTooltip('停止回答'));
    await tester.pumpAndSettle();
    expect(find.text('思考过程'), findsOneWidget);
    expect(find.text('已输出的正文', findRichText: true), findsOneWidget);
    expect(interaction.draft, '第二轮');
    unawaited(desktop.answers.last.close());
    await tester.pump();
  });

  testWidgets(
    'compact replies show the newest stream text without a tap action',
    (tester) async {
      final interaction = RobotInteraction(_Desktop(), () => null);
      addTearDown(interaction.dispose);
      interaction.phase = InteractionPhase.thinking;
      interaction.question = '介绍一下机器人';
      interaction.replyModel = '桌面测试模型';
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 280,
              child: ListenableBuilder(
                listenable: interaction,
                builder: (_, _) => ReplyPreview(interaction),
              ),
            ),
          ),
        ),
      );
      expect(find.text('等待回复'), findsOneWidget);
      interaction.phase = InteractionPhase.answering;
      interaction.reply = '${'这是一段正在流式接收的回复。' * 16}最后一句。';
      interaction.notifyListeners();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('接收中'), findsOneWidget);
      expect(find.textContaining('最后一句。'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ReplyPreview),
          matching: find.byType(InkWell),
        ),
        findsNothing,
      );
      interaction.phase = InteractionPhase.idle;
      interaction.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('接收中'), findsNothing);
    },
  );

  test(
    'a followed app notification received in background is shown on resume',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final channel = MethodChannel(RobotInteraction.events.name);
      String? savedNotices;
      messenger.setMockMethodCallHandler(RobotInteraction.bridge, (call) async {
        if (call.method == 'saveRecentNotices') {
          savedNotices = call.arguments as String;
          return null;
        }
        return switch (call.method) {
          'capabilities' => {'notifications': true},
          'notificationAccess' => true,
          'loadRecentNotices' => savedNotices,
          _ => null,
        };
      });
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      addTearDown(() {
        messenger.setMockMethodCallHandler(RobotInteraction.bridge, null);
        messenger.setMockMethodCallHandler(channel, null);
      });
      final interaction = RobotInteraction(RemoteClient(), () => null);
      addTearDown(interaction.dispose);
      await interaction.initialize();

      Future<void> emit(
        String package,
        String title, {
        String? id,
        String? sender,
        bool verification = false,
        bool? matchesNoticeRules,
      }) => messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'type': 'notification',
          'app': package,
          'package': package,
          'id': id ?? package,
          'sender': sender ?? '',
          'title': title,
          'verification': verification,
          'matchesNoticeRules': ?matchesNoticeRules,
        }),
        (_) {},
      );
      await emit('sms.app', '默认接收短信');
      await emit('other.app', '默认接收其他应用');
      expect(interaction.recentNotices.map((item) => item.title), [
        '默认接收其他应用',
        '默认接收短信',
      ]);

      interaction.saveNoticeChoices(const [
        NoticeChoice('followed.app', '关注应用'),
      ], contacts: false);
      interaction.saveKeywords(['匹配词']);
      interaction.clearNotice();
      interaction.pause();

      await emit('followed.app', '新通知');
      await emit('unfollowed.app', '忽略此通知');
      expect(interaction.notice, isNull);
      expect(interaction.recentNotices.first.title, '新通知');
      expect(interaction.recentNotices.length, 3);

      await interaction.resume();
      expect(interaction.notice?.title, '新通知');

      await emit('another.app', '含匹配词的提醒', id: 'matching');
      expect(interaction.recentNotices.first.title, '含匹配词的提醒');
      interaction.saveNoticeChoices(const [
        NoticeChoice('contact', '测试联系人'),
      ], contacts: true);
      await emit('another.app', '联系人提醒', id: 'contact', sender: '测试联系人');
      expect(interaction.recentNotices.first.title, '联系人提醒');

      final reopened = RobotInteraction(RemoteClient(), () => null);
      addTearDown(reopened.dispose);
      await reopened.initialize();
      expect(reopened.recentNotices.first.title, '联系人提醒');
      expect(reopened.recentNotices.length, 5);
      expect(reopened.notice, isNull);

      reopened.saveKeywords(['验证码']);
      await emit(
        'sms.app',
        '收到验证消息',
        id: 'unmatched-verification',
        verification: true,
        matchesNoticeRules: false,
      );
      expect(reopened.notice, isNull);
      await emit(
        'sms.app',
        '收到验证消息',
        id: 'matched-verification',
        verification: true,
        matchesNoticeRules: true,
      );
      expect(reopened.notice?.title, '收到验证消息');
      expect(reopened.notice?.text, isEmpty);
      expect(reopened.recentNotices.first.verification, isTrue);
    },
  );

  test(
    'recording waits for the final transcript before sending once',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final methods = <String>[];
      messenger.setMockMethodCallHandler(RobotInteraction.bridge, (call) async {
        methods.add(call.method);
        if (call.method == 'capabilities') return {'speech': true};
        return null;
      });
      const eventChannel = MethodChannel('com.reareyes/interactionEvents');
      messenger.setMockMethodCallHandler(eventChannel, (_) async => null);
      addTearDown(() {
        messenger.setMockMethodCallHandler(RobotInteraction.bridge, null);
        messenger.setMockMethodCallHandler(eventChannel, null);
      });
      final desktop = _Desktop();
      final pairing = Pairing.parse(
        '{"url":"https://desk.example.ts.net","token":"${'a' * 43}"}',
      );
      final interaction = RobotInteraction(desktop, () => pairing);
      addTearDown(interaction.dispose);
      await interaction.initialize();

      Future<void> emit(Map<String, Object> event) async {
        await messenger.handlePlatformMessage(
          eventChannel.name,
          const StandardMethodCodec().encodeSuccessEnvelope(event),
          (_) {},
        );
      }

      interaction.setDraft('原来草稿');
      await interaction.startRecording(sendAfter: true);
      await emit({'type': 'speech', 'text': '短暂录音', 'final': false});
      expect(interaction.draft, isEmpty);
      await emit({'type': 'speech', 'text': '短暂录音', 'final': true});
      expect(interaction.draft, '原来草稿');
      expect(interaction.error, isNull);
      expect(desktop.requests, isEmpty);

      await interaction.startRecording();
      await Future<void>.delayed(const Duration(milliseconds: 650));
      await emit({'type': 'speechLevel', 'level': .75});
      expect(interaction.inputLevel, .75);
      await emit({'type': 'speech', 'text': '你好', 'final': false});
      await interaction.send();
      expect(
        methods.where((method) => method == 'stopListening'),
        hasLength(1),
      );
      expect(desktop.requests, isEmpty);
      await emit({'type': 'speech', 'text': '你好，世界', 'final': true});
      await emit({'type': 'speechEnd'});
      await Future<void>.delayed(Duration.zero);
      expect(interaction.question, '你好，世界');
      expect(desktop.requests, hasLength(1));
      desktop.answers.single.add((text: '你好。', thinking: false));
      await desktop.answers.single.close();
    },
  );

  testWidgets('model errors disappear while the question remains retryable', (
    tester,
  ) async {
    final desktop = _Desktop();
    final pairing = Pairing.parse(
      '{"url":"https://desk.example.ts.net","token":"${'a' * 43}"}',
    );
    final interaction = RobotInteraction(desktop, () => pairing);
    addTearDown(interaction.dispose);
    await interaction.fetchModels();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: interaction,
            builder: (_, _) => DeskVoiceControl(
              interaction,
              onPressed: interaction.send,
            ),
          ),
        ),
      ),
    );

    await interaction.send('原始问题');
    const message = '模型未返回可显示的文字。';
    desktop.answers.single.addError(const FormatException(message));
    await tester.pump();
    expect(find.text(message), findsOneWidget);
    expect(find.byTooltip('重试'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    expect(find.text(message), findsNothing);
    expect(find.byTooltip('重试'), findsOneWidget);
    expect(interaction.draft, '原始问题');

    await tester.tap(find.byTooltip('重试'));
    await tester.pump();
    expect(desktop.requests, hasLength(2));
    await desktop.answers.last.close();
    await tester.pump();
    expect(interaction.error, '模型没有返回内容。');
    await tester.pump(const Duration(seconds: 4));
    expect(interaction.error, isNull);
    expect(interaction.canRetryReply, isTrue);
  });

  test('model output streams and cancellation retains the question', () async {
    final desktop = _Desktop();
    final pairing = Pairing.parse(
      '{"url":"https://desk.example.ts.net","token":"${'a' * 43}"}',
    );
    final interaction = RobotInteraction(desktop, () => pairing);
    addTearDown(interaction.dispose);
    await interaction.fetchModels();
    interaction.setDraft('你好');
    await interaction.send();
    expect(interaction.phase, InteractionPhase.thinking);
    desktop.answers.single.add((text: '你好。', thinking: false));
    await Future<void>.delayed(Duration.zero);
    expect(interaction.phase, InteractionPhase.answering);
    expect(interaction.reply, '你好。');

    await interaction.cancelAnswer();
    expect(desktop.cancelled, desktop.requests);
    expect(interaction.draft, '你好');
    expect(interaction.phase, InteractionPhase.idle);
    await desktop.answers.single.close();

    desktop.useCloudDefault = true;
    await interaction.send();
    expect(interaction.replyModel, '云端模型');
    desktop.answers.last.add((text: '新回复。', thinking: false));
    await desktop.answers.last.close();
    expect(interaction.reply, '新回复。');
    expect(interaction.phase, InteractionPhase.idle);
  });

  test(
    'desktop model streams and cancels over LAN without Tailscale',
    () async {
      final desktop = _Desktop();
      final lan = Pairing.readLan(
        '{"url":"http://192.168.1.20:18794",'
        '"token":"e48040cb-83cd-4c2f-89e1-3d14f360729c"}',
      )!;
      final interaction = RobotInteraction(
        desktop,
        () => null,
        lanPairing: () => lan,
      );
      addTearDown(interaction.dispose);

      interaction.setDraft('局域网测试');
      await interaction.send();
      expect(desktop.requestConnections, [lan]);
      desktop.answers.single.add((text: '局域网回复。', thinking: false));
      await Future<void>.delayed(Duration.zero);
      expect(interaction.reply, '局域网回复。');
      await interaction.cancelAnswer();
      expect(desktop.cancelConnections, [lan]);
      expect(desktop.cancelled, desktop.requests);
      expect(interaction.canSyncPhoneModel, isFalse);
      await desktop.answers.single.close();
    },
  );

  test(
    'standalone cloud profiles can be saved and switched without a pairing',
    () async {
      final interaction = RobotInteraction(_Desktop(), () => null);
      addTearDown(interaction.dispose);
      final profile = PhoneModel(
        ModelSource.cloud,
        'https://cloud.example/v1',
        'test-model',
        '',
      );
      expect(profile.endpoint.path, '/v1/chat/completions');
      interaction.configureModel(ModelSource.cloud, profile);
      interaction.configureModel(
        ModelSource.cloud,
        PhoneModel(
          ModelSource.cloud,
          'https://second.example/v1',
          'second-model',
          '',
        ),
      );
      expect(interaction.cloudProfiles.map((item) => item.model), [
        'second-model',
        'test-model',
      ]);
      interaction.configureModel(ModelSource.cloud, profile);
      await interaction.send('你好');
      await Future<void>.delayed(Duration.zero);
      expect(interaction.reply, '直连回复。');
      expect(interaction.reasoning, '单独返回的推理标签里的推理');
    },
  );

  test('local file profiles keep the file reference and report an unavailable GGUF', () async {
    final folder = await Directory.systemTemp.createTemp('robot-eyes-gguf-');
    addTearDown(() => folder.delete(recursive: true));
    final file = '${folder.path}/missing.gguf';
    final profile = PhoneModel.file(file, '本机对话');
    final restored = PhoneModel.fromJson(profile.toJson())!;
    expect(restored.localPath, file);
    expect(restored.source, ModelSource.local);
    expect(restored.toJson(), isNot(contains('url')));
    await expectLater(
      RemoteClient().directChat(restored, [
        {'role': 'user', 'content': '你好'},
      ]),
      emitsError(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('GGUF'),
        ),
      ),
    );
    expect(
      PhoneModel.fromJson({
        'source': 'lan',
        'url': 'http://192.168.1.10/v1',
        'model': 'old',
        'key': '',
      }),
      isNull,
    );
  });

  test('long reasoning preview still allows the answer through', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await request.drain<void>();
      final frames = [
        {'choices': [{'delta': {'reasoning': 'a' * 50000}}]},
        {'choices': [{'delta': {'content': '正式回答'}}]},
      ];
      request.response.add(
        utf8.encode(
          frames.map((frame) => 'data: ${jsonEncode(frame)}').join('\n') +
              '\ndata: [DONE]\n',
        ),
      );
      await request.response.close();
    });
    final profile = PhoneModel(
      ModelSource.local,
      'http://127.0.0.1:${server.port}/v1',
      'fixture',
      '',
    );
    final chunks = await HttpOverrides.runWithHttpOverrides(
      () => RemoteClient().directChat(profile, [
        {'role': 'user', 'content': '测试'},
      ]).toList(),
      _LoopbackHttpOverrides(),
    );
    expect(chunks.first.text.length, 48000);
    expect(chunks.last, (text: '正式回答', thinking: false));
  });

  test('phone model streams a reply from a loopback service', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requestCaptured = Completer<Map<String, Object?>>();
    server.listen((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      requestCaptured.complete({
        'path': request.uri.path,
        'model': body['model'],
        'authorization': request.headers.value('authorization'),
      });
      request.response
        ..headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        )
        ..add(
          utf8.encode(
            'data: {"choices":[{"delta":{"content":"收到"}}]}\n\n'
            'data: [DONE]\n\n',
          ),
        );
      await request.response.close();
    });
    final profile = PhoneModel(
      ModelSource.local,
      'http://127.0.0.1:${server.port}/v1',
      'robot-test',
      '',
    );
    final reply = await HttpOverrides.runWithHttpOverrides(
      () => RemoteClient()
          .directChat(profile, [
            {'role': 'user', 'content': '测试'},
          ])
          .map((chunk) => chunk.text)
          .join(),
      _LoopbackHttpOverrides(),
    );
    expect(reply, '收到');
    expect(await requestCaptured.future, {
      'path': '/v1/chat/completions',
      'model': 'robot-test',
      'authorization': null,
    });
  });
}
