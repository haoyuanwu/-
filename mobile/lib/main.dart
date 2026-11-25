import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
// Keep the Flutter SDK Material import for compatibility with stable Flutter.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'design.dart';
import 'desk_voice_feedback.dart';
import 'eye_scene.dart';
import 'interaction.dart';
import 'interaction_view.dart';
import 'model_settings_view.dart';
import 'remote.dart';
import 'status_strip.dart';
import 'platform_io.dart'
    if (dart.library.js_interop) 'platform_web.dart'
    as platform;

const native = MethodChannel('com.reareyes/mobile');
final android = platform.isAndroid;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RearEyesMobile());
}

class RearEyesMobile extends StatelessWidget {
  const RearEyesMobile({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Robot Eyes',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: backdrop,
      colorScheme: const ColorScheme.dark(
        surface: panelColor,
        onSurface: primaryInk,
        primary: cyan,
        secondary: violet,
        error: Color(0xffff93aa),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    ),
    home: const HomePage(),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final client = RemoteClient();
  late final interaction = RobotInteraction(client, () => pairing);
  final scene = ValueNotifier<(EyeMood, int)>((EyeMood.idle, 0));
  final telemetry = ValueNotifier(Snapshot());
  late final Timer timer;
  Snapshot snapshot = Snapshot();
  Pairing? pairing;
  EyeMood? preview;
  int revision = 0;
  int sleepSeconds = 90;
  Timer? previewTimer;
  String? syncTicket;
  String? failure;
  String? syncResult;
  bool syncing = false;
  Future<void>? pendingRefresh;
  final localLogs = <String>[];
  bool foreground = true;
  int nextRemoteAt = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    interaction.addListener(_updateScene);
    unawaited(interaction.initialize());
    timer = Timer.periodic(const Duration(seconds: 1), (_) => refresh());
    unawaited(load());
  }

  Future<void> load() async {
    try {
      final raw = await platform.loadPairing();
      if (raw != null && mounted) setState(() => pairing = Pairing.parse(raw));
    } catch (_) {
      if (mounted) setState(() => failure = '无法读取配对配置。');
    }
    try {
      final sleep = await platform.sleepSetting();
      if (mounted && sleep != null) setState(() => sleepSeconds = sleep);
    } catch (_) {
      // Keep the default if browser storage or platform preferences are unavailable.
    }
    await refresh(force: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (foreground) {
      unawaited(refresh(force: true));
      unawaited(interaction.resume());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      interaction.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    timer.cancel();
    previewTimer?.cancel();
    interaction.removeListener(_updateScene);
    interaction.dispose();
    scene.dispose();
    telemetry.dispose();
    super.dispose();
  }

  void _updateScene() {
    final mood = interaction.mood ?? preview ?? snapshot.state;
    if (scene.value.$1 != mood) scene.value = (mood, ++revision);
    interaction.updateActivity(
      interaction.generating ? EyeMood.thinking : snapshot.state,
    );
  }

  Future<void> refresh({bool force = false}) async {
    if (!mounted || (!foreground && !force)) return;
    final pending = pendingRefresh;
    if (pending != null) {
      if (!force) return;
      await pending;
      return refresh(force: true);
    }
    final operation = _refresh(force: force);
    pendingRefresh = operation;
    try {
      await operation;
    } finally {
      pendingRefresh = null;
    }
  }

  void addLog(String text) {
    final now = DateTime.now();
    final timestamp = [
      now.hour,
      now.minute,
      now.second,
    ].map((part) => part.toString().padLeft(2, '0')).join(':');
    localLogs.add('$timestamp $text');
    if (localLogs.length > 40) localLogs.removeAt(0);
  }

  Future<void> _refresh({required bool force}) async {
    final saved = pairing;
    if (!android) {
      if (saved == null) return;
      final last = snapshot.updatedAt;
      if (snapshot.error != null &&
          last != null &&
          DateTime.now().difference(last) >= const Duration(seconds: 12) &&
          (snapshot.state != EyeMood.idle ||
              snapshot.links.isNotEmpty ||
              snapshot.five != null ||
              snapshot.week != null ||
              snapshot.agents.isNotEmpty)) {
        setState(() {
          snapshot = Snapshot(
            updatedAt: last,
            error: snapshot.error,
            remoteState: snapshot.remoteState,
          );
          telemetry.value = snapshot;
          _updateScene();
        });
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      if (!force && now < nextRemoteAt) return;
      nextRemoteAt = now + 4000;
    }
    try {
      final Snapshot next;
      if (android) {
        final json = await native.invokeMapMethod<Object?, Object?>('snapshot');
        if (json == null) return;
        next = Snapshot.read(json);
      } else {
        next = await client.fetch(saved!);
      }

      if (!mounted || saved != pairing) return;
      final manualSync = syncTicket != null && syncTicket == next.ticket;
      setState(() {
        if (!android) {
          if (!snapshot.links.contains('TAILSCALE')) addLog('Tailscale 已连接');
          if (snapshot.state != next.state) {
            addLog('电脑状态 · ${next.state.label}');
          }
        }
        failure = android ? next.error : null;
        if (android && next.nativePairing != pairing?.encode()) {
          final config = next.nativePairing;
          pairing = config == null ? null : Pairing.parse(config);
        }
        snapshot = next;
        telemetry.value = next;
        if (manualSync) {
          syncTicket = null;
          syncResult = syncSummary(next);
        }
        _updateScene();
      });
      if (saved?.encode() != pairing?.encode()) interaction.resetConnection();
    } catch (error) {
      if (!mounted || saved != pairing) return;
      setState(() {
        final message = android
            ? '无法读取 Android 同步状态。'
            : RemoteClient.describe(error);
        if (!android && message != failure) addLog(message);
        failure = message;
        if (!android) {
          snapshot = Snapshot(
            state: snapshot.state,
            five: snapshot.five,
            week: snapshot.week,
            agents: snapshot.agents,
            updatedAt: snapshot.updatedAt,
            remoteState: snapshot.remoteState,
            error: failure,
          );
          telemetry.value = snapshot;
        }
      });
    }
  }

  String syncSummary(Snapshot data) {
    final source = const {
      'USB': 'USB',
      'LAN': '局域网',
      'TAILSCALE': 'Tailscale',
    }[data.links.firstOrNull];
    return source == null ? '已同步' : '$source 已同步';
  }

  List<String> usageLabels(Snapshot data) => [
    if (data.fiveRemaining case final value?) '5 小时剩余 $value%',
    if (data.weekRemaining case final value?) '周剩余 $value%',
  ];

  Future<void> refreshNow() async {
    if (syncing) return;
    if (!android && pairing == null) {
      await remoteConnection();
      return;
    }
    setState(() {
      syncing = true;
      syncResult = null;
    });
    try {
      if (android) {
        syncTicket = await native.invokeMethod<String>('sync');
        final asked = syncTicket;
        for (
          var attempt = 0;
          attempt < 10 && mounted && syncTicket == asked;
          attempt++
        ) {
          await Future<void>.delayed(const Duration(seconds: 1));
          await refresh(force: true);
        }
        if (mounted && syncTicket != null) {
          setState(() {
            syncTicket = null;
            syncResult = '同步超时，请检查电脑上的 Robot Eyes 服务。';
          });
        }
      } else {
        await refresh(force: true);
        if (mounted) {
          setState(() => syncResult = failure ?? syncSummary(snapshot));
        }
      }
    } on PlatformException {
      if (mounted) setState(() => syncResult = '无法触发同步，请重试。');
    } finally {
      if (mounted) setState(() => syncing = false);
    }
  }

  Future<void> remoteConnection() async {
    final saved = pairing;
    if (saved == null) {
      await pair();
      return;
    }
    final action = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('远程连接'),
        content: ValueListenableBuilder(
          valueListenable: telemetry,
          builder: (_, data, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                saved.url.toString(),
                style: const TextStyle(color: cyan),
              ),
              const SizedBox(height: 8),
              Text(
                data.error ??
                    failure ??
                    (data.remoteState == null
                        ? '正在等待电脑响应…'
                        : '电脑状态 · ${data.remoteState!.label}'),
              ),
              if (data.updatedAt case final time?)
                Text('上次同步 ${TimeOfDay.fromDateTime(time).format(context)}'),
              TextButton(
                onPressed: () => remoteHelp(dialog),
                child: const Text('连接教程'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, 'pair'),
            child: const Text('管理配对'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, 'message'),
            child: const Text('发消息'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'pair') await pair();
    if (action == 'message') await message();
  }

  Future<void> remoteHelp(BuildContext context) => showDialog<void>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: const Text('Tailscale 远程连接教程'),
      content: const SingleChildScrollView(
        child: Text(
          '1. 在电脑和手机上打开 Tailscale，加入同一个网络。在电脑上启动 Robot Eyes。\n\n'
          '2. 在电脑 Robot Eyes 的「Tailscale 连接」点「重新检测」。如果没有地址，复制命令到电脑终端运行，再检测一次。\n\n'
          '3. 点「复制配对配置」，把整段 JSON 私下传到手机。\n\n'
          '4. 在「远程连接」粘贴并保存。已配对时，用「管理配对」更新配置。',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog),
          child: const Text('知道了'),
        ),
      ],
    ),
  );

  Future<void> pair() async {
    String raw = '';
    String? error;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, update) => AlertDialog(
          title: const Text('Tailscale 配对'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (pairing != null) ...[
                Text(pairing!.url.host, style: const TextStyle(color: cyan)),
                const SizedBox(height: 8),
              ],
              const Text('在电脑 Robot Eyes 复制配对配置。两端需加入同一个 Tailscale 网络。'),
              TextButton(
                onPressed: () => remoteHelp(dialogContext),
                child: const Text('连接教程'),
              ),
              const SizedBox(height: 8),
              TextField(
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: '粘贴配对配置',
                  errorText: error,
                ),
                onChanged: (value) => raw = value,
              ),
            ],
          ),
          actions: [
            if (pairing != null)
              TextButton(
                onPressed: () async {
                  if (await savePairing(null) && dialogContext.mounted) {
                    Navigator.pop(dialogContext);
                  }
                },
                child: const Text('解除配对'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  final value = Pairing.parse(raw);
                  if (await savePairing(value) && dialogContext.mounted) {
                    Navigator.pop(dialogContext);
                  }
                } on FormatException catch (failure) {
                  if (dialogContext.mounted) {
                    update(() => error = failure.message);
                  }
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> savePairing(Pairing? value) async {
    try {
      await platform.savePairing(value?.encode());
      if (!mounted) return false;
      setState(() {
        pairing = value;
        failure = null;
        syncResult = null;
        if (!android) {
          snapshot = Snapshot();
          addLog(value == null ? '已解除 Tailscale 配对' : '已保存 Tailscale 配对');
          telemetry.value = snapshot;
          _updateScene();
        }
      });
      interaction.resetConnection();
      unawaited(refresh(force: true));
      return true;
    } catch (_) {
      if (mounted) notice('无法保存配对配置');
      return false;
    }
  }

  Future<void> message() async {
    final saved = pairing;
    if (saved == null) {
      await pair();
      return;
    }
    String text = '';
    String id = '';
    String? previous;
    String? error;
    var sending = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, update) => AlertDialog(
          title: const Text('发消息到电脑'),
          content: TextField(
            autofocus: true,
            enabled: !sending,
            minLines: 3,
            maxLines: 5,
            maxLength: 2000,
            decoration: InputDecoration(labelText: '消息', errorText: error),
            onChanged: (value) => text = value,
          ),
          actions: [
            TextButton(
              onPressed: sending ? null : () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: sending
                  ? null
                  : () async {
                      final value = text.trim();
                      if (value.isEmpty) {
                        update(() => error = '请输入消息');
                        return;
                      }
                      if (value.length > 2000) {
                        update(() => error = '消息超过 2000 字符，请缩短后重试。');
                        return;
                      }
                      if (value != previous) {
                        id = RemoteClient.messageId();
                        previous = value;
                      }
                      update(() {
                        sending = true;
                        error = null;
                      });
                      try {
                        await client.send(saved, id, value);
                        if (dialogContext.mounted) Navigator.pop(dialogContext);
                        if (mounted) {
                          if (!android) setState(() => addLog('消息已送达电脑'));
                          notice('已送达电脑');
                        }
                      } catch (failure) {
                        if (dialogContext.mounted) {
                          update(() {
                            sending = false;
                            error = RemoteClient.describe(failure);
                          });
                        }
                      }
                    },
              child: Text(
                sending
                    ? '发送中…'
                    : error != null
                    ? '重试'
                    : '发送',
              ),
            ),
          ],
        ),
      ),
    );
  }

  void notice(String message) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));

