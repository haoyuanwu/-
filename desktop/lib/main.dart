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
import 'phone_links.dart';
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

enum _DashboardPage {
  overview('概览', Icons.space_dashboard_outlined, Icons.space_dashboard_rounded),
  models('模型', Icons.tune_outlined, Icons.tune_rounded),
  phone('手机连接', Icons.phone_android_outlined, Icons.phone_android_rounded),
  tools('AI 工具', Icons.hub_outlined, Icons.hub_rounded);

  const _DashboardPage(this.label, this.icon, this.selectedIcon);
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

enum _PhonePage {
  lan('手机局域网', Icons.wifi),
  tailscale('Tailscale 连接', Icons.link_rounded);

  const _PhonePage(this.label, this.icon);
  final String label;
  final IconData icon;
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
  String get lanLabel => _phoneStatus(server.phoneLinks.lanDevices);

  String _phoneStatus(List<PhoneDevice> devices) {
    final count = devices.where((device) => device.connected).length;
    if (!server.running) return '服务已停止';
    if (count > 0) return '$count 台已连接';
    return devices.isEmpty ? '未配对' : '未连接';
  }

  String get adbLabel => switch (server.phoneLinks.adbTransport) {
    'USB' => 'USB 已连接',
    'LAN' => '无线调试已连接',
    _ => server.running ? '未连接' : '服务已停止',
  };
  Timer? _endpointRefresh;
  bool _detectingEndpoint = false;
  bool busy = false;
  bool checking = false;
  bool? _startupEnabled;
  bool _startupBusy = false;
  bool _startupFailed = false;
  List<String> _publishedRows = const [];
  bool? _publishedBusy;
  bool? _publishedRunning;
  _DashboardPage _page = _DashboardPage.overview;
  _PhonePage? _phonePage;

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
      '手机局域网 · $lanLabel',
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
    if (Platform.isWindows) unawaited(_updateStartup());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(toggleService());
        unawaited(detectEndpoint());
        _endpointRefresh = Timer.periodic(
          const Duration(seconds: 5),
          (_) => unawaited(detectEndpoint(background: true)),
        );
      }
    });
  }

  Future<void> _updateStartup([bool? enabled]) async {
    if (_startupBusy) return;
    setState(() => _startupBusy = true);
    bool? current;
    try {
      current = await desktopChannel.invokeMethod<bool>(
        enabled == null ? 'getStartup' : 'setStartup',
        enabled,
      );
    } on PlatformException {
      // Retain the last confirmed setting if Windows rejects the change.
    } on MissingPluginException {
      // The Windows runner provides the setting through the desktop channel.
    }
    if (!mounted) return;
    setState(() {
      _startupEnabled = current ?? _startupEnabled;
      _startupFailed = current == null;
      _startupBusy = false;
    });
  }

  @override
  void dispose() {
    _endpointRefresh?.cancel();
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
      failure = '无法访问本地数据，请检查文件权限。';
    } on FormatException {
      failure = '本地配对密钥无效，请检查 pairing.key。';
    } finally {
      if (mounted) {
        setState(() => busy = false);
        publishTray();
      }
    }
  }

  Future<void> detectEndpoint({bool background = false}) async {
    if (!background && !checking) {
      setState(() => checking = true);
      publishTray();
    }
    if (_detectingEndpoint) return;
    _detectingEndpoint = true;
    TailscaleStatus? result;
    try {
      result = await detectTailscale(RemoteServer.port, RemoteServer.servePort);
    } finally {
      _detectingEndpoint = false;
      if (mounted && (checking || tailscale != result)) {
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
        jsonEncode({
          'url': address,
          'token': server.token,
          'desktopId': server.desktopId,
          'desktopName': server.desktopName,
        }),
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

  Widget panel(Widget child) => Material(
    color: surface,
    shape: RoundedRectangleBorder(
      side: const BorderSide(color: line),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Padding(padding: const EdgeInsets.all(20), child: child),
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
          heading(Icons.monitor_rounded, '电脑服务'),
          const SizedBox(height: 12),
          const Text(
            '127.0.0.1:${RemoteServer.port}',
            style: TextStyle(
              color: muted,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const Divider(height: 30, color: line),
          Wrap(
            spacing: 36,
            runSpacing: 14,
            children: [
              _serviceMetric(
                '任务状态',
                server.running
                    ? RemoteServer.labels[status['state']] ?? '待机'
                    : '—',
              ),
              _serviceMetric('5 小时剩余', remaining('five')),
              _serviceMetric('周剩余', remaining('week')),
            ],
          ),
          if (Platform.isWindows) ...[
            const Divider(height: 30, color: line),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('开机自启'),
              subtitle: const Text('登录 Windows 后在托盘启动电脑服务'),
              value: _startupEnabled ?? false,
              onChanged: _startupBusy || _startupEnabled == null
                  ? null
                  : (enabled) => unawaited(_updateStartup(enabled)),
            ),
            if (_startupFailed)
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '无法更新开机自启设置',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  TextButton(
                    onPressed: _startupBusy ? null : () => _updateStartup(),
                    child: const Text('重新读取'),
                  ),
                ],
              ),
          ],
        ],
      ),
    );
  }

  Widget _serviceMetric(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(color: muted, fontSize: 13)),
      const SizedBox(height: 4),
      Text(
        value,
        style: const TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w700,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    ],
  );

  Widget pairingPanel() {
    final command = setupCommand;
    final needsServe = tailscale?.state == TailscaleState.serveMissing;
    return panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          heading(Icons.link_rounded, 'Tailscale 服务'),
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

  Future<void> showLanCode() async {
    var code = server.createLanCode();
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('局域网配对码'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  code,
                  style: const TextStyle(
                    color: cyan,
                    fontSize: 28,
                    letterSpacing: 4,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 12),
                const Text('在手机 App 的「局域网」搜索并选择这台电脑，然后输入配对码。配对码 5 分钟内可用一次。'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => update(() => code = server.createLanCode()),
              child: const Text('重新生成'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('完成'),
            ),
          ],
        ),
      ),
    );
  }

  List<PhoneDevice> _phoneDevices(_PhonePage page) => switch (page) {
    _PhonePage.lan => server.phoneLinks.lanDevices,
    _PhonePage.tailscale => server.phoneLinks.tailscaleDevices,
  };

  Widget _phoneEntry(_PhonePage page) {
    final devices = _phoneDevices(page);
    final online = devices.where((device) => device.connected).toList();
    return panel(
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(page.icon, color: cyan),
        title: Text(page.label),
        subtitle: online.isEmpty
            ? null
            : Text(online.map((device) => device.name).join('、')),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            StatusPill(_phoneStatus(devices), active: online.isNotEmpty),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right_rounded, size: 19),
          ],
        ),
        onTap: () => setState(() => _phonePage = page),
      ),
    );
  }

  Future<void> _forgetLanPhone(PhoneDevice device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('移除 ${device.name} 的局域网配对？'),
        content: Text('${device.detail} · 移除后可以重新配对。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    try {
      device.forget?.call();
    } on FileSystemException {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法移除配对，请检查文件权限。')),
      );
    }
  }

  Widget _phoneList(_PhonePage page) {
    final devices = _phoneDevices(page);
    return panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              heading(Icons.phone_android_rounded, '手机设备'),
              StatusPill(
                _phoneStatus(devices),
                active: devices.any((device) => device.connected),
              ),
              if (page == _PhonePage.lan)
                FilledButton.icon(
                  onPressed: server.running ? showLanCode : null,
                  icon: const Icon(Icons.link, size: 18),
                  label: const Text('生成配对码'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (devices.isEmpty)
            const Text('暂无已配对手机', style: TextStyle(color: muted)),
          for (final connected in [true, false])
            for (final device in devices.where((row) => row.connected == connected))
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.phone_android_outlined, size: 20),
                title: Text(device.name),
                subtitle: Text(device.detail),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    StatusPill(
                      device.connected ? '已连接' : '未连接',
                      active: device.connected,
                    ),
                    if (device.forget != null)
                      IconButton(
                        tooltip: '移除局域网配对',
                        onPressed: () => _forgetLanPhone(device),
                        icon: const Icon(Icons.link_off, size: 19),
                      ),
                  ],
                ),
              ),
          if (page == _PhonePage.lan) ...[
            const SizedBox(height: 8),
            Text('ADB · $adbLabel', style: const TextStyle(color: muted)),
          ],
        ],
      ),
    );
  }

  Widget _phoneContent() {
    final page = _phonePage;
    if (page == null) {
      return stack([for (final item in _PhonePage.values) _phoneEntry(item)]);
    }
    return stack([
      _phoneList(page),
      if (page == _PhonePage.tailscale) pairingPanel(),
    ]);
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

  Widget connectedPanel() {
    final clients = {
      for (final client in server.agentMcp.connectedClients())
        client.name.toLowerCase(),
    };
    final states = server.agentStates;
    return panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          heading(Icons.hub_outlined, 'AI 工具连接', violet),
          const SizedBox(height: 14),
          if (states.isEmpty)
            Text(
              server.agentMcp.running ? '等待 AI 工具连接本机 MCP。' : '桌面 MCP 当前不可用。',
              style: const TextStyle(color: muted),
            )
          else
            for (final MapEntry(:key, :value) in states.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: background,
                  borderRadius: BorderRadius.circular(8),
                  child: ListTile(
                    dense: true,
                    title: Text(
                      key,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      clients.contains(key.toLowerCase())
                          ? 'MCP 已连接'
                          : key == 'Codex'
                          ? '本机状态'
                          : '状态上报',
                    ),
                    trailing: StatusPill(
                      RemoteServer.labels[value] ?? '待机',
                      active: value == 'THINKING' || value == 'QUESTION',
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

  Widget _workspaceHeader() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 14),
    child: Row(
      children: [
        if (_page == _DashboardPage.phone && _phonePage != null)
          IconButton(
            tooltip: '返回手机连接',
            onPressed: () => setState(() => _phonePage = null),
            icon: const Icon(Icons.arrow_back),
          ),
        Expanded(
          child: Semantics(
            header: true,
            child: Text(
              _page == _DashboardPage.phone
                  ? _phonePage?.label ?? _page.label
                  : _page.label,
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
            ),
          ),
        ),
        const SizedBox(width: 12),
        StatusPill(
          busy
              ? '切换中'
              : server.running
              ? '服务运行中'
              : '服务已停止',
          active: server.running && !busy,
        ),
        const SizedBox(width: 10),
        if (server.running)
          OutlinedButton(
            onPressed: busy ? null : toggleService,
            child: const Text('停止服务'),
          )
        else
          FilledButton(
            onPressed: busy ? null : toggleService,
            child: const Text('启动服务'),
          ),
      ],
    ),
  );

  Widget _pageContent() => switch (_page) {
    _DashboardPage.overview => stack([servicePanel(), connectedPanel()]),
    _DashboardPage.models => panel(
      ModelConnectionsPanel(server.modelConnections, server.phoneModels),
    ),
    _DashboardPage.phone => _phoneContent(),
    _DashboardPage.tools => stack([agentMcpPanel(), connectedPanel()]),
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        const DesktopTitleBar(),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 800;
              final gutter = wide ? 28.0 : 16.0;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  NavigationRail(
                    backgroundColor: surface,
                    extended: wide,
                    minWidth: 84,
                    minExtendedWidth: 160,
                    labelType: wide
                        ? NavigationRailLabelType.none
                        : NavigationRailLabelType.all,
                    leading: const SizedBox(height: 8),
                    scrollable: true,
                    selectedIndex: _page.index,
                    useIndicator: true,
                    indicatorColor: cyan.withValues(alpha: .15),
                    selectedIconTheme: const IconThemeData(
                      color: cyan,
                      size: 22,
                    ),
                    unselectedIconTheme: const IconThemeData(
                      color: muted,
                      size: 22,
                    ),
                    selectedLabelTextStyle: const TextStyle(
                      color: cyan,
                      fontWeight: FontWeight.w600,
                    ),
                    unselectedLabelTextStyle: const TextStyle(color: muted),
                    onDestinationSelected: (index) =>
                        setState(() {
                          _page = _DashboardPage.values[index];
                          _phonePage = null;
                        }),
                    destinations: [
                      for (final page in _DashboardPage.values)
                        NavigationRailDestination(
                          icon: Icon(page.icon),
                          selectedIcon: Icon(page.selectedIcon),
                          label: Text(page.label),
                        ),
                    ],
                  ),
                  const VerticalDivider(width: 1, color: line),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: gutter),
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 980),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _workspaceHeader(),
                              const Divider(height: 1, color: line),
                              if (failure case final error?)
                                Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: Text(
                                    error,
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .error,
                                    ),
                                  ),
                                ),
                              Expanded(
                                child: SingleChildScrollView(
                                  key: PageStorageKey((_page, _phonePage)),
                                  padding: const EdgeInsets.only(
                                    top: 16,
                                    bottom: 24,
                                  ),
                                  child: _pageContent(),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    ),
  );
}
