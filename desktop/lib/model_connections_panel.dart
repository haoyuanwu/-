import 'dart:async';
import 'dart:io';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:robot_eyes_models/robot_eyes_models.dart';

import 'model_connections.dart';
import 'phone_model_bindings.dart';

class ModelConnectionsPanel extends StatefulWidget {
  const ModelConnectionsPanel(this.connections, this.phoneModels, {super.key});

  final ModelConnections connections;
  final PhoneModelBindings phoneModels;

  @override
  State<ModelConnectionsPanel> createState() => _ModelConnectionsPanelState();
}

enum _ModelType {
  file('本地模型文件', '导入本机 GGUF 文件', Icons.insert_drive_file_outlined),
  service('本地模型服务', '连接 Ollama 等 OpenAI 兼容服务', Icons.dns_outlined),
  cloud('云端模型', '配置 HTTPS 模型服务', Icons.cloud_outlined);

  const _ModelType(this.label, this.description, this.icon);

  final String label;
  final String description;
  final IconData icon;

  static _ModelType of(ModelProfile profile) => profile.localPath != null
      ? file
      : profile.isLocalService
      ? service
      : cloud;
}

class _ModelConnectionsPanelState extends State<ModelConnectionsPanel> {
  bool _syncingLocalModels = false;

  Future<void> _syncLocalModels(List<ModelProfile> profiles) async {
    setState(() => _syncingLocalModels = true);
    var synced = 0;
    final failures = <String>[];
    try {
      await Future.wait([
        for (final profile in profiles)
          () async {
            try {
              if (await widget.connections.syncLocalServiceModels(profile)) {
                synced++;
              }
            } on ModelFailure catch (error) {
              failures.add('${profile.name} · ${error.message}');
            } on FormatException catch (error) {
              failures.add('${profile.name} · ${error.message}');
            } on FileSystemException {
              failures.add('${profile.name} · 无法保存模型列表');
            }
          }(),
      ]);
    } finally {
      if (mounted) setState(() => _syncingLocalModels = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          [
            '已同步 $synced 个本地服务',
            ...failures.take(2),
            if (failures.length > 2) '另有 ${failures.length - 2} 个服务同步失败',
          ].join('\n'),
        ),
      ),
    );
  }

  Future<void> _edit([ModelProfile? profile]) async {
    final type = profile != null
        ? _ModelType.of(profile)
        : await showDialog<_ModelType>(
            context: context,
            builder: (dialog) => SimpleDialog(
              title: const Text('添加模型'),
              children: [
                for (final type in _ModelType.values)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(dialog, type),
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(type.icon),
                      title: Text(type.label),
                      subtitle: Text(type.description),
                    ),
                  ),
              ],
            ),
          );
    if (!mounted || type == null) return;
    await showDialog<void>(
      context: context,
      builder: (context) => _ModelEditor(widget.connections, type, profile),
    );
    if (mounted) setState(() {});
  }

  Future<void> _switchModelId(ModelProfile profile) async {
    final id = await _pickModelId(context, profile.modelIds, profile.model);
    if (!mounted || id == null) return;
    try {
      widget.connections.selectModelId(profile.id, id);
      setState(() {});
    } on FormatException catch (failure) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(failure.message)));
    } on FileSystemException {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('无法保存当前模型。')));
    }
  }

  Future<void> _remove(ModelProfile profile) async {
    if (!await _confirmModelRemoval(context, profile) || !mounted) return;
    try {
      setState(() => widget.connections.remove(profile.id));
    } on FileSystemException {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('无法删除模型，请检查文件权限。')));
    }
  }

  void _selectPhoneModel(PhoneModelBinding phone, String target) {
    try {
      if (target == 'refresh-catalog') {
        widget.phoneModels.refreshCatalog(phone.id);
      } else {
        widget.phoneModels.select(phone.id, target);
      }
      setState(() {});
    } on FileSystemException {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('无法保存手机模型设置。')));
    } on FormatException catch (error) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _resolveConflict(
    PhoneModelBinding phone,
    CloudModelConflict conflict,
  ) async {
    final choice = await showDialog<CloudResolution>(
      context: context,
      builder: (dialog) => SimpleDialog(
        title: const Text('云端模型配置不同'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '电脑 · ${conflict.desktop.model} · ${conflict.desktop.endpoint.host}',
                ),
                Text(
                  '手机 · ${conflict.phone.model} · ${conflict.phone.endpoint.host}',
                ),
                if (conflict.keysDiffer) const Text('两端的访问密钥不同。'),
              ],
            ),
          ),
          for (final (action, label) in [
            (CloudResolution.desktop, '以电脑为准'),
            (CloudResolution.phone, '以手机为准'),
            (CloudResolution.mergeDesktop, '合并，当前使用电脑配置'),
            (CloudResolution.mergePhone, '合并，当前使用手机配置'),
          ])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialog, action),
              child: Text(label),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('稍后处理'),
          ),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    try {
      setState(() => widget.phoneModels.resolve(phone.id, conflict, choice));
    } on FileSystemException {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('无法保存云端配置。')));
    } on FormatException catch (failure) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(failure.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final connections = widget.connections;
    final profiles = connections.profiles;
    final localServices = profiles
        .where((profile) => profile.isLocalService)
        .toList();
    final phones = widget.phoneModels;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            Text('电脑模型', style: Theme.of(context).textTheme.titleMedium),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _syncingLocalModels || localServices.isEmpty
                      ? null
                      : () => _syncLocalModels(localServices),
                  icon: const Icon(Icons.sync, size: 18),
                  label: Text(_syncingLocalModels ? '正在同步…' : '同步本地模型'),
                ),
                FilledButton.icon(
                  onPressed: _edit,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('添加模型'),
                ),
              ],
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
                profile.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                [
                  _ModelType.of(profile).label,
                  if (profile.isLocalService) ...[
                    if (profile.name != profile.model) profile.name,
                  ] else
                    profile.model,
                  for (final type in profile.mediaTypes) '${type.label}输入',
                  if (profile.id == profiles.first.id) '手机默认',
                  if (profile.isLocalService &&
                      profile.modelIds.isNotEmpty &&
                      !profile.modelIds.contains(profile.model))
                    '请选择可用模型',
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
                tooltip: '管理 ${profile.displayName}',
                itemBuilder: (_) => [
                  if (profile.id != profiles.first.id)
                    const PopupMenuItem(
                      value: 'default',
                      child: Text('设为手机默认'),
                    ),
                  if (profile.localPath == null && profile.modelIds.isNotEmpty)
                    const PopupMenuItem(
                      value: 'switch',
                      child: Text('切换模型 ID'),
                    ),
                  const PopupMenuItem(value: 'edit', child: Text('编辑')),
                  const PopupMenuItem(value: 'remove', child: Text('删除模型')),
                ],
                onSelected: (action) async {
                  if (action == 'edit') {
                    await _edit(profile);
                  } else if (action == 'switch') {
                    await _switchModelId(profile);
                  } else if (action == 'remove') {
                    await _remove(profile);
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
        const Divider(height: 28),
        Text('手机模型', style: Theme.of(context).textTheme.titleMedium),
        if (phones.phones.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('打开已配对的手机 App 后，可在这里查看并同步模型。'),
          ),
        for (final phone in phones.phones)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('手机 ${phone.id.substring(phone.id.length - 4)}'),
            subtitle: Text(
              [
                switch (phone.source) {
                  'desktop' => '通过电脑调用',
                  'cloud' => '云端直连 · ${phone.model}',
                  'lan' => '使用手机局域网模型',
                  _ => '使用手机本机模型',
                },
                if (phones.conflictFor(phone.id) != null)
                  '云端配置不同，等待处理'
                else if (phones.pending(phone))
                  '待同步 · ${phones.cloudProfile(phone.target)?.name ?? '电脑默认'}'
                else if (phones.catalogPending(phone))
                  '云端列表待同步到手机'
                else if (phones.online(phone))
                  '已同步'
                else
                  '手机未连接',
              ].join('\n'),
            ),
            trailing: switch (phones.conflictFor(phone.id)) {
              final conflict? => OutlinedButton(
                onPressed: () => _resolveConflict(phone, conflict),
                child: const Text('处理冲突'),
              ),
              null => PopupMenuButton<String>(
                tooltip: '同步模型到手机',
                onSelected: (target) => _selectPhoneModel(phone, target),
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'refresh-catalog',
                    child: Text('同步云端列表到手机'),
                  ),
                  const PopupMenuItem(value: '', child: Text('使用电脑默认')),
                  for (final profile in phones.cloudProfiles)
                    PopupMenuItem(
                      value: profile.id,
                      child: Text('直连 ${profile.name}'),
                    ),
                  if (phones.cloudProfiles.isEmpty)
                    const PopupMenuItem(
                      enabled: false,
                      child: Text('先添加一个 HTTPS 云端模型'),
                    ),
                ],
              ),
            },
          ),
      ],
    );
  }
}

