import 'dart:async';

import 'package:flutter/material.dart';
import 'package:robot_eyes_models/robot_eyes_models.dart';

import 'design.dart';
import 'interaction.dart';
import 'phone_model.dart';
import 'settings_page.dart';

Future<void> openModelSettings(
  BuildContext context,
  RobotInteraction interaction,
) {
  unawaited(interaction.syncPhoneModel(force: true));
  return openSettingsPage(
    context,
    '模型设置',
    (context) => ListenableBuilder(
      listenable: interaction,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionTitle('对话使用的模型'),
          const SizedBox(height: 12),
          SettingsGroup([
            ListTile(
              leading: const Icon(Icons.desktop_windows_outlined, color: cyan),
              title: Text(ModelSource.desktop.label),
              subtitle: Text(
                interaction.modelSource == ModelSource.desktop &&
                        interaction.model != null
                    ? '当前使用 · ${interaction.model!.name}'
                    : '使用配对电脑的默认模型',
              ),
              selected: interaction.modelSource == ModelSource.desktop,
              trailing: interaction.modelSource == ModelSource.desktop
                  ? const Icon(Icons.check_rounded, color: cyan)
                  : null,
              onTap: interaction.modelSource == ModelSource.desktop
                  ? null
                  : () => _useModel(context, interaction, ModelSource.desktop),
            ),
            for (final source in [ModelSource.cloud, ModelSource.local])
              SettingsEntry(
                source == ModelSource.cloud
                    ? Icons.cloud_outlined
                    : Icons.smartphone_outlined,
                source.label,
                () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => _ModelList(interaction, source),
                  ),
                ),
                detail: interaction.modelSource == source
                    ? '当前使用 · ${interaction.phoneModel?.model ?? '待配置'}'
                    : null,
              ),
          ]),
          _ModelSyncStatus(interaction),
        ],
      ),
    ),
  );
}

Future<void> _useModel(
  BuildContext context,
  RobotInteraction interaction,
  ModelSource source, {
  PhoneModel? profile,
  bool add = false,
}) async {
  await interaction.cancelAnswer();
  if (context.mounted) interaction.configureModel(source, profile, add: add);
}

class _ModelSyncStatus extends StatelessWidget {
  const _ModelSyncStatus(this.interaction);
  final RobotInteraction interaction;

  @override
  Widget build(BuildContext context) {
    final label = interaction.phoneModelSyncLabel;
    final conflict = interaction.phoneModelConflict;
    final error = interaction.phoneModelSyncError;
    final syncing = interaction.phoneModelSyncing;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            syncing ? '正在同步云端模型…' : error ?? label ?? '请先在「桌面模型连接」完成配对。',
            style: const TextStyle(color: secondaryInk),
          ),
          if (conflict != null) ...[
            Text(
              '电脑 · ${conflict.desktopModel} · ${conflict.desktopHost}\n'
              '手机 · ${conflict.phoneModel} · ${conflict.phoneHost}',
            ),
            if (conflict.keysDiffer) const Text('两端的访问密钥不同。'),
            const Text('请在电脑的「模型连接 → 手机模型」处理冲突。'),
          ] else if (error == null && !syncing && label == '已与电脑同步') ...[
            Text('已从电脑同步 ${interaction.savedCloudModels.length} 个云端配置'),
            if (interaction.needsDesktopCatalogUpdate)
              const Text('更新桌面端后可同步完整云端列表。'),
          ],
          TextButton.icon(
            onPressed: !interaction.canSyncPhoneModel || syncing
                ? null
                : () => interaction.syncPhoneModel(force: true),
            icon: const Icon(Icons.sync),
            label: const Text('同步云端模型'),
          ),
        ],
      ),
    );
  }
}

class _ModelList extends StatefulWidget {
  const _ModelList(this.interaction, this.source);
  final RobotInteraction interaction;
  final ModelSource source;

  @override
  State<_ModelList> createState() => _ModelListState();
}

class _ModelListState extends State<_ModelList> {
  bool _busy = false;

