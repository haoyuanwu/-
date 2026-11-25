import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Keep the SDK Material import for stable Flutter compatibility.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'agent_mcp.dart';
import 'desktop_chrome.dart';
import 'model_connections_panel.dart';
import 'remote_server.dart';
import 'tailscale_endpoint.dart';

void main() => runApp(const RearEyes());

class RearEyes extends StatelessWidget {
  const RearEyes({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Robot Eyes',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: background,
      fontFamily: Platform.isWindows ? 'Segoe UI' : null,
      tooltipTheme: const TooltipThemeData(
        waitDuration: Duration(milliseconds: 400),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 40),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 40),
          side: const BorderSide(color: line),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      colorScheme: const ColorScheme.dark(
        primary: cyan,
        secondary: violet,
        surface: surface,
        onSurface: ink,
        error: Color(0xffff93aa),
      ),
    ),
    home: const DesktopDashboard(),
  );
}

class DesktopDashboard extends StatefulWidget {
  const DesktopDashboard({super.key});

  @override
  State<DesktopDashboard> createState() => _DesktopDashboardState();
}

class _DesktopDashboardState extends State<DesktopDashboard> {
  static const reportingSkillAsset = 'skills/robot-eyes-reporting/SKILL.md';
  late final RemoteServer server;
  TailscaleStatus? tailscale;
  String? get endpoint => tailscale?.endpoint;
  String? get setupCommand => tailscale?.setupCommand;
  String get tailscaleLabel => checking
      ? '检测中'
      : switch (tailscale?.state) {
          TailscaleState.ready => '已检测到 HTTPS 地址',
          TailscaleState.serveMissing => '已连接，待配置 Serve',
          TailscaleState.serveUnknown => '无法读取 Serve 状态',
          TailscaleState.disconnected => '未连接 tailnet',
          TailscaleState.unavailable => '无法读取 Tailscale 状态',
          null => '等待检测',
        };
  String? failure;
  bool busy = false;
  bool checking = false;
  List<String> _publishedRows = const [];
  bool? _publishedBusy;
  bool? _publishedRunning;

