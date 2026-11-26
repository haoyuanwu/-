// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'design.dart';
import 'interaction.dart';

class NoticeRules extends StatelessWidget {
  const NoticeRules(this.interaction, {super.key});

  final RobotInteraction interaction;

  Future<void> _choose(BuildContext context, {required bool contacts}) async {
    final result = await Navigator.of(context).push<List<NoticeChoice>>(
      MaterialPageRoute(
        builder: (_) => _NoticePicker(interaction, contacts: contacts),
      ),
    );
    if (result != null && context.mounted) {
      interaction.saveNoticeChoices(result, contacts: contacts);
    }
  }

  Future<void> _keywords(BuildContext context) async {
    final result = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(builder: (_) => _KeywordPicker(interaction.keywords)),
    );
    if (result != null && context.mounted) interaction.saveKeywords(result);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _row(
        context,
        '关注的 App',
        interaction.selectedApps.map((app) => app.name),
        () => _choose(context, contacts: false),
        emptyLabel: '全部 App（含短信）',
      ),
      _row(
        context,
        '联系人',
        interaction.selectedContacts.map((contact) => contact.name),
        () => _choose(context, contacts: true),
        emptyLabel: '全部联系人',
      ),
      _row(context, '关键词', interaction.keywords, () => _keywords(context)),
      const SizedBox(height: 6),
      const Text(
        '选中的 App、联系人和关键词，匹配任一项就会提醒。三项都未设置时提醒全部通知。',
        style: TextStyle(color: secondaryInk, fontSize: 13),
      ),
    ],
  );

  Widget _row(
    BuildContext context,
    String label,
    Iterable<String> entries,
    VoidCallback edit, {
    String emptyLabel = '未设置',
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            TextButton.icon(
              onPressed: edit,
              icon: const Icon(Icons.add, size: 18),
              label: Text(entries.isEmpty ? '添加' : '编辑'),
            ),
          ],
        ),
        if (entries.isEmpty)
          Text(emptyLabel, style: const TextStyle(color: secondaryInk))
        else
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final name in entries)
                Chip(
                  label: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
      ],
    ),
  );
}

class _NoticePicker extends StatefulWidget {
  const _NoticePicker(this.interaction, {required this.contacts});

  final RobotInteraction interaction;
  final bool contacts;

  @override
  State<_NoticePicker> createState() => _NoticePickerState();
}

class _NoticePickerState extends State<_NoticePicker> {
  late final selected = {
    for (final item
        in widget.contacts
            ? widget.interaction.selectedContacts
            : widget.interaction.selectedApps)
      item.id: item,
  };
  List<NoticeChoice> choices = const [];
  var query = '';
  bool loading = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final loaded = await widget.interaction.loadNoticeChoices(
        contacts: widget.contacts,
      );
      if (!mounted) return;
      setState(() {
        choices = loaded;
        if (!widget.contacts) {
          final available = loaded.map((option) => option.id).toSet();
          selected.removeWhere((id, _) => !available.contains(id));
        }
        for (final option in loaded) {
          if (selected.containsKey(option.id)) selected[option.id] = option;
        }
      });
    } on PlatformException catch (failure) {
      if (mounted) setState(() => error = failure.message ?? '无法读取列表。');
    } on MissingPluginException {
      if (mounted) setState(() => error = '当前设备无法读取此列表。');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final options = {for (final item in choices) item.id: item};
    if (widget.contacts) {
      for (final item in selected.values) {
        options.putIfAbsent(item.id, () => item);
      }
    }
    final visible = options.values.where((entry) {
      final searchable = widget.contacts ? entry.aliases : [entry.id];
      return entry.name.toLowerCase().contains(query) ||
          searchable.any((value) => value.toLowerCase().contains(query));
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.contacts ? '选择联系人' : '选择关注的 App'),
        actions: [
          TextButton(
            onPressed: loading || error != null
                ? null
                : () => Navigator.pop(context, selected.values.toList()),
            child: const Text('保存'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                decoration: InputDecoration(
                  labelText: widget.contacts ? '搜索联系人或号码' : '搜索 App',
                  prefixIcon: const Icon(Icons.search),
                ),
                onChanged: (value) =>
                    setState(() => query = value.trim().toLowerCase()),
              ),
            ),
            if (loading) const LinearProgressIndicator(),
            if (error case final message?)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(child: Text(message)),
                    TextButton(onPressed: _load, child: const Text('重试')),
                  ],
                ),
              ),
            if (!loading && error == null && visible.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(query.isEmpty ? '列表为空' : '没有匹配项，试试其他搜索词。'),
              ),
            Expanded(
              child: ListView.builder(
                itemCount: visible.length,
                itemBuilder: (context, index) {
                  final item = visible[index];
                  return CheckboxListTile(
                    title: Text(item.name),
                    subtitle: widget.contacts ? null : Text(item.id),
                    value: selected.containsKey(item.id),
                    onChanged: (value) => setState(() {
                      if (value == true) {
                        selected[item.id] = item;
                      } else {
                        selected.remove(item.id);
                      }
                    }),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _KeywordPicker extends StatefulWidget {
  const _KeywordPicker(this.initial);

  final List<String> initial;

  @override
  State<_KeywordPicker> createState() => _KeywordPickerState();
}

class _KeywordPickerState extends State<_KeywordPicker> {
  late final _selected = widget.initial.toSet();
  final _input = TextEditingController();
  static const _suggestions = ['会议', '日程', '紧急', '待办', '到期', '快递'];

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _addInput() {
    final value = _input.text.trim();
    if (value.isEmpty) return;
    setState(() => _selected.add(value));
    _input.clear();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('提醒关键词'),
      actions: [
        TextButton(
          onPressed: () {
            _addInput();
            Navigator.pop(context, _selected.toList());
          },
          child: const Text('保存'),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _input,
          maxLength: 60,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _addInput(),
          decoration: InputDecoration(
            labelText: '添加关键词',
            suffixIcon: IconButton(
              tooltip: '添加关键词',
              onPressed: _addInput,
              icon: const Icon(Icons.add),
            ),
          ),
        ),
        if (_selected.isNotEmpty) ...[
          const Text('已选关键词'),
          Wrap(
            spacing: 8,
            children: [
              for (final term in _selected)
                InputChip(
                  label: Text(term),
                  onDeleted: () => setState(() => _selected.remove(term)),
                ),
            ],
          ),
          const SizedBox(height: 16),
        ],
        const Text('常用关键词'),
        Wrap(
          spacing: 8,
          children: [
            for (final term in _suggestions)
              FilterChip(
                label: Text(term),
                selected: _selected.contains(term),
                onSelected: (value) => setState(() {
                  if (value) {
                    _selected.add(term);
                  } else {
                    _selected.remove(term);
                  }
                }),
              ),
          ],
        ),
      ],
    ),
  );
}
