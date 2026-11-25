import 'dart:io';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import 'model_connections.dart';

class ModelConnectionsPanel extends StatefulWidget {
  const ModelConnectionsPanel(this.connections, {super.key});

  final ModelConnections connections;

  @override
  State<ModelConnectionsPanel> createState() => _ModelConnectionsPanelState();
}

class _ModelConnectionsPanelState extends State<ModelConnectionsPanel> {
  Future<void> _edit([ModelProfile? profile]) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _ModelEditor(widget.connections, profile),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final connections = widget.connections;
    final profiles = connections.profiles;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            Text('模型连接', style: Theme.of(context).textTheme.titleLarge),
            OutlinedButton.icon(
              onPressed: _edit,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加模型'),
            ),
          ],
        ),
        if (connections.loadError case final String error)
          Text(
            error,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          )
        else if (profiles.isEmpty)
          const Text('添加模型后，手机会使用这里设定的默认模型。'),
        for (final profile in profiles)
          Material(
            type: MaterialType.transparency,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                profile.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                [
                  profile.kind == 'local' ? '本地' : '云端',
                  profile.model,
                  if (profile.id == profiles.first.id) '手机默认',
                  switch (connections.availability(profile.id)) {
                    true => '可用',
                    false => '连接失败',
                    null => '未验证',
                  },
                ].join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: PopupMenuButton<String>(
                tooltip: '管理 ${profile.name}',
                itemBuilder: (_) => [
                  if (profile.id != profiles.first.id)
                    const PopupMenuItem(
                      value: 'default',
                      child: Text('设为手机默认'),
                    ),
                  const PopupMenuItem(value: 'edit', child: Text('编辑')),
                ],
                onSelected: (action) async {
                  if (action == 'edit') {
                    await _edit(profile);
                  } else {
                    try {
                      setState(() => connections.setDefault(profile.id));
                    } on FileSystemException {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('无法保存默认模型。')),
                        );
                      }
                    }
                  }
                },
              ),
              onTap: () => _edit(profile),
            ),
          ),
      ],
    );
  }
}

class _ModelEditor extends StatefulWidget {
  const _ModelEditor(this.connections, this.profile);

  final ModelConnections connections;
  final ModelProfile? profile;

  @override
  State<_ModelEditor> createState() => _ModelEditorState();
}

class _ModelEditorState extends State<_ModelEditor> {
  late final _id = widget.profile?.id ?? ModelConnections.newId();
  late final _name = TextEditingController(text: widget.profile?.name);
  late final _address = TextEditingController(
    text: widget.profile?.endpoint.toString(),
  );
  late final _model = TextEditingController(text: widget.profile?.model);
  late final _key = TextEditingController(text: widget.profile?.apiKey);
  late String _kind = widget.profile?.kind ?? 'local';
  bool _testing = false;
  bool? _testResult;
  String? _message;

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _model.dispose();
    _key.dispose();
    super.dispose();
  }

  ModelProfile _readProfile() => ModelProfile(
    id: _id,
    name: _name.text,
    address: _address.text,
    model: _model.text,
    apiKey: _key.text,
    kind: _kind,
  );

  void _changed() => setState(() {
    _testResult = null;
    _message = null;
  });

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
      _message = null;
    });
    try {
      final profile = _readProfile();
      await widget.connections.test(profile);
      if (!mounted) return;
      _testResult = true;
      _message = '已收到模型回复。';
    } on FormatException catch (error) {
      _message = error.message;
    } on ModelFailure catch (error) {
      _testResult = false;
      _message = error.message;
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  void _save() {
    try {
      widget.connections.save(_readProfile(), tested: _testResult);
      Navigator.of(context).pop();
    } on FormatException catch (error) {
      setState(() => _message = error.message);
    } on FileSystemException {
      setState(() => _message = '无法保存模型连接，请检查文件权限。');
    }
  }

  Future<void> _remove() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除模型连接？'),
        content: Text(widget.profile!.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    try {
      widget.connections.remove(_id);
      Navigator.of(context).pop();
    } on FileSystemException {
      setState(() => _message = '无法移除模型连接，请检查文件权限。');
    }
  }

  Widget _input(
    TextEditingController controller,
    String label, {
    String? hint,
    bool secret = false,
  }) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: TextField(
      controller: controller,
      enabled: !_testing,
      obscureText: secret,
      autocorrect: !secret,
      enableSuggestions: !secret,
      onChanged: (_) => _changed(),
      decoration: InputDecoration(labelText: label, hintText: hint),
    ),
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.profile == null ? '添加模型' : '编辑模型'),
    scrollable: true,
    content: SizedBox(
      width: 440,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'local', label: Text('本地模型')),
              ButtonSegment(value: 'cloud', label: Text('云端模型')),
            ],
            selected: {_kind},
            onSelectionChanged: _testing
                ? null
                : (values) {
                    _kind = values.single;
                    _changed();
                  },
          ),
          _input(_name, '显示名称'),
          _input(
            _address,
            '服务地址',
            hint: _kind == 'local'
                ? 'http://127.0.0.1:11434/v1'
                : 'https://api.openai.com/v1',
          ),
          _input(_model, '模型 ID'),
          _input(_key, '访问密钥（可选）', secret: true),
          if (_testing) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(semanticsLabel: '正在测试模型连接'),
          ],
          if (_message case final String message) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(
                message,
                style: TextStyle(
                  color: _testResult == true
                      ? null
                      : Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          ],
        ],
      ),
    ),
    actions: [
      if (widget.profile != null)
        TextButton(
          onPressed: _testing ? null : _remove,
          child: const Text('移除'),
        ),
      TextButton(onPressed: _testing ? null : _test, child: const Text('测试连接')),
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('关闭'),
      ),
      FilledButton(onPressed: _testing ? null : _save, child: const Text('保存')),
    ],
  );
}