  bool get _cloud => widget.source == ModelSource.cloud;

  @override
  void initState() {
    super.initState();
    if (_cloud) unawaited(widget.interaction.syncPhoneModel(force: true));
  }

  bool _isSelected(PhoneModel profile) {
    final interaction = widget.interaction;
    final active = interaction.phoneModel;
    if (interaction.modelSource != widget.source || active == null) {
      return false;
    }
    return _cloud
        ? profile.sameCloud(active)
        : profile.localPath == active.localPath;
  }

  Future<void> _select(PhoneModel profile, {bool add = false}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _useModel(
        context,
        widget.interaction,
        widget.source,
        profile: profile,
        add: add,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _modelTile(PhoneModel profile, bool disabled) {
    final selected = _isSelected(profile);
    return ListTile(
      selected: selected,
      leading: Icon(
        selected
            ? Icons.check_rounded
            : _cloud
            ? Icons.cloud_outlined
            : Icons.insert_drive_file_outlined,
        color: selected ? cyan : secondaryInk,
      ),
      title: Text(profile.model),
      subtitle: Text(
        _cloud
            ? profile.endpoint.host
            : [
                '文本',
                for (final type in profile.mediaTypes) '${type.label}输入',
              ].join(' · '),
      ),
      trailing: !_cloud
          ? PopupMenuButton<String>(
              tooltip: '管理 ${profile.model}',
              enabled: !disabled,
              onSelected: (action) async {
                if (action == 'edit') {
                  await _editLocal(profile);
                } else {
                  await _removeLocal(profile);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('编辑本机模型能力')),
                PopupMenuItem(value: 'remove', child: Text('删除模型')),
              ],
            )
          : selected
          ? IconButton(
              tooltip: '编辑当前云端配置',
              icon: const Icon(Icons.edit_outlined),
              onPressed: disabled ? null : () => _editCloud(profile),
            )
          : null,
      onTap: disabled || selected ? null : () => _select(profile),
    );
  }

  Future<void> _editCloud([PhoneModel? profile]) async {
    final saved = await showDialog<PhoneModel>(
      context: context,
      builder: (_) => _CloudModelDialog(widget.interaction, profile),
    );
    if (!mounted || saved == null) return;
    // A sync update may have changed which desktop profile is bound while editing.
    await _select(saved, add: profile == null || !_isSelected(profile));
  }

  Future<void> _editLocal([PhoneModel? profile]) async {
    final saved = await showDialog<PhoneModel>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _LocalModelDialog(profile),
    );
    if (saved == null) return;
    widget.interaction.rememberLocalModel(saved);
    if (mounted) await _select(saved);
  }

  Future<void> _removeLocal(PhoneModel profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('删除本机模型？'),
        content: Text(
          '从本机模型列表删除 ${profile.model}，保留模型文件。'
          '${_isSelected(profile) ? '删除后将切换到电脑默认模型。' : ''}',
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
    );
    if (!mounted || confirmed != true || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.interaction.removeLocalModel(profile);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final interaction = widget.interaction;
    final disabled = _busy;
    return SettingsPage(
      widget.source.label,
      (_) => ListenableBuilder(
        listenable: interaction,
        builder: (context, _) {
          final profiles = _cloud
              ? interaction.cloudProfiles
              : interaction.localProfiles;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '当前使用 · ${interaction.modelLabel}',
                style: const TextStyle(color: cyan),
              ),
              const SizedBox(height: 12),
              if (profiles.isEmpty)
                Text(
                  _cloud
                      ? '暂无云端模型，点右上角「添加」配置服务。'
                      : supportsGgufFiles
                      ? '暂无本机模型，点右上角「添加」导入 GGUF 文件。'
                      : '当前平台不支持导入 GGUF 文件。',
                  style: const TextStyle(color: secondaryInk),
                ),
              if (profiles.isNotEmpty)
                SettingsGroup([
                  for (final profile in profiles) _modelTile(profile, disabled),
                ]),
              if (_cloud) _ModelSyncStatus(interaction),
            ],
          );
        },
      ),
      actions: [
        TextButton.icon(
          onPressed: disabled
              ? null
              : _cloud
              ? () => _editCloud()
              : supportsGgufFiles
              ? () => _editLocal()
              : null,
          icon: const Icon(Icons.add),
          label: const Text('添加'),
        ),
      ],
    );
  }
}