Future<bool> _confirmModelRemoval(
  BuildContext context,
  ModelProfile profile,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('删除模型？'),
        content: Text(
          '从模型列表删除 ${profile.displayName}。'
          '${profile.localPath != null ? '模型文件会保留。' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('删除'),
          ),
        ],
      ),
    ) ??
    false;

class _ModelEditor extends StatefulWidget {
  const _ModelEditor(this.connections, this.type, this.profile);

  final ModelConnections connections;
  final _ModelType type;
  final ModelProfile? profile;

  @override
  State<_ModelEditor> createState() => _ModelEditorState();
}

class _ModelEditorState extends State<_ModelEditor> {
  late final _id = widget.profile?.id ?? ModelConnections.newId();
  late final _name = TextEditingController(text: widget.profile?.name);
  late final _address = TextEditingController(
    text:
        widget.profile?.endpoint.toString() ??
        (widget.type == _ModelType.service
            ? 'http://127.0.0.1:11434/v1'
            : null),
  );
  late final _model = TextEditingController(text: widget.profile?.model);
  late final _key = TextEditingController(text: widget.profile?.apiKey);
  bool get _file => widget.type == _ModelType.file;
  bool get _cloud => widget.type == _ModelType.cloud;
  bool get _localService => widget.type == _ModelType.service;
  late String? _localPath = widget.profile?.localPath;
  late String? _projectorPath = widget.profile?.projectorPath;
  String? _projectorName;
  late final _mediaTypes = {...?widget.profile?.mediaTypes};
  late List<String> _modelIds = widget.profile?.modelIds ?? const [];
  bool _testing = false;
  bool _fetching = false;
  bool _picking = false;
  bool get _busy => _testing || _fetching || _picking;
  bool? _testResult;
  String? _message;
  Future<String?>? _parameters;

