import 'package:flutter/material.dart';

import 'design.dart';
import 'interaction.dart';
import 'phone_model.dart';

Future<void> openModelSettings(
  BuildContext context,
  RobotInteraction interaction,
) => Navigator.of(context)
    .push<void>(MaterialPageRoute(builder: (_) => _ModelSettings(interaction)));

class _ModelSettings extends StatefulWidget {
  const _ModelSettings(this.interaction);
  final RobotInteraction interaction;

  @override
  State<_ModelSettings> createState() => _ModelSettingsState();
}

class _ModelSettingsState extends State<_ModelSettings> {
  late ModelSource source = widget.interaction.modelSource;
  late final address = TextEditingController(
    text: widget.interaction.phoneModel?.endpoint.toString(),
  );
  late final model = TextEditingController(
    text: widget.interaction.phoneModel?.model,
  );
  late final key = TextEditingController(
    text: widget.interaction.phoneModel?.key,
  );
  String? error;

  @override
  void dispose() {
    address.dispose();
    model.dispose();
    key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    try {
      final profile = source == ModelSource.desktop
          ? null
          : PhoneModel(source, address.text, model.text, key.text);
      await widget.interaction.cancelAnswer();
      if (!mounted) return;
      widget.interaction.configureModel(source, profile);
      Navigator.pop(context);
    } on FormatException catch (failure) {
      setState(() => error = failure.message);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('模型设置')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const SectionTitle('对话使用的模型'),
              const SizedBox(height: 12),
              DropdownButtonFormField<ModelSource>(
                initialValue: source,
                decoration: const InputDecoration(labelText: '模型来源'),
                items: [
                  for (final option in ModelSource.values)
                    DropdownMenuItem(value: option, child: Text(option.label)),
                ],
                onChanged: (next) {
                  if (next == null) return;
                  setState(() {
                    source = next;
                    error = null;
                  });
                },
              ),
              const SizedBox(height: 12),
              Text(switch (source) {
                ModelSource.desktop => '在电脑的「模型连接」设置手机默认模型。',
                ModelSource.cloud => '使用支持 OpenAI Chat Completions 的 HTTPS 服务。',
                ModelSource.lan => '手机需能访问同一局域网中的模型服务。',
                ModelSource.local => '先在手机上启动兼容服务，再填写回环地址。',
              }, style: const TextStyle(color: secondaryInk)),
              if (source != ModelSource.desktop) ...[
                const SizedBox(height: 16),
                TextField(
                  controller: address,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: '接口地址',
                    hintText: switch (source) {
                      ModelSource.desktop ||
                      ModelSource.cloud => 'https://模型服务/v1',
                      ModelSource.lan => 'http://192.168.1.10:11434/v1',
                      ModelSource.local => 'http://127.0.0.1:8080/v1',
                    },
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: model,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: '模型 ID'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: key,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'API 密钥（按服务要求填写）',
                  ),
                ),
              ],
              if (error case final message?) ...[
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    message,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              FilledButton(onPressed: _save, child: const Text('保存')),
            ],
          ),
        ),
      ),
    ),
  );
}
