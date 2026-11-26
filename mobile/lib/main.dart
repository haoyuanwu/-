import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
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
import 'permission_settings_view.dart';
import 'phone_model.dart';
import 'remote.dart';
import 'settings_page.dart';
import 'status_strip.dart';
import 'platform_io.dart'
    if (dart.library.js_interop) 'platform_web.dart'
    as platform;

const native = MethodChannel('com.reareyes/mobile');
final android = platform.isAndroid;

const _homeOrientation = [DeviceOrientation.portraitUp];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb) await SystemChrome.setPreferredOrientations(_homeOrientation);
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
  (String?, double, int)? _rearVoice;
  CloudConflictSummary? _announcedModelConflict;
  int _announcedModelUpdate = 0;
  OverlayEntry? _modelToast;
  Timer? _modelToastTimer;
  Future<void>? pendingRefresh;
  final localLogs = <String>[];
  bool foreground = true;
  int nextRemoteAt = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (android) native.setMethodCallHandler(_handleNativeEvent);
    interaction.addListener(_updateScene);
    unawaited(
      interaction.initialize().then((_) => interaction.syncPhoneModel()),
    );
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(refresh());
      if (foreground) unawaited(interaction.syncPhoneModel());
    });
    unawaited(load());
  }

  Future<void> _handleNativeEvent(MethodCall call) async {
    if (call.method == 'rearDisplayReady') await refresh(force: true);
  }

  Future<void> load() async {
    try {
      final raw = await platform.loadPairing();
      if (raw != null && mounted) {
        final saved = Pairing.parse(raw);
        if (pairing?.encode() != saved.encode()) {
          setState(() => pairing = saved);
          interaction.resetConnection();
        }
      }
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
      unawaited(interaction.syncPhoneModel(force: true));
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      interaction.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (android) native.setMethodCallHandler(null);
    timer.cancel();
    previewTimer?.cancel();
    _dismissModelToast();
    interaction.removeListener(_updateScene);
    interaction.dispose();
    scene.dispose();
    telemetry.dispose();
    super.dispose();
  }

  void _updateScene() {
    if (interaction.phoneModelUpdate case final update?
        when update.id != _announcedModelUpdate) {
      _announcedModelUpdate = update.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _announcedModelUpdate != update.id) return;
        _showModelToast(update.message);
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    }
    final conflict = interaction.phoneModelConflict;
    if (_announcedModelConflict != conflict) {
      _announcedModelConflict = conflict;
      if (conflict != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || interaction.phoneModelConflict != conflict) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('两端的云端模型配置不同，请在电脑上选择如何同步。'),
              action: SnackBarAction(
                label: '查看',
                onPressed: () =>
                    unawaited(openModelSettings(context, interaction)),
              ),
            ),
          );
        });
      }
    }
    final mood = interaction.mood ?? preview ?? snapshot.state;
    if (scene.value.$1 != mood) {
      scene.value = (mood, ++revision);
    }
    interaction.updateActivity(
      interaction.generating ? EyeMood.thinking : snapshot.state,
    );
    if (android) {
      final phase = interaction.finishingRecording
          ? 'thinking'
          : interaction.listening
          ? 'listening'
          : interaction.spokenText != null
          ? 'speaking'
          : switch (interaction.phase) {
              InteractionPhase.thinking => 'thinking',
              InteractionPhase.answering => 'answering',
              _ => null,
            };
      final listening = phase == 'listening';
      final voice = (
        phase,
        listening ? interaction.inputLevel : 0.0,
        listening ? interaction.speechActivity : 0,
      );
      if (_rearVoice != voice) {
        _rearVoice = voice;
        unawaited(_sendRearVoice(voice));
      }
    }
  }

  void _dismissModelToast() {
    _modelToastTimer?.cancel();
    _modelToast?.remove();
    _modelToast?.dispose();
    _modelToast = null;
  }

  void _showModelToast(String message) {
    final overlay = Navigator.of(context, rootNavigator: true).overlay;
    if (overlay == null) return;
    _dismissModelToast();
    final entry = OverlayEntry(
      builder: (context) => Positioned.fill(
        child: IgnorePointer(
          child: SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  20,
                  0,
                  20,
                  24 + MediaQuery.viewInsetsOf(context).bottom,
                ),
                child: Semantics(
                  liveRegion: true,
                  child: Material(
                    color: panelColor,
                    shape: const StadiumBorder(
                      side: BorderSide(color: borderColor),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      child: Text(message, textAlign: TextAlign.center),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    _modelToast = entry;
    _modelToastTimer = Timer(const Duration(seconds: 3), _dismissModelToast);
  }

  Future<void> _sendRearVoice((String?, double, int) voice) async {
    try {
      await native.invokeMethod<void>('rearVoice', {
        'phase': voice.$1,
        'level': voice.$2,
        'activity': voice.$3,
      });
    } on PlatformException {
      // The main display can still show the conversation.
    } on MissingPluginException {
      // Only the native Android host mirrors voice to the rear display.
    }
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
              snapshot.agents.isNotEmpty ||
              snapshot.models.isNotEmpty)) {
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
            models: snapshot.models,
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
    if (!android && pairing == null) return;
    unawaited(interaction.syncPhoneModel(force: true));
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
            onPressed: () => Navigator.pop(dialog, 'cloud'),
            child: const Text('同步云端模型'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'pair') await pair();
    if (action == 'cloud') {
      await interaction.syncPhoneModel(force: true);
      if (mounted) {
        notice(
          interaction.phoneModelConflict != null
              ? '云端配置有冲突，请在电脑的「模型连接 → 手机模型」处理。'
              : interaction.phoneModelSyncError ??
                    '已同步 ${interaction.savedCloudModels.length} 个云端模型配置',
        );
      }
    }
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

  bool _deskOpen = false;

  Future<void> fullscreen() async {
    if (_deskOpen) return;
    _deskOpen = true;
    try {
      await platform.keepScreenOn(true);
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
      try {
        if (!kIsWeb) {
          await SystemChrome.setPreferredOrientations(_homeOrientation);
          await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        }
        if (interaction.listening) await interaction.cancelRecording();
      } finally {
        _deskOpen = false;
        await platform.keepScreenOn(false);
      }
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

  Future<void> rearDisplaySettings() async {
    try {
      final saved = await native.invokeMapMethod<String, Object?>(
        'rearSettings',
      );
      if (!mounted || saved == null) return;
      var keepOn = saved['keepOn'] as bool;
      var brightness = (saved['brightness'] as int).toDouble();
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: const Text('背屏显示设置'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('背屏常亮'),
                  value: keepOn,
                  onChanged: (value) => update(() => keepOn = value),
                ),
                const SizedBox(height: 12),
                Text('背屏亮度 ${brightness.round()}%'),
                Slider(
                  min: 10,
                  max: 100,
                  divisions: 90,
                  value: brightness,
                  semanticFormatterCallback: (value) =>
                      '背屏亮度 ${value.round()}%',
                  onChanged: (value) => update(() => brightness = value),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialog, true),
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      );
      if (confirmed != true) return;
      await native.invokeMapMethod<String, Object?>('rearSettings', {
        'keepOn': keepOn,
        'brightness': brightness.round(),
      });
    } on PlatformException {
      if (mounted) notice('无法读取或保存背屏显示设置。');
    }
  }

  String sleepLabel(int seconds) =>
      seconds % 60 == 0 ? '${seconds ~/ 60} 分钟' : '$seconds 秒';

  Widget control(
    String label,
    VoidCallback? onPressed, {
    Color accent = cyan,
    bool prominent = false,
    IconData? icon,
  }) => OutlinedButton(
    onPressed: onPressed,
    style: OutlinedButton.styleFrom(
      foregroundColor: prominent ? backdrop : accent,
      backgroundColor: prominent ? cyan : Colors.transparent,
      disabledForegroundColor: secondaryInk,
      minimumSize: const Size(0, 46),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      side: BorderSide(color: prominent ? cyan : borderColor),
      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    ),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[Icon(icon, size: 18), const SizedBox(width: 6)],
        Flexible(child: Text(label, textAlign: TextAlign.center)),
      ],
    ),
  );

  Widget actionGroup(List<Widget> actions, {int columns = 2}) => LayoutBuilder(
    builder: (context, constraints) {
      const gap = 8.0;
      final scale = MediaQuery.textScalerOf(context).scale(13) / 13;
      final count = (constraints.maxWidth / (95 * scale)).floor().clamp(
        1,
        columns,
      );
      final width = (constraints.maxWidth - gap * (count - 1)) / count;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final action in actions) SizedBox(width: width, child: action),
        ],
      );
    },
  );

  Widget homeSection(String title, List<Widget> children) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: panelColor,
      border: Border.all(color: borderColor),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [SectionTitle(title), const SizedBox(height: 10), ...children],
    ),
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
      child: ListenableBuilder(
        listenable: Listenable.merge([scene, interaction]),
        builder: (_, _) => EyeScene(
          mood: scene.value.$1,
          revision: scene.value.$2,
          conversationActive: interaction.conversationActive,
          sleepSeconds: sleepSeconds,
          agents: snapshot.agents,
          connected: snapshot.links.isNotEmpty,
          allowVerticalScroll: true,
        ),
      ),
    ),
  );

  Widget agentStatuses() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
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

  Widget modelStatuses() => homeSection('桌面模型连接', [
    if (snapshot.models.isEmpty)
      Text(
        snapshot.links.isEmpty ? '连接电脑后查看模型状态' : '暂无桌面模型状态',
        style: const TextStyle(fontSize: 13, color: secondaryInk),
      ),
    for (final (index, model) in snapshot.models.indexed)
      statusRow(
        model.name,
        Icons.memory_outlined,
        snapshot.links.isEmpty
            ? ('连接中断', Icons.link_off, secondaryInk)
            : switch (model.available) {
                true => (
                  '已连接',
                  Icons.check_circle_outline,
                  moodColor(EyeMood.done),
                ),
                false => (
                  '连接失败',
                  Icons.error_outline,
                  Theme.of(context).colorScheme.error,
                ),
                null => ('未验证', Icons.help_outline, secondaryInk),
              },
        detail: '${model.local ? '本地' : '云端'}${index == 0 ? ' · 默认' : ''}',
      ),
  ]);

  Widget homeHeader() => Row(
    children: [
      Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: panelColor,
          border: Border.all(color: borderColor),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircleAvatar(radius: 4.5, backgroundColor: cyan),
            SizedBox(width: 5),
            CircleAvatar(radius: 4.5, backgroundColor: cyan),
          ],
        ),
      ),
      const SizedBox(width: 12),
      const Expanded(
        child: Text(
          '背屏电子眼',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
        ),
      ),
      IconButton(
        tooltip: '设置',
        icon: const Icon(Icons.settings_outlined, color: secondaryInk),
        onPressed: openSettings,
      ),
    ],
  );

  Future<void> openSettings() => openSettingsPage(context, '设置', (route) {
    return SettingsGroup([
      SettingsEntry(
        Icons.display_settings_outlined,
        '显示',
        () => openSettingsPage(route, '显示设置', (_) => displaySettings()),
        detail: snapshot.rearSupported ? '自动睡眠、背屏亮度与校准' : '自动睡眠',
      ),
      SettingsEntry(
        Icons.link,
        '连接',
        () => openSettingsPage(route, '连接设置', (_) => connectionSettings()),
        detail: android ? 'Tailscale 配对、局域网 MCP' : 'Tailscale 配对',
      ),
      if (!kIsWeb) ...[
        SettingsEntry(
          Icons.record_voice_over_outlined,
          '语音与提醒',
          () => openInteractionSettings(route, interaction),
          detail: '自动朗读、音色、提醒规则与记录',
        ),
        SettingsEntry(
          Icons.memory_outlined,
          '模型设置',
          () => openModelSettings(route, interaction),
          detail: '桌面、云端和手机本地模型',
        ),
      ],
      if (android || (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS))
        SettingsEntry(
          Icons.security_outlined,
          '权限设置',
          () => Navigator.of(route).push<void>(
            MaterialPageRoute(builder: (_) => const PermissionSettingsPage()),
          ),
        ),
      SettingsEntry(
        Icons.build_outlined,
        '诊断',
        () => openSettingsPage(route, '诊断', diagnostics),
        detail: '表情测试、运行日志',
      ),
    ]);
  });

  Widget displaySettings() => ValueListenableBuilder(
    valueListenable: telemetry,
    builder: (context, data, _) => SettingsGroup([
      SettingsEntry(Icons.bedtime_outlined, '自动睡眠', sleepSettings),
      if (data.rearSupported) ...[
        SettingsEntry(
          Icons.brightness_6_outlined,
          '背屏常亮与亮度',
          rearDisplaySettings,
        ),
        SettingsEntry(
          Icons.adjust,
          '圆环校准',
          () => native.invokeMethod<void>('rear', true),
        ),
      ],
    ]),
  );

  Widget connectionSettings() => SettingsGroup([
    SettingsEntry(Icons.vpn_lock_outlined, 'Tailscale 配对', remoteConnection),
    if (android) SettingsEntry(Icons.lan_outlined, '局域网 MCP', lan),
  ]);

  Widget displayActions() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (snapshot.rearSupported)
        actionGroup([
          control(
            '显示到背屏',
            () => native.invokeMethod<void>('rear', false),
            prominent: true,
            icon: Icons.phone_android,
          ),
          control(
            '主屏横屏显示',
            fullscreen,
            prominent: true,
            icon: Icons.screen_rotation_outlined,
          ),
        ])
      else
        control(
          '主屏横屏显示',
          fullscreen,
          prominent: true,
          icon: Icons.screen_rotation_outlined,
        ),
      if (snapshot.rearSupported || !kIsWeb) const SizedBox(height: 8),
      if (snapshot.rearSupported)
        const Text(
          '切换到背屏需要 Shizuku。',
          style: TextStyle(fontSize: 12, color: secondaryInk),
        ),
      if (snapshot.rearSupported && !kIsWeb) const SizedBox(height: 8),
      if (!kIsWeb)
        ListenableBuilder(
          listenable: interaction,
          builder: (context, _) => control(
            '对话',
            () => openConversation(
              context,
              interaction,
              record: interaction.speechEnabled,
            ),
            icon: interaction.speechEnabled
                ? Icons.mic_none
                : Icons.chat_bubble_outline,
          ),
        ),
      if (!kIsWeb) InteractionBubbles(interaction, showReply: true),
    ],
  );

  Widget connectionControls() => homeSection('连接状态', [
    for (final (source, label, icon) in [
      if (android) ('USB', 'USB', Icons.usb),
      if (android) ('LAN', '局域网', Icons.wifi),
      ('TAILSCALE', 'Tailscale', Icons.vpn_lock_outlined),
    ])
      statusRow(
        label,
        icon,
        snapshot.links.firstOrNull == source
            ? ('同步中', Icons.sync, cyan)
            : snapshot.links.contains(source)
            ? ('已连接', Icons.check_circle_outline, moodColor(EyeMood.done))
            : source == 'TAILSCALE' && pairing == null
            ? ('未配对', Icons.link_off, secondaryInk)
            : ('未连接', Icons.remove_circle_outline, secondaryInk),
      ),
    if (android || pairing != null) ...[
      const SizedBox(height: 8),
      control(
        syncing ? '正在同步…' : '同步 Codex',
        syncing ? null : refreshNow,
        icon: Icons.sync,
      ),
    ],
    if (syncing || syncResult != null || failure != null) ...[
      const SizedBox(height: 8),
      Semantics(
        liveRegion: true,
        child: Text(
          syncing ? '正在等待状态更新…' : (syncResult ?? failure!),
          style: const TextStyle(fontSize: 12, color: secondaryInk),
        ),
      ),
    ],
  ]);

  Widget statusRow(
    String label,
    IconData icon,
    (String, IconData, Color) status, {
    String? detail,
  }) {
    final (text, stateIcon, color) = status;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 17, color: secondaryInk),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 13)),
                if (detail != null)
                  Text(
                    detail,
                    style: const TextStyle(fontSize: 12, color: secondaryInk),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            flex: 2,
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(stateIcon, size: 16, color: color),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      text,
                      style: TextStyle(fontSize: 13, color: color),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget diagnostics(BuildContext route) => SettingsGroup([
    SettingsEntry(
      Icons.sentiment_satisfied_alt,
      '表情测试',
      () => openSettingsPage(
        route,
        '表情测试',
        (_) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            hero,
            const SizedBox(height: 12),
            actionGroup([
              for (final mood in [
                EyeMood.thinking,
                EyeMood.question,
                EyeMood.done,
                EyeMood.error,
                EyeMood.sleep,
                EyeMood.idle,
                if (!android) ...[EyeMood.stopped, EyeMood.focus, EyeMood.idea],
              ])
                control(mood.label, () => play(mood), accent: moodColor(mood)),
              control('试试打招呼', () => play(EyeMood.hello), accent: violet),
            ], columns: 3),
          ],
        ),
      ),
    ),
    SettingsEntry(
      Icons.terminal,
      '运行日志',
      () => openSettingsPage(
        route,
        '运行日志',
        (_) => ValueListenableBuilder(
          valueListenable: telemetry,
          builder: (context, data, _) {
            final logs = android ? data.logs : localLogs;
            return SelectableText(
              logs.isEmpty ? '暂无运行日志' : logs.join('\n'),
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: secondaryInk,
              ),
            );
          },
        ),
      ),
    ),
  ]);

  @override
  Widget build(BuildContext context) {
    final usage = usageLabels(snapshot);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 740),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                homeHeader(),
                const SizedBox(height: 14),
                hero,
                const SizedBox(height: 12),
                displayActions(),
                if (usage.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 16,
                    runSpacing: 4,
                    children: [
                      for (final label in usage)
                        Text(
                          label,
                          style: const TextStyle(
                            fontSize: 12,
                            color: secondaryInk,
                          ),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                LayoutBuilder(
                  builder: (context, constraints) {
                    if (constraints.maxWidth < 620) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          connectionControls(),
                          const SizedBox(height: 12),
                          modelStatuses(),
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: connectionControls()),
                        const SizedBox(width: 12),
                        Expanded(child: modelStatuses()),
                      ],
                    );
                  },
                ),
                if (snapshot.agents.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  homeSection('AI 工具状态', [agentStatuses()]),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
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
        return Stack(
          children: [
            Positioned.fill(
              child: ValueListenableBuilder(
                valueListenable: widget.telemetry,
                builder: (_, data, _) => ListenableBuilder(
                  listenable: Listenable.merge([
                    widget.scene,
                    widget.interaction,
                  ]),
                  builder: (_, _) {
                    final (mood, revision) = widget.scene.value;
                    final interaction = widget.interaction;
                    final listening = interaction?.listening == true;
                    final recognizing = interaction?.finishingRecording == true;
                    final speaking = interaction?.spokenText != null;
                    final eyeMood = recognizing
                        ? EyeMood.thinking
                        : _inlineVoice &&
                              interaction?.error != null &&
                              !listening
                        ? EyeMood.error
                        : speaking && !listening
                        ? EyeMood.hello
                        : mood;
                    return EyeScene(
                      mood: eyeMood,
                      revision: revision,
                      fullScreen: true,
                      onDoubleTap: _toggleControls,
                      noticeCue: interaction?.noticeReaction,
                      voiceLevel: listening && !recognizing
                          ? interaction?.inputLevel
                          : null,
                      speechActivity: interaction?.speechActivity ?? 0,
                      speaking: speaking && eyeMood == EyeMood.hello,
                      conversationActive:
                          interaction?.conversationActive == true,
                      sleepSeconds: widget.sleepSeconds,
                      agents: data.agents,
                      connected: data.links.isNotEmpty,
                    );
                  },
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
                    bottom: insets.bottom + 76,
                    child: Column(
                      children: [
                        Expanded(
                          child: Align(
                            alignment: Alignment.topCenter,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxHeight: constraints.maxHeight * .48,
                              ),
                              child: SingleChildScrollView(
                                hitTestBehavior: HitTestBehavior.deferToChild,
                                child: InteractionBubbles(
                                  interaction,
                                  showReply: !_inlineVoice,
                                  includeNotice: false,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 300),
                            child: NoticeSignal(interaction),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              Positioned(
                bottom: insets.bottom + 16,
                left: insets.left,
                right: insets.right,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: math.min(344, constraints.maxWidth * .54),
                    ),
                    child: ListenableBuilder(
                      listenable: interaction,
                      builder: (context, _) => DeskVoiceControl(
                        interaction,
                        showCaption: _inlineVoice,
                        onPressed: () {
                          if (!interaction.speechEnabled) {
                            unawaited(openConversation(context, interaction));
                          } else if (interaction.finishingRecording) {
                            unawaited(interaction.cancelRecording());
                          } else if (interaction.listening) {
                            unawaited(
                              interaction.stopRecording(sendAfter: true),
                            );
                          } else if (interaction.canRetryReply) {
                            unawaited(interaction.send());
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
                      child: const Text('退出全屏', style: TextStyle(fontSize: 13)),
                    ),
                  ),
                ),
              ),
            ),
          ],
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