  @override
  void initState() {
    super.initState();
    if (!_localService) return;
    if (widget.profile == null) {
      unawaited(_fetchModels(chooseMultiple: false));
    } else {
      _parameters = _readParameters();
    }
  }

  Future<String?> _readParameters() =>
      widget.connections.readLocalModelParameters(
        address: _address.text,
        model: _model.text,
        apiKey: _key.text,
      );

  void _refreshParameters() {
    final request = _readParameters();
    setState(() {
      _parameters = request;
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _model.dispose();
    _key.dispose();
    super.dispose();
  }

  ModelProfile _readProfile() {
    final localPath = _file ? _localPath : null;
    if (_file && localPath == null) {
      throw const FormatException('请先选择 GGUF 模型文件。');
    }
    final model = _model.text.trim();
    if (_localService && model.isEmpty) {
      throw const FormatException('请从服务列表选择模型，或填写模型 ID。');
    }
    final name = _name.text.trim();
    return ModelProfile(
      id: _id,
      name: _localService && name.isEmpty
          ? (model.length > 80 ? model.substring(0, 80) : model)
          : name,
      address: _address.text,
      model: model,
      apiKey: localPath == null ? _key.text : '',
      kind: _cloud ? 'cloud' : 'local',
      modelIds: _file ? const [] : _modelIds,
      localPath: localPath,
      projectorPath: localPath != null && _mediaTypes.isNotEmpty
          ? _projectorPath
          : null,
      mediaTypes: localPath != null ? _mediaTypes : const {},
    );
  }

  Future<void> _pickLocal({bool projector = false}) async {
    setState(() {
      _picking = true;
      _message = null;
    });
    try {
      final picked = await pickGgufFile(projector: projector);
      if (!mounted || picked == null) return;
      if (projector) {
        _projectorPath = picked.path;
        _projectorName = picked.name;
        _changed();
        return;
      }
      if (_localPath != picked.path) {
        _projectorPath = _projectorName = null;
      }
      _localPath = picked.path;
      _model.text = picked.name.length > 200
          ? picked.name.substring(0, 200)
          : picked.name;
      if (_name.text.trim().isEmpty) {
        _name.text = picked.name.length > 80
            ? picked.name.substring(0, 80)
            : picked.name;
      }
      _changed();
    } on FormatException catch (failure) {
      if (mounted) setState(() => _message = failure.message);
    } catch (_) {
      if (mounted) setState(() => _message = '无法访问模型文件，请检查文件权限和可用空间。');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _changed({bool clearCatalog = false, bool clearParameters = false}) =>
      setState(() {
        if (clearCatalog) _modelIds = const [];
        if (clearCatalog || clearParameters) _parameters = null;
        _testResult = null;
        _message = null;
      });

  Future<void> _chooseModelId() async {
    final id = await _pickModelId(context, _modelIds, _model.text);
    if (!mounted || id == null) return;
    _useModelId(id);
  }

  void _useModelId(String id) {
    _model.text = id;
    if (!_localService && _name.text.trim().isEmpty) {
      final host = Uri.tryParse(_address.text.trim())?.host ?? '';
      _name.text = host.length > 80 ? host.substring(0, 80) : host;
    }
    _changed();
    if (_localService) {
      _refreshParameters();
    }
  }

  Future<void> _fetchModels({bool chooseMultiple = true}) async {
    setState(() {
      _fetching = true;
      _message = null;
      _testResult = null;
    });
    try {
      final ids = await widget.connections.fetchModelIds(
        address: _address.text,
        apiKey: _key.text,
        cloud: _cloud,
      );
      if (!mounted) return;
      setState(() {
        _modelIds = ids;
        _fetching = false;
      });
      if (ids.length == 1) {
        _useModelId(ids.single);
      } else if (chooseMultiple) {
        await _chooseModelId();
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } on ModelFailure catch (error) {
      if (mounted) setState(() => _message = error.message);
    } finally {
      if (mounted && _fetching) {
        setState(() => _fetching = false);
      }
    }
  }

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

  Future<void> _save() async {
    try {
      final profile = _readProfile();
      if (profile.projectorPath case final path?) {
        setState(() {
          _testing = true;
          _message = '正在检测模型输入能力…';
        });
        await checkGgufMediaSupport(
          profile.localPath!,
          path,
          profile.mediaTypes,
        );
        if (!mounted) return;
      }
      widget.connections.save(profile, tested: _testResult);
      Navigator.of(context).pop();
    } on FormatException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } on FileSystemException {
      if (mounted) setState(() => _message = '无法保存模型连接，请检查文件权限。');
    } finally {
      if (mounted && _testing) setState(() => _testing = false);
    }
  }

  Future<void> _remove() async {
    if (!await _confirmModelRemoval(context, widget.profile!) || !mounted) {
      return;
    }
    try {
      widget.connections.remove(_id);
      Navigator.of(context).pop();
    } on FileSystemException {
      setState(() => _message = '无法删除模型，请检查文件权限。');
    }
  }

  Widget _input(
    TextEditingController controller,
    String label, {
    String? hint,
    bool secret = false,
    bool clearCatalog = false,
    bool clearParameters = false,
  }) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: TextField(
      controller: controller,
      enabled: !_busy,
      obscureText: secret,
      autocorrect: !secret,
      enableSuggestions: !secret,
      onChanged: (_) => _changed(
        clearCatalog: clearCatalog,
        clearParameters: clearParameters,
      ),
      decoration: InputDecoration(labelText: label, hintText: hint),
    ),
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('${widget.profile == null ? '添加' : '编辑'}${widget.type.label}'),
    scrollable: true,
    content: SizedBox(
      width: 440,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _input(_name, _localService ? '连接名称（可选）' : '显示名称'),
          if (_file) ...[
            const SizedBox(height: 12),
            const Text('对话主模型'),
            if (_localPath != null) Text(_model.text),
            OutlinedButton.icon(
              onPressed: _busy ? null : _pickLocal,
              icon: const Icon(Icons.insert_drive_file_outlined, size: 18),
              label: Text(_picking ? '正在打开模型…' : '选择 GGUF 主模型'),
            ),
            const SizedBox(height: 12),
            const Text('输入能力'),
            const Text('文本输入默认启用'),
            for (final type in GgufMediaType.values)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${type.label}输入'),
                value: _mediaTypes.contains(type),
                onChanged: _busy || _localPath == null
                    ? null
                    : (enabled) {
                        if (enabled == true) {
                          _mediaTypes.add(type);
                        } else {
                          _mediaTypes.remove(type);
                        }
                        _changed();
                      },
              ),
            if (_localPath != null && _mediaTypes.isNotEmpty) ...[
              const Text('请手动选择与主模型配套的 mmproj 文件。保存时会检测所选能力。'),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _pickLocal(projector: true),
                icon: const Icon(Icons.extension_outlined),
                label: Text(
                  _projectorPath == null ? '选择 mmproj 文件' : '更换 mmproj 文件',
                ),
              ),
              if (_projectorPath != null) Text(_projectorName ?? '已配置 mmproj'),
            ],
          ],
          if (!_file) ...[
            _input(
              _address,
              '服务地址',
              clearCatalog: true,
              hint: _cloud
                  ? 'https://api.openai.com/v1'
                  : 'http://127.0.0.1:11434/v1',
            ),
            _input(_key, '访问密钥（可选）', secret: true, clearCatalog: true),
            _input(_model, '模型 ID', clearParameters: true),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : _fetchModels,
                  icon: const Icon(Icons.cloud_download_outlined, size: 18),
                  label: Text(_fetching ? '正在获取…' : '获取模型列表'),
                ),
                if (_modelIds.isNotEmpty)
                  TextButton(
                    onPressed: _busy ? null : _chooseModelId,
                    child: Text('选择模型（${_modelIds.length} 个）'),
                  ),
              ],
            ),
            if (_localService) ...[
              const Divider(height: 24),
              const Text('模型运行参数（只读）'),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: _busy || _model.text.trim().isEmpty
                      ? null
                      : _refreshParameters,
                  icon: const Icon(Icons.sync, size: 18),
                  label: const Text('读取模型参数'),
                ),
              ),
              if (_parameters case final parameters?)
                FutureBuilder<String?>(
                  future: parameters,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const LinearProgressIndicator(
                        semanticsLabel: '正在读取模型参数',
                      );
                    }
                    final error = snapshot.error;
                    if (error != null) {
                      return Text(switch (error) {
                        FormatException(:final message) => message,
                        ModelFailure(:final message) => message,
                        _ => '无法读取模型参数。',
                      });
                    }
                    return switch (snapshot.data) {
                      null => const Text('服务未提供此模型的参数。'),
                      '' => const Text('模型使用服务默认参数。'),
                      final value => SelectableText(
                        value,
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                    };
                  },
                ),
            ],
          ],
          if (_busy) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(
              semanticsLabel: _picking
                  ? '正在打开模型文件'
                  : _fetching
                  ? '正在获取模型列表'
                  : '正在测试模型连接',
            ),
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
          onPressed: _busy ? null : _remove,
          child: const Text('删除模型'),
        ),
      TextButton(onPressed: _busy ? null : _test, child: const Text('测试连接')),
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('关闭'),
      ),
      FilledButton(onPressed: _busy ? null : _save, child: const Text('保存')),
    ],
  );
}