  Future<void> play(EyeMood mood) async {
    if (android) {
      await native.invokeMethod<void>('preview', mood.wire);
      await refresh(force: true);
      return;
    }
    previewTimer?.cancel();
    setState(() {
      preview = mood;
      scene.value = (interaction.mood ?? mood, ++revision);
    });
    final duration = switch (mood) {
      EyeMood.idle || EyeMood.sleep => sleepSeconds,
      EyeMood.done || EyeMood.error || EyeMood.stopped => 30,
      _ => 5,
    };
    previewTimer = Timer(Duration(seconds: duration), () {
      if (mounted) {
        setState(() {
          preview = null;
          _updateScene();
        });
      }
    });
  }

  Future<void> fullscreen() async {
    await platform.keepScreenOn(true);
    try {
      if (!kIsWeb) {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      }
      if (mounted) {
        await Navigator.push<void>(
          context,
          MaterialPageRoute(
            builder: (_) => DeskPage(
              scene: scene,
              telemetry: telemetry,
              sleepSeconds: sleepSeconds,
              interaction: kIsWeb ? null : interaction,
            ),
          ),
        );
      }
    } finally {
      if (interaction.listening) await interaction.cancelRecording();
      if (!kIsWeb) {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        await SystemChrome.setPreferredOrientations([]);
      }
      await platform.keepScreenOn(false);
    }
  }