class _LocalModelDialog extends StatefulWidget {
  const _LocalModelDialog(this.profile);

  final PhoneModel? profile;

  @override
  State<_LocalModelDialog> createState() => _LocalModelDialogState();
}

class _LocalModelDialogState extends State<_LocalModelDialog> {
  late GgufFile? _model = switch (widget.profile) {
    final profile? => (path: profile.localPath!, name: profile.model),
    null => null,
  };
  late String? _projectorPath = widget.profile?.projectorPath;
  String? _projectorName;
  late final _types = {...?widget.profile?.mediaTypes};
  final _staged = <String>{};
  bool _busy = false;
  String? _status;
  String? _error;

  void _discard(String? path) {
    if (path != null && _staged.remove(path)) {
      unawaited(discardImportedGguf(path));
    }
  }

  @override
  void dispose() {
    for (final path in _staged) {
      unawaited(discardImportedGguf(path));
    }
    super.dispose();
  }

  Future<void> _pick({bool projector = false}) async {
    setState(() {
      _busy = true;
      _status = '正在选择或导入文件…';
      _error = null;
    });
    try {
      final selected = await pickGgufFile(projector: projector);
      if (selected == null) return;
      if (!mounted) {
        await discardImportedGguf(selected.path);
        return;
      }
      setState(() {
        if (projector) {
          _discard(_projectorPath);
          _projectorPath = selected.path;
          _projectorName = selected.name;
        } else {
          _discard(_model?.path);
          _model = selected;
        }
        _staged.add(selected.path);
      });
    } on FormatException catch (failure) {
      if (mounted) setState(() => _error = failure.message);
    } catch (_) {
      if (mounted) setState(() => _error = '无法导入文件，请检查文件权限和可用空间。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final model = _model!;
    final projector = _types.isEmpty ? null : _projectorPath;
    setState(() {
      _busy = true;
      _status = '正在检测模型能力…';
      _error = null;
    });
    try {
      final profile = PhoneModel.file(
        model.path,
        model.name.length > 200 ? model.name.substring(0, 200) : model.name,
        projectorPath: projector,
        mediaTypes: _types,
      );
      if (projector != null) {
        await checkGgufMediaSupport(model.path, projector, profile.mediaTypes);
      }
      if (!mounted) return;
      _staged.remove(model.path);
      _staged.remove(projector);
      Navigator.of(context).pop(profile);
    } on FormatException catch (failure) {
      if (mounted) setState(() => _error = failure.message);
    } catch (_) {
      if (mounted) setState(() => _error = '无法检测模型能力，请检查模型文件和可用内存。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(widget.profile == null ? '添加本机模型' : '编辑本机模型能力'),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SectionTitle('对话主模型'),
            if (_model case final model?) Text(model.name),
            if (widget.profile == null)
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _pick(),
                icon: const Icon(Icons.insert_drive_file_outlined),
                label: Text(_model == null ? '选择 GGUF 主模型' : '更换 GGUF 主模型'),
              ),
            const SizedBox(height: 12),
            const SectionTitle('输入能力'),
            const Text('文本输入默认启用'),
            for (final type in GgufMediaType.values)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${type.label}输入'),
                value: _types.contains(type),
                onChanged: _busy
                    ? null
                    : (enabled) => setState(() {
                        if (enabled == true) {
                          _types.add(type);
                        } else {
                          _types.remove(type);
                        }
                        _error = null;
                      }),
              ),
            if (_types.isNotEmpty) ...[
              const Text(
                '请手动选择与主模型配套的 mmproj 文件。保存时会检测所选能力。',
                style: TextStyle(color: secondaryInk),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.extension_outlined),
                label: Text(
                  _projectorPath == null ? '选择 mmproj 文件' : '更换 mmproj 文件',
                ),
                onPressed: _busy ? null : () => _pick(projector: true),
              ),
              if (_projectorPath != null) Text(_projectorName ?? '已配置 mmproj'),
            ],
            if (_busy) ...[
              const SizedBox(height: 10),
              const LinearProgressIndicator(),
              Text(_status!),
            ],
            if (_error case final error?) _FormError(error),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed:
              _busy ||
                  _model == null ||
                  (_types.isNotEmpty && _projectorPath == null)
              ? null
              : _save,
          child: const Text('保存并使用'),
        ),
      ],
    ),
  );
}