Future<String?> _pickModelId(
  BuildContext context,
  List<String> ids,
  String selected,
) => showDialog<String>(
  context: context,
  builder: (_) => _ModelIdPicker(ids, selected.trim()),
);

class _ModelIdPicker extends StatefulWidget {
  const _ModelIdPicker(this.ids, this.selected);

  final List<String> ids;
  final String selected;

  @override
  State<_ModelIdPicker> createState() => _ModelIdPickerState();
}

class _ModelIdPickerState extends State<_ModelIdPicker> {
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final ids = widget.ids
        .where((id) => id.toLowerCase().contains(_search))
        .toList();
    return AlertDialog(
      title: const Text('选择模型 ID'),
      content: SizedBox(
        width: 440,
        height: 320,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '搜索模型',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (text) =>
                  setState(() => _search = text.trim().toLowerCase()),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ids.isEmpty
                  ? const Center(child: Text('没有匹配的模型'))
                  : ListView.builder(
                      itemCount: ids.length,
                      itemBuilder: (_, index) {
                        final id = ids[index];
                        return ListTile(
                          selected: id == widget.selected,
                          title: Text(id),
                          trailing: id == widget.selected
                              ? const Icon(Icons.check_rounded)
                              : null,
                          onTap: () => Navigator.pop(context, id),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
