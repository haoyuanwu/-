import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rear_eyes_mobile/chat_reasoning.dart';
import 'package:rear_eyes_mobile/interaction.dart';
import 'package:rear_eyes_mobile/interaction_view.dart';
import 'package:rear_eyes_mobile/phone_model.dart';
import 'package:rear_eyes_mobile/remote.dart';

class _LoopbackHttpOverrides extends HttpOverrides {}

class _Desktop extends RemoteClient {
  final answers = <StreamController<ChatChunk>>[];
  final requests = <String>[];
  final cancelled = <String>[];
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
    final answer = StreamController<ChatChunk>();
    answers.add(answer);
    return answer.stream;
  }

  @override
  Future<void> cancelChat(Pairing pairing, String requestId) async {
    cancelled.add(requestId);
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
  TestWidgetsFlutterBinding.ensureInitialized();

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
    final during = tester.getTopLeft(title).dy;
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(title).dy, lessThan(during));
    interaction.clearNotice();
    await tester.pumpAndSettle();
    expect(title, findsNothing);
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
      }) => messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'type': 'notification',
          'app': package,
          'package': package,
          'id': id ?? package,
          'sender': sender ?? '',
          'title': title,
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
      await interaction.startRecording();

      Future<void> emit(Map<String, Object> event) async {
        await messenger.handlePlatformMessage(
          eventChannel.name,
          const StandardMethodCodec().encodeSuccessEnvelope(event),
          (_) {},
        );
      }

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

  test('a LAN model sends without a desktop pairing', () async {
    final interaction = RobotInteraction(_Desktop(), () => null);
    addTearDown(interaction.dispose);
    final profile = PhoneModel(
      ModelSource.lan,
      'http://192.168.1.8:11434/v1',
      'test-model',
      '',
    );
    expect(profile.endpoint.path, '/v1/chat/completions');
    interaction.configureModel(ModelSource.lan, profile);
    await interaction.send('你好');
    await Future<void>.delayed(Duration.zero);
    expect(interaction.reply, '直连回复。');
    expect(interaction.reasoning, '单独返回的推理标签里的推理');
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