  void publishTray() {
    final rows = [
      '电脑服务 · ${busy
          ? '切换中'
          : failure != null
          ? '启动失败'
          : server.running
          ? '运行中'
          : '已停止'}',
      '桌面 MCP · ${server.agentMcp.running
          ? '运行中 / ${server.agentMcp.connectedClients().length} 个工具'
          : server.running && server.agentMcpError != null
          ? '启动失败'
          : '已停止'}',
      'Tailscale · $tailscaleLabel',
      '手机局域网 · ${server.phoneLinks.lanAddress == null ? '未配置' : '已配置'}',
      'Web App · ${!server.webApp.available
          ? '未安装'
          : server.running
          ? '可用'
          : '已停止'}',
    ];
    if (_publishedBusy == busy &&
        _publishedRunning == server.running &&
        _publishedRows.join('\n') == rows.join('\n')) {
      return;
    }
    _publishedBusy = busy;
    _publishedRunning = server.running;
    _publishedRows = rows;
    unawaited(
      desktopAction('updateTray', {
        'running': server.running,
        'busy': busy,
        'rows': rows,
        'canCopyPairing': !busy && server.running && endpoint != null,
        'canCopyMcp': !busy && server.agentMcp.running,
      }),
    );
  }

  @override
  void initState() {
    super.initState();
    server = RemoteServer(RemoteServer.defaultDirectory(), (newMessage) {
      if (!mounted) return;
      setState(() {});
      publishTray();
      if (newMessage) {
        unawaited(notifyMessage());
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('收到一条手机消息')));
      }
    });
    if (Platform.isMacOS || Platform.isWindows) {
      desktopChannel.setMethodCallHandler((call) async {
        if (!mounted) return null;
        if (call.method == 'toggleService') await toggleService();
        if (call.method == 'copyConfiguration' && call.arguments is String) {
          return copyConfiguration(call.arguments as String);
        }
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(toggleService());
        unawaited(detectEndpoint());
      }
    });
  }

  @override
  void dispose() {
    if (Platform.isMacOS || Platform.isWindows) {
      desktopChannel.setMethodCallHandler(null);
    }
    unawaited(server.stop());
    super.dispose();
  }

  Future<void> notifyMessage() async {
    try {
      await const MethodChannel('com.reareyes/desktop')
          .invokeMethod<void>('messageReceived');
    } on PlatformException {
      await SystemSound.play(SystemSoundType.alert);
    } on MissingPluginException {
      await SystemSound.play(SystemSoundType.alert);
    }
  }

  Future<void> toggleService() async {
    if (busy) return;
    setState(() {
      busy = true;
      failure = null;
    });
    publishTray();
    try {
      if (server.running) {
        await server.stop();
      } else {
        await server.start();
      }
    } on SocketException {
      failure = '启动失败，请检查本机端口 ${RemoteServer.port} 是否被占用。';
    } on FileSystemException {
      failure = '无法访问本地配置或收件箱，请检查文件权限。';
    } on FormatException {
      failure = '本地配对密钥无效，请检查 pairing.key。';
    } finally {
      if (mounted) {
        setState(() => busy = false);
        publishTray();
      }
    }
  }

  Future<void> detectEndpoint() async {
    if (checking) return;
    setState(() => checking = true);
    publishTray();
    TailscaleStatus? result;
    try {
      result = await detectTailscale(RemoteServer.port, RemoteServer.servePort);
    } finally {
      if (mounted) {
        setState(() {
          tailscale = result;
          checking = false;
        });
        publishTray();
      }
    }
  }

  Future<void> copy(String value, String confirmation) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(confirmation)));
    }
  }

  Future<bool> copyConfiguration(String configuration) async {
    if (busy) return false;
    if (configuration == 'pairing') {
      final address = endpoint;
      if (!server.running || address == null) return false;
      await copy(
        jsonEncode({'url': address, 'token': server.token}),
        '已复制配对配置',
      );
      return true;
    }
    if (configuration != 'aiSetup' || !server.agentMcp.running) return false;
    final skill = await rootBundle.loadString(reportingSkillAsset);
    if (!mounted || busy || !server.agentMcp.running) return false;
    await copy(server.agentMcp.setupPrompt(skill), '已复制，粘贴给同一台电脑上的 AI');
    return true;
  }

  Widget panel(Widget child) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: surface,
      border: Border.all(color: line),
      borderRadius: BorderRadius.circular(14),
    ),
    child: child,
  );

  Widget heading(IconData icon, String text, [Color color = cyan]) => Row(
    children: [
      Icon(icon, color: color, size: 20),
      const SizedBox(width: 10),
      Text(
        text,
        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
      ),
    ],
  );

  Widget servicePanel() {
    final status = server.status;
    String remaining(String name) {
      final used = status[name];
      return used is int && server.running ? '${100 - used}%' : '—';
    }

    return panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: heading(Icons.monitor_rounded, '电脑服务')),
              StatusPill(
                busy
                    ? '切换中'
                    : server.running
                    ? '运行中'
                    : '已停止',
                active: server.running && !busy,
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            '127.0.0.1:${RemoteServer.port}',
            style: TextStyle(
              color: muted,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          if (failure != null) ...[
            const SizedBox(height: 8),
            Text(
              failure!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 12),
          FilledButton.icon(
            icon: Icon(
              server.running ? Icons.stop_rounded : Icons.play_arrow_rounded,
              size: 18,
            ),
            onPressed: busy ? null : toggleService,
            label: Text(server.running ? '停止服务' : '启动服务'),
          ),
          const Divider(height: 34, color: line),
          Text(
            server.running
                ? '任务状态 · ${RemoteServer.labels[status['state']]}'
                : '任务状态 · —',
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 20,
            children: [
              Text(
                '5 小时剩余 ${remaining('five')}',
                style: const TextStyle(color: muted),
              ),
              Text(
                '周剩余 ${remaining('week')}',
                style: const TextStyle(color: muted),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget pairingPanel() {
    final command = setupCommand;
    final needsServe = tailscale?.state == TailscaleState.serveMissing;
    return panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          heading(Icons.link_rounded, 'Tailscale 连接'),
          const SizedBox(height: 14),
          if (endpoint == null) ...[
            Text(tailscaleLabel, style: const TextStyle(color: muted)),
            if (!checking && needsServe && command != null) ...[
              const SizedBox(height: 8),
              Text(
                Platform.isWindows
                    ? '在 PowerShell 运行以下命令，再重新检测。'
                    : '在终端运行以下命令，再重新检测。',
              ),
              const SizedBox(height: 8),
              SelectableText(command, style: const TextStyle(color: cyan)),
            ],
          ] else ...[
            SelectableText(endpoint!, style: const TextStyle(color: cyan)),
            const SizedBox(height: 8),
            Text(
              server.webApp.available
                  ? '在手机浏览器打开上方地址，将配对配置粘贴到「远程连接」。'
                  : '把配对配置复制到手机 Robot Eyes 的「远程连接」。',
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: checking ? null : detectEndpoint,
                child: const Text('重新检测'),
              ),
              if (!checking && needsServe && command != null)
                OutlinedButton(
                  onPressed: () => copy(command, '已复制命令'),
                  child: const Text('复制命令'),
                )
              else if (endpoint != null) ...[
                if (server.webApp.available)
                  OutlinedButton(
                    onPressed: !server.running
                        ? null
                        : () => copy(endpoint!, '已复制 Web App 地址'),
                    child: const Text('复制 Web App 地址'),
                  ),
                FilledButton.icon(
                  onPressed: !server.running
                      ? null
                      : () => copyConfiguration('pairing'),
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: const Text('复制配对配置'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> editLan() async {
    String config = '';
    String? error;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          final address = server.phoneLinks.lanAddress;
          return AlertDialog(
            title: const Text('手机局域网配置'),
            scrollable: true,
            content: SizedBox(
              width: 460,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (address != null) ...[
                    const Text('当前配置 · Streamable HTTP'),
                    const SizedBox(height: 6),
                    SelectableText(
                      address,
                      style: const TextStyle(color: cyan),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Authorization · Bearer ••••••••',
                      style: TextStyle(color: muted),
                    ),
                    const SizedBox(height: 16),
                  ],
                  TextField(
                    decoration: InputDecoration(
                      labelText: address == null
                          ? '粘贴手机的局域网 MCP 配置'
                          : '粘贴新配置以替换',
                      errorText: error,
                      helperText: '手机在「局域网 MCP」开启后可以复制配置。',
                    ),
                    obscureText: true,
                    onChanged: (value) => update(() {
                      config = value;
                      error = null;
                    }),
                  ),
                ],
              ),
            ),
            actions: [
              if (address != null)
                TextButton(
                  onPressed: () {
                    try {
                      server.phoneLinks.configureLan('');
                      Navigator.pop(context);
                    } on FileSystemException {
                      update(() => error = '无法移除配置，请检查文件权限。');
                    }
                  },
                  child: const Text('移除配置'),
                ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: config.trim().isEmpty
                    ? null
                    : () {
                        try {
                          server.phoneLinks.configureLan(config);
                          Navigator.pop(context);
                        } on FormatException {
                          update(() => error = '请粘贴手机复制的完整 MCP 配置。');
                        } on FileSystemException {
                          update(() => error = '无法保存配置，请检查文件权限。');
                        }
                      },
                child: const Text('保存'),
              ),
            ],
          );
        },
      ),
    );
    if (mounted) {
      setState(() {});
      publishTray();
    }
  }

  Widget lanPanel() {
    final address = server.phoneLinks.lanAddress;
    return panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: heading(Icons.phone_android_rounded, '手机局域网')),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: editLan, child: const Text('管理配置')),
            ],
          ),
          const SizedBox(height: 8),
          if (address == null)
            const Text('未配置', style: TextStyle(color: muted))
          else
            SelectableText(address, style: const TextStyle(color: cyan)),
        ],
      ),
    );
  }

  Future<void> showAiConfiguration() async {
    final skill = await rootBundle.loadString(reportingSkillAsset);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('AI 配置详情'),
        scrollable: true,
        content: SizedBox(
          width: 560,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('通用 MCP'),
              const SizedBox(height: 8),
              SelectableText(
                server.agentMcp.configuration(),
                style: TextStyle(
                  color: cyan,
                  fontFamily: Platform.isWindows ? 'Consolas' : 'Menlo',
                ),
              ),
              const SizedBox(height: 16),
              const Text('robot-eyes-reporting/SKILL.md'),
              const SizedBox(height: 8),
              SelectableText(
                skill.trimRight(),
                style: const TextStyle(color: muted),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget agentMcpPanel() {
    final verification = server.agentMcp.lastReportingVerification;
    return panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          heading(Icons.link_rounded, '桌面 AI MCP'),
          const SizedBox(height: 8),
          if (server.agentMcp.running) ...[
            SelectableText(AgentMcp.url(), style: const TextStyle(color: cyan)),
            const SizedBox(height: 8),
            const Text(
              '复制后粘贴给同一台电脑上的 AI，由它添加 MCP 并安装状态上报 Skill。',
              style: TextStyle(color: muted),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: busy ? null : () => copyConfiguration('aiSetup'),
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: const Text('复制给 AI 配置'),
                ),
                OutlinedButton(
                  onPressed: showAiConfiguration,
                  child: const Text('查看配置详情'),
                ),
              ],
            ),
          ] else
            Text(
              server.agentMcpError ?? '启动电脑服务后可连接。',
              style: const TextStyle(color: muted),
            ),
          if (verification != null) ...[
            const SizedBox(height: 10),
            Text(
              '最近验证 · ${verification.name} · ${TimeOfDay.fromDateTime(verification.at).format(context)}',
              style: const TextStyle(color: muted),
            ),
          ],
        ],
      ),
    );
  }

  Widget inboxPanel() => panel(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        heading(Icons.inbox_outlined, '手机收件箱', violet),
        const SizedBox(height: 14),
        if (server.messages.isEmpty)
          const Text('暂无消息', style: TextStyle(color: muted))
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 340),
            child: ListView.separated(
              primary: false,
              shrinkWrap: true,
              itemCount: server.messages.length,
              separatorBuilder: (_, _) => const Divider(color: line),
              itemBuilder: (context, index) {
                final message =
                    server.messages[server.messages.length - 1 - index];
                final time = DateTime.tryParse(message['at'] as String)
                    ?.toLocal();
                final date = time == null
                    ? ''
                    : time.toString().substring(0, 16);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        date,
                        style: const TextStyle(color: muted, fontSize: 13),
                      ),
                      const SizedBox(height: 6),
                      SelectableText(message['text'] as String),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    ),
  );

  Widget connectedPanel() {
    final clients = server.agentMcp.connectedClients();
    final states = server.agentMcp.states();
    return panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          heading(Icons.hub_outlined, 'AI 工具连接', violet),
          const SizedBox(height: 14),
          if (clients.isEmpty)
            Text(
              server.agentMcp.running ? '等待 AI 工具连接本机 MCP。' : '桌面 MCP 当前不可用。',
              style: const TextStyle(color: muted),
            )
          else
            for (final client in clients)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: background,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: ListTile(
                    dense: true,
                    title: Text(
                      client.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: StatusPill(
                      RemoteServer.labels[states[client.name]] ?? '待机',
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }

  static Widget stack(List<Widget> panels) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < panels.length; i++) ...[
        if (i > 0) const SizedBox(height: 16),
        panels[i],
      ],
    ],
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        const DesktopTitleBar(),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 780;
              return SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  wide ? 32 : 18,
                  28,
                  wide ? 32 : 18,
                  32,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1160),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          '服务概览',
                          style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -.6,
                          ),
                        ),
                        const SizedBox(height: 5),
                        const Text(
                          '管理本机服务、AI 工具会话和背屏连接。',
                          style: TextStyle(color: muted, fontSize: 14),
                        ),
                        const SizedBox(height: 24),
                        if (wide)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                flex: 6,
                                child: stack([
                                  servicePanel(),
                                  connectedPanel(),
                                  inboxPanel(),
                                ]),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                flex: 5,
                                child: stack([
                                  agentMcpPanel(),
                                  panel(
                                    ModelConnectionsPanel(
                                      server.modelConnections,
                                    ),
                                  ),
                                  pairingPanel(),
                                  lanPanel(),
                                ]),
                              ),
                            ],
                          )
                        else
                          stack([
                            servicePanel(),
                            connectedPanel(),
                            agentMcpPanel(),
                            panel(
                              ModelConnectionsPanel(server.modelConnections),
                            ),
                            pairingPanel(),
                            lanPanel(),
                            inboxPanel(),
                          ]),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    ),
  );
}
