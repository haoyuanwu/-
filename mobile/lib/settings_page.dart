// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import 'design.dart';

Future<void> openSettingsPage(
  BuildContext context,
  String title,
  WidgetBuilder builder,
) => Navigator.of(context).push<void>(
  MaterialPageRoute(builder: (context) => SettingsPage(title, builder)),
);

class SettingsPage extends StatelessWidget {
  const SettingsPage(this.title, this.builder, {this.actions, super.key});

  final String title;
  final WidgetBuilder builder;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title), actions: actions),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [builder(context)],
          ),
        ),
      ),
    ),
  );
}

class SettingsEntry extends StatelessWidget {
  const SettingsEntry(
    this.icon,
    this.title,
    this.onTap, {
    this.detail,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    minTileHeight: 56,
    leading: Icon(icon, color: cyan, size: 21),
    title: Text(title),
    subtitle: detail == null
        ? null
        : Text(detail!, style: const TextStyle(color: secondaryInk)),
    trailing: const Icon(Icons.chevron_right, color: secondaryInk),
    onTap: onTap,
  );
}

class SettingsGroup extends StatelessWidget {
  const SettingsGroup(this.children, {super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Material(
    color: panelColor,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: const BorderSide(color: borderColor),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (index, child) in children.indexed) ...[
          if (index > 0) const Divider(height: 1, color: borderColor),
          child,
        ],
      ],
    ),
  );
}