  Future<void> lan() async {
    final state = await native.invokeMapMethod<String, Object?>('lan');
    if (!mounted || state == null) return;
    final endpoints = (state['endpoints'] as List).cast<String>();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('局域网 MCP'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text(
              state['enabled'] == true
                  ? endpoints.isEmpty
                        ? '等待手机连接到局域网。'
                        : '选择手机地址，复制配置到桌面端。'
                  : '在可信局域网开启后，桌面端和 Agent 可以同步状态。',
            ),
          ),
          for (final endpoint in endpoints)
            SimpleDialogOption(
              onPressed: () async {
                try {
                  await native.invokeMethod<void>('copyLanConfig', endpoint);
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                  if (mounted) notice('已复制局域网配置');
                } on PlatformException catch (error) {
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                  if (mounted) notice(error.message ?? '无法复制局域网配置');
                }
              },
              child: Text(endpoint),
            ),
          SimpleDialogOption(
            onPressed: () async {
              Navigator.pop(dialogContext);
              await native.invokeMethod<Object?>(
                'lan',
                state['enabled'] != true,
              );
              if (mounted) await lan();
            },
            child: Text(
              state['enabled'] == true ? '关闭 MCP' : '开启 MCP',
              style: const TextStyle(color: cyan),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> sleepSettings() async {
    final seconds = await showDialog<int>(
      context: context,
      builder: (dialog) => SimpleDialog(
        title: const Text('待机多久后睡眠'),
        children: [
          for (final value in [30, 60, 90, 120, 300, 600])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialog, value),
              child: Row(
                children: [
                  Icon(
                    value == sleepSeconds
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: value == sleepSeconds ? cyan : secondaryInk,
                    size: 18,
                  ),
                  const SizedBox(width: 12),
                  Text(sleepLabel(value)),
                ],
              ),
            ),
        ],
      ),
    );
    if (seconds == null) return;
    final saved = await platform.sleepSetting(seconds);
    if (mounted && saved != null) setState(() => sleepSeconds = saved);
  }

  String sleepLabel(int seconds) =>
      seconds % 60 == 0 ? '${seconds ~/ 60} 分钟' : '$seconds 秒';

  Widget control(
    String label,
    VoidCallback? onPressed, {
    Color accent = cyan,
    bool prominent = false,
  }) => OutlinedButton(
    onPressed: onPressed,
    style: OutlinedButton.styleFrom(
      foregroundColor: accent,
      backgroundColor: prominent ? const Color(0xff153640) : panelColor,
      disabledForegroundColor: secondaryInk,
      minimumSize: const Size(0, 46),
      padding: const EdgeInsets.symmetric(horizontal: 5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
      side: BorderSide(color: prominent ? accent.withAlpha(205) : borderColor),
      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    ),
    child: Text(label, textAlign: TextAlign.center),
  );

  Widget get hero => Container(
    height: 192,
    padding: const EdgeInsets.all(1),
    decoration: BoxDecoration(
      color: Colors.black,
      border: Border.all(color: cyan.withAlpha(115)),
      borderRadius: BorderRadius.circular(19),
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: ValueListenableBuilder(
        valueListenable: scene,
        child: android
            ? AndroidView(
                viewType: 'com.reareyes/eyes-preview',
                layoutDirection: TextDirection.ltr,
                gestureRecognizers: {
                  Factory<EagerGestureRecognizer>(EagerGestureRecognizer.new),
                },
              )
            : null,
        builder: (_, value, nativePreview) => Stack(
          fit: StackFit.expand,
          children: [
            if (nativePreview != null)
              Offstage(
                offstage: interaction.mood != null,
                child: nativePreview,
              ),
            if (nativePreview == null || interaction.mood != null)
              EyeScene(
                mood: value.$1,
                revision: value.$2,
                sleepSeconds: sleepSeconds,
                agents: snapshot.agents,
                connected: snapshot.links.isNotEmpty,
              ),
          ],
        ),
      ),
    ),
  );

  Widget agentStatuses() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SectionTitle('AI 工具状态'),
      const SizedBox(height: 8),
      for (final entry in snapshot.agents.entries)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              StatusGlyph(entry.value),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${entry.key} · ${entry.value.label}',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 630),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 17, 20, 24),
            children: [
              Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: const Color(0xff152438),
                      border: Border.all(color: cyan.withAlpha(124)),
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: const Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircleAvatar(radius: 5.5, backgroundColor: cyan),
                          SizedBox(width: 5.5),
                          CircleAvatar(radius: 5.5, backgroundColor: cyan),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '背屏电子眼',
                          style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          'Agent 状态与表情',
                          style: TextStyle(fontSize: 13, color: secondaryInk),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 17),
              hero,
              if (!kIsWeb) ...[
                InteractionBubbles(interaction, showReply: true),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 5,
                  children: [
                    ListenableBuilder(
                      listenable: interaction,
                      builder: (context, _) => SpeakButton(
                        icon: interaction.speechEnabled
                            ? Icons.mic_none
                            : Icons.chat_bubble_outline,
                        onPressed: () => openConversation(
                          context,
                          interaction,
                          record: interaction.speechEnabled,
                        ),
                        label: interaction.speechEnabled ? '说话' : 'AI 对话',
                      ),
                    ),
                    TextButton(
                      onPressed: () => openModelSettings(context, interaction),
                      child: const Text('模型设置'),
                    ),
                    TextButton(
                      onPressed: () =>
                          openInteractionSettings(context, interaction),
                      child: const Text('语音与提醒'),
                    ),
                    TextButton(
                      onPressed: () => openRecentNotices(context, interaction),
                      child: const Text('最近提醒'),
                    ),
                  ],
                ),
              ],
              if (usageLabels(snapshot) case final labels
                  when labels.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  labels.join(' · '),
                  style: const TextStyle(fontSize: 12, color: secondaryInk),
                ),
              ],
              const SizedBox(height: 16),
              const SectionTitle('显示控制'),
              const SizedBox(height: 8),
              control('主屏横屏显示', fullscreen, prominent: true),
              if (snapshot.rearSupported) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: control(
                        '显示到背屏',
                        () => native.invokeMethod<void>('rear', false),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: control(
                        '圆环校准',
                        () => native.invokeMethod<void>('rear', true),
                        accent: violet,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  '手机切屏需要 Shizuku。',
                  style: TextStyle(fontSize: 12, color: secondaryInk),
                ),
              ],
              const SizedBox(height: 10),
              control(
                syncing ? '正在同步…' : '同步 Codex',
                syncing ? null : refreshNow,
              ),
              const SizedBox(height: 6),
              Semantics(
                liveRegion: true,
                child: Text(
                  syncResult ?? '自动使用已连接的同步方式。',
                  style: const TextStyle(fontSize: 12, color: secondaryInk),
                ),
              ),
              const SizedBox(height: 8),
              const SectionTitle('连接状态'),
              for (final (source, label) in [
                if (android) ('USB', 'USB'),
                if (android) ('LAN', '局域网'),
                ('TAILSCALE', 'Tailscale'),
              ])
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Text(
                    '$label · ${snapshot.links.firstOrNull == source
                        ? '同步中'
                        : snapshot.links.contains(source)
                        ? '已连接'
                        : source == 'TAILSCALE' && pairing == null
                        ? '未配对'
                        : '未连接'}',
                    style: TextStyle(
                      fontSize: 13,
                      color: snapshot.links.contains(source)
                          ? cyan
                          : secondaryInk,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              if (android) ...[
                control('局域网 MCP', lan),
                const SizedBox(height: 8),
              ],
              control('远程连接', remoteConnection),
              const SizedBox(height: 8),
              control('发消息', message),
              if (snapshot.agents.isNotEmpty) ...[
                const SizedBox(height: 18),
                agentStatuses(),
              ],
              const SizedBox(height: 18),
              const SectionTitle('自动睡眠'),
              const SizedBox(height: 8),
              control('待机 ${sleepLabel(sleepSeconds)}后睡眠', sleepSettings),
              const SizedBox(height: 18),
              const SectionTitle('表情测试'),
              const SizedBox(height: 8),
              for (final row in [
                [EyeMood.thinking, EyeMood.question, EyeMood.done],
                [EyeMood.error, EyeMood.sleep, EyeMood.idle],
                if (!android) [EyeMood.stopped, EyeMood.focus, EyeMood.idea],
              ]) ...[
                Row(
                  children: [
                    for (final (index, mood) in row.indexed) ...[
                      if (index != 0) const SizedBox(width: 8),
                      Expanded(
                        child: control(
                          mood.label,
                          () => play(mood),
                          accent: moodColor(mood),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
              ],
              control('试试打招呼', () => play(EyeMood.hello), accent: violet),
              const SizedBox(height: 19),
              const SectionTitle('运行日志'),
              const SizedBox(height: 8),
              Container(
                height: 150,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: panelColor,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: borderColor),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    (android ? snapshot.logs : localLogs).join('\n'),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: secondaryInk,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class DeskPage extends StatefulWidget {
  const DeskPage({
    super.key,
    required this.scene,
    required this.telemetry,
    required this.sleepSeconds,
    this.interaction,
  });
  final ValueListenable<(EyeMood, int)> scene;
  final ValueListenable<Snapshot> telemetry;
  final int sleepSeconds;
  final RobotInteraction? interaction;

  @override
  State<DeskPage> createState() => _DeskPageState();
}

class _DeskPageState extends State<DeskPage> {
  Timer? dimTimer;
  bool visible = false;
  bool _inlineVoice = false;
  PointerDownEvent? _tapDown;
  PointerUpEvent? _previousTap;

  // Observe taps alongside EyeScene, whose recognizer owns the eye gestures.
  void _startTap(PointerDownEvent event) {
    if (_tapDown != null || event.buttons != kPrimaryButton) {
      _cancelTap();
      return;
    }
    _tapDown = event;
  }

  void _moveTap(PointerMoveEvent event) {
    final down = _tapDown;
    if (down != null &&
        down.pointer == event.pointer &&
        (event.position - down.position).distance > kTouchSlop) {
      _cancelTap();
    }
  }

  void _finishTap(PointerUpEvent event) {
    final down = _tapDown;
    if (down == null || down.pointer != event.pointer) return;
    _tapDown = null;
    if (event.timeStamp - down.timeStamp >= kLongPressTimeout ||
        (event.position - down.position).distance > kTouchSlop) {
      _cancelTap();
      return;
    }
    final previous = _previousTap;
    if (previous != null &&
        previous.kind == event.kind &&
        down.timeStamp - previous.timeStamp <= kDoubleTapTimeout &&
        (previous.position - event.position).distance <= kDoubleTapSlop) {
      _previousTap = null;
      _toggleControls();
    } else {
      _previousTap = event;
    }
  }

  void _cancelTap() {
    _tapDown = null;
    _previousTap = null;
  }

  void _toggleControls() {
    dimTimer?.cancel();
    setState(() => visible = !visible);
    if (!visible) return;
    dimTimer = Timer(
      const Duration(seconds: 15),
      () => setState(() => visible = false),
    );
  }

  @override
  void dispose() {
    dimTimer?.cancel();
    super.dispose();
  }

  Widget fade(Widget child) => AnimatedOpacity(
    opacity: visible ? 1 : 0,
    duration: visible || MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 220),
    child: child,
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: LayoutBuilder(
      builder: (context, constraints) {
        final insets = MediaQuery.paddingOf(context);
        final radius = math.min(18.0, constraints.maxHeight * .054);
        return Listener(
          onPointerDown: _startTap,
          onPointerMove: _moveTap,
          onPointerUp: _finishTap,
          onPointerCancel: (_) => _cancelTap(),
          child: Stack(
            children: [
              Positioned.fill(
                child: ValueListenableBuilder(
                  valueListenable: widget.telemetry,
                  builder: (_, data, _) => ValueListenableBuilder(
                    valueListenable: widget.scene,
                    builder: (_, value, _) => EyeScene(
                      mood: value.$1,
                      revision: value.$2,
                      fullScreen: true,
                      sleepSeconds: widget.sleepSeconds,
                      agents: data.agents,
                      connected: data.links.isNotEmpty,
                    ),
                  ),
                ),
              ),
              Positioned(
                top: insets.top + 16,
                right: insets.right + 16,
                child: IgnorePointer(
                  child: fade(
                    ValueListenableBuilder(
                      valueListenable: widget.telemetry,
                      builder: (_, data, _) => Row(
                        spacing: 12,
                        children: [
                          if (data.fiveRemaining case final value?)
                            _UsageRing('5 小时', value, cyan, radius),
                          if (data.weekRemaining case final value?)
                            _UsageRing('本周', value, violet, radius),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (widget.interaction case final interaction?) ...[
                ValueListenableBuilder(
                  valueListenable: widget.telemetry,
                  builder: (context, data, _) {
                    final showUsage =
                        visible &&
                        (data.fiveRemaining != null ||
                            data.weekRemaining != null);
                    final quotaLabelHeight = MediaQuery.textScalerOf(context)
                        .scale(math.min(11.0, radius * .63));
                    return Positioned(
                      top:
                          insets.top +
                          16 +
                          (showUsage
                              ? radius * 2 + quotaLabelHeight * 1.5 + 12
                              : 0),
                      right: insets.right + 16,
                      width: math.min(330, constraints.maxWidth * .50),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: constraints.maxHeight * .48,
                        ),
                        child: SingleChildScrollView(
                          child: InteractionBubbles(
                            interaction,
                            showReply: !_inlineVoice,
                          ),
                        ),
                      ),
                    );
                  },
                ),
                if (_inlineVoice)
                  Positioned(
                    bottom:
                        insets.bottom + (constraints.maxWidth < 600 ? 64 : 16),
                    left: insets.left,
                    right: insets.right,
                    child: IgnorePointer(
                      child: Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: math.min(344, constraints.maxWidth * .54),
                          ),
                          child: ListenableBuilder(
                            listenable: interaction,
                            builder: (_, _) => DeskVoiceFeedback(interaction),
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  bottom: insets.bottom + 16,
                  right: insets.right + 16,
                  child: ListenableBuilder(
                    listenable: interaction,
                    builder: (context, _) => DeskVoiceButton(
                      listening: interaction.listening,
                      speechEnabled: interaction.speechEnabled,
                      onPressed: interaction.finishingRecording
                          ? null
                          : () {
                              if (!interaction.speechEnabled) {
                                unawaited(
                                  openConversation(context, interaction),
                                );
                              } else if (interaction.listening) {
                                unawaited(
                                  interaction.stopRecording(sendAfter: true),
                                );
                              } else {
                                if (!_inlineVoice) {
                                  setState(() => _inlineVoice = true);
                                }
                                unawaited(
                                  interaction.startRecording(sendAfter: true),
                                );
                              }
                            },
                    ),
                  ),
                ),
              ],
              Positioned(
                bottom: insets.bottom + 16,
                left: widget.interaction == null ? null : insets.left + 16,
                right: widget.interaction == null ? insets.right + 16 : null,
                child: ExcludeFocus(
                  excluding: !visible,
                  child: IgnorePointer(
                    ignoring: !visible,
                    child: fade(
                      OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 48),
                          backgroundColor: panelColor,
                          foregroundColor: secondaryInk,
                          side: const BorderSide(color: borderColor),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                        ),
                        child: const Text(
                          '退出全屏',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

class _UsageRing extends StatelessWidget {
  const _UsageRing(this.label, this.remaining, this.accent, this.radius);
  final String label;
  final int remaining;
  final Color accent;
  final double radius;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    spacing: 4,
    children: [
      SizedBox.square(
        dimension: radius * 2,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CircularProgressIndicator(
              value: remaining / 100,
              strokeWidth: radius * .075,
              backgroundColor: borderColor,
              color: accent,
              padding: EdgeInsets.zero,
            ),
            Center(
              child: Text(
                '$remaining%',
                style: TextStyle(
                  fontSize: radius * .59,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
      Text(
        label,
        style: TextStyle(
          color: secondaryInk,
          fontSize: math.min(11.0, radius * .63),
        ),
      ),
    ],
  );
}