class _CloudModelDialog extends StatefulWidget {
  const _CloudModelDialog(this.interaction, this.profile);
  final RobotInteraction interaction;
  final PhoneModel? profile;

  @override
  State<_CloudModelDialog> createState() => _CloudModelDialogState();
}

class _CloudModelDialogState extends State<_CloudModelDialog> {
  late final _address = TextEditingController(
    text: widget.profile?.endpoint.toString(),
  );
  late final _model = TextEditingController(text: widget.profile?.model);
  late final _key = TextEditingController(text: widget.profile?.key);
  late List<String> _ids = widget.profile?.modelIds ?? const [];
  bool _fetching = false;
  String? _error;

  @override
  void dispose() {
    _address.dispose();
    _model.dispose();
    _key.dispose();
    super.dispose();
  }

  void _save() {
    try {
      Navigator.pop(
        context,
        PhoneModel(
          ModelSource.cloud,
          _address.text,
          _model.text,
          _key.text,
          modelIds: _ids,
        ),
      );
    } on FormatException catch (failure) {
      setState(() => _error = failure.message);
    }
  }

  void _connectionChanged(String _) => setState(() {
    _ids = const [];
    _error = null;
  });

  Future<void> _fetchCloudIds() async {
    final url = _address.text;
    final token = _key.text;
    setState(() {
      _fetching = true;
      _error = null;
    });
    bool current() => mounted && url == _address.text && token == _key.text;
    try {
      final ids = await widget.interaction.remote.cloudModelIds(url, token);
      if (!current()) return;
      setState(() {
        _ids = ids;
        if (ids.length == 1) _model.text = ids.single;
      });
    } on FormatException catch (failure) {
      if (current()) setState(() => _error = failure.message);
    } catch (_) {
      if (current()) setState(() => _error = '无法连接云端服务，请检查接口地址和网络。');
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.profile == null ? '添加云端模型' : '编辑云端模型'),
    scrollable: true,
    content: SizedBox(
      width: 440,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _address,
            onChanged: _connectionChanged,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: '接口地址',
              hintText: 'https://模型服务/v1',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _key,
            onChanged: _connectionChanged,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'API 密钥（按服务要求填写）'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _fetching ? null : _fetchCloudIds,
            icon: const Icon(Icons.cloud_download_outlined),
            label: Text(_fetching ? '正在获取…' : '获取模型列表'),
          ),
          if (_ids.isNotEmpty) ...[
            const SizedBox(height: 12),
            DropdownMenu<String>(
              key: ObjectKey(_ids),
              initialSelection: _ids.contains(_model.text) ? _model.text : null,
              expandedInsets: EdgeInsets.zero,
              menuHeight: 260,
              enableFilter: true,
              label: const Text('搜索并选择模型 ID'),
              dropdownMenuEntries: [
                for (final id in _ids) DropdownMenuEntry(value: id, label: id),
              ],
              onSelected: (id) {
                if (id != null) _model.text = id;
              },
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _model,
            autocorrect: false,
            decoration: const InputDecoration(labelText: '模型 ID'),
          ),
          if (_error case final message?) _FormError(message),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _fetching ? null : _save,
        child: const Text('保存并使用'),
      ),
    ],
  );
}

class _FormError extends StatelessWidget {
  const _FormError(this.message);
  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Semantics(
      liveRegion: true,
      child: Text(
        message,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
    ),
  );
}
