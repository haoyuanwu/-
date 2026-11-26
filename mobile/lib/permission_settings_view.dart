// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('com.reareyes/mobile');

class PermissionSettingsPage extends StatefulWidget {
  const PermissionSettingsPage({super.key});

  @override
  State<PermissionSettingsPage> createState() => _PermissionSettingsPageState();
}

class _PermissionSettingsPageState extends State<PermissionSettingsPage>
    with WidgetsBindingObserver {
  Map<String, bool?>? _status;
  bool _busy = false;

  static const _permissions = [
    ('notificationAccess', '通知访问', '读取其他 App 和短信的通知'),
    ('autoStart', '后台自启动', '允许小米系统在后台启动通知监听'),
    (
      'floatingNotifications',
      '系统悬浮通知',
      '在系统设置中找到「悬浮通知」，可单独关闭微信等 App 的弹窗，保留消息接收和通知栏记录',
    ),
    ('microphone', '麦克风', '使用语音对话'),
    ('speech', '语音识别', '将录音转换为文字'),
    ('contacts', '联系人', '按联系人筛选提醒'),
    ('notifications', '应用通知', '显示 Robot Eyes 的系统通知'),
    ('shizuku', 'Shizuku 授权', '在小米背屏显示电子眼'),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    try {
      final status = await _channel.invokeMapMethod<String, bool?>(
        'permissionStatus',
      );
      if (mounted) setState(() => _status = status ?? {});
    } on PlatformException {
      if (mounted) setState(() => _status = {});
    } on MissingPluginException {
      if (mounted) setState(() => _status = {});
    }
  }

  Future<void> _open(String id) async {
    setState(() => _busy = true);
    try {
      await _channel.invokeMethod<void>('openPermission', id);
      await _refresh();
    } on PlatformException {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法打开权限设置')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return Scaffold(
      appBar: AppBar(title: const Text('权限设置')),
      body: SafeArea(
        child: status == null
            ? const Center(child: CircularProgressIndicator())
            : status.isEmpty
            ? const Center(child: Text('当前无法读取权限状态'))
            : ListView(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  for (final (id, title, purpose) in _permissions)
                    if (status.containsKey(id))
                      ListTile(
                        title: Text(title),
                        subtitle: Text(
                          [
                            purpose,
                            switch (status[id]) {
                              true
                                  when id == 'notificationAccess' &&
                                      status['listenerConnected'] == false =>
                                '已授权，监听未连接',
                              true => '已开启',
                              false => '未开启',
                              null when id == 'floatingNotifications' => '',
                              null => '请在系统设置中确认',
                            },
                          ].where((line) => line.isNotEmpty).join('\n'),
                        ),
                        trailing: TextButton(
                          onPressed: _busy ? null : () => _open(id),
                          child: const Text('设置'),
                        ),
                      ),
                ],
              ),
      ),
    );
  }
}
