import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import 'design.dart';
import 'interaction.dart';
import 'model_settings_view.dart';
import 'notice_rules_view.dart';

Future<void> openConversation(
  BuildContext context,
  RobotInteraction interaction, {
  bool record = false,
  String? draft,
}) async {
  if (draft != null) interaction.setDraft(draft);
  unawaited(interaction.fetchModels());
  if (record) unawaited(interaction.startRecording());
  await Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => _ConversationPage(interaction)),
  );
  if (interaction.listening) await interaction.cancelRecording();
}

Future<void> showNotice(
  BuildContext context,
  RobotInteraction interaction,
  PhoneNotice item,
) async {
  final draft = await showDialog<String>(
    context: context,
    builder: (context) => _NoticeDialog(interaction, item),
  );
  if (draft != null && context.mounted) {
    await openConversation(context, interaction, draft: draft);
  }
}

class _NoticeDialog extends StatefulWidget {
  const _NoticeDialog(this.interaction, this.item);

  final RobotInteraction interaction;
  final PhoneNotice item;

  @override
  State<_NoticeDialog> createState() => _NoticeDialogState();
}

class _NoticeDialogState extends State<_NoticeDialog> {
  Future<String?>? details;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return AlertDialog(
      scrollable: true,
      title: Text(item.title),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(item.source, style: const TextStyle(color: secondaryInk)),
          if (item.text.isNotEmpty) ...[
            const SizedBox(height: 6),
            SelectableText(item.text),
          ],
          if (details case final request?)
            FutureBuilder<String?>(
              future: request,
              builder: (context, result) {
                if (result.connectionState != ConnectionState.done) {
                  return const LinearProgressIndicator();
                }
                return SelectableText(result.data ?? '系统未提供可显示的验证码内容。');
              },
            ),
        ],
      ),
      actions: [
        if (item.verification && details == null)
          TextButton(
            onPressed: () => setState(
              () => details = widget.interaction.noticeDetails(item),
            ),
            child: const Text('查看验证内容'),
          ),
        if (!item.verification && item.text.isNotEmpty)
          TextButton(
            onPressed: () => Navigator.pop(context, item.text),
            child: const Text('问 AI'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _ConversationPage extends StatefulWidget {
  const _ConversationPage(this.interaction);
  final RobotInteraction interaction;

  @override
  State<_ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<_ConversationPage> {
  late final input = TextEditingController(text: interaction.draft);
  final transcript = ScrollController();
  final composerFocus = FocusNode();
  String? lastTurnId;
  bool awayFromLatest = false;
  RobotInteraction get interaction => widget.interaction;

  @override
  void initState() {
    super.initState();
    lastTurnId = interaction.turnId;
    interaction.addListener(_syncDraft);
    transcript.addListener(_updateScrollPosition);
  }

  void _updateScrollPosition() {
    final away = transcript.hasClients && transcript.offset > 100;
    if (away != awayFromLatest) setState(() => awayFromLatest = away);
  }

  void _syncDraft() {
    if (input.text != interaction.draft) {
      input.value = TextEditingValue(
        text: interaction.draft,
        selection: TextSelection.collapsed(offset: interaction.draft.length),
      );
    }
    if (lastTurnId != interaction.turnId) {
      lastTurnId = interaction.turnId;
      if (lastTurnId == null) awayFromLatest = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && transcript.hasClients) transcript.jumpTo(0);
      });
    }
  }

  void _goToLatest() {
    if (!transcript.hasClients) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      transcript.jumpTo(0);
    } else {
      transcript.animateTo(
        0,
        duration: const Duration(milliseconds: 230),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Future<void> _newConversation() async {
    if (interaction.question.isNotEmpty || input.text.trim().isNotEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('开始新对话？'),
          content: const Text('当前对话和草稿会被清空。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('新对话'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
    }
    interaction.startNewConversation();
    composerFocus.requestFocus();
  }

  @override
  void dispose() {
    interaction.removeListener(_syncDraft);
    transcript.dispose();
    composerFocus.dispose();
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: interaction,
    builder: (context, _) => Scaffold(
      backgroundColor: backdrop,
      appBar: AppBar(
        titleSpacing: 0,
        scrolledUnderElevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('AI 对话'),
            Text(
              interaction.modelLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: secondaryInk),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '模型设置',
            onPressed: interaction.listening || interaction.generating
                ? null
                : () => openModelSettings(context, interaction),
            icon: const Icon(Icons.tune_rounded),
          ),
          IconButton(
            tooltip: '新对话',
            onPressed: interaction.listening ? null : _newConversation,
            icon: const Icon(Icons.edit_square),
          ),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: borderColor),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: LayoutBuilder(
              builder: (context, constraints) => Column(
                children: [
                  if (interaction.loading)
                    const LinearProgressIndicator(minHeight: 2),
                  Expanded(child: _buildTranscript()),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: constraints.maxHeight * .62,
                    ),
                    child: SingleChildScrollView(
                      reverse: true,
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                      child: _buildComposer(
                        compact: constraints.maxHeight < 270,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _buildTranscript() {
    final turns = interaction.recentTurns;
    final current = interaction.turnId;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (current == null && turns.isEmpty)
          LayoutBuilder(
            builder: (context, constraints) => Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (constraints.maxHeight >= 120) ...[
                      const _RobotMark(size: 52),
                      const SizedBox(height: 12),
                    ],
                    const Text(
                      '想聊点什么？',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          ListView(
            controller: transcript,
            reverse: true,
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
            children: [
              if (current != null)
                _ChatMessagePair(
                  key: ValueKey(current),
                  question: interaction.question,
                  reply: interaction.reply,
                  reasoning: interaction.reasoning,
                  label: interaction.replyModel ?? 'Robot Eyes',
                  generating: interaction.generating,
                  speaking: interaction.spokenText != null,
                  mute: interaction.muteCurrent,
                ),
              for (final turn in turns.reversed)
                _ChatMessagePair(
                  key: ValueKey(turn.id),
                  question: turn.question,
                  reply: turn.reply,
                  reasoning: turn.reasoning,
                  label: turn.label,
                ),
            ],
          ),
        if (awayFromLatest)
          Positioned(
            bottom: 8,
            right: 16,
            child: IconButton.filledTonal(
              tooltip: '回到最新消息',
              onPressed: _goToLatest,
              icon: const Icon(Icons.arrow_downward_rounded),
            ),
          ),
      ],
    );
  }

  Widget _buildComposer({required bool compact}) {
    final field = TextField(
      controller: input,
      focusNode: composerFocus,
      readOnly: interaction.listening,
      minLines: 1,
      maxLines: compact ? 2 : 3,
      maxLength: 4000,
      textInputAction: TextInputAction.newline,
      decoration: InputDecoration(
        hintText: interaction.listening ? '正在聆听…' : '发消息',
        counterText: '',
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: const EdgeInsets.fromLTRB(10, 8, 10, 3),
      ),
      onChanged: interaction.setDraft,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if ((interaction.error ?? interaction.modelError) case final message?)
          Padding(
            padding: const EdgeInsets.fromLTRB(5, 0, 5, 8),
            child: Semantics(
              liveRegion: true,
              child: Text(
                message,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ),
        if (interaction.listening) ...[
          _ListeningFeedback(interaction),
          const SizedBox(height: 6),
        ],
        DecoratedBox(
          decoration: BoxDecoration(
            color: panelColor,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: borderColor),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(7, 3, 7, 4),
            child: Flex(
              direction: compact ? Axis.horizontal : Axis.vertical,
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: compact
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.stretch,
              children: [
                if (compact) Expanded(child: field) else field,
                Row(
                  mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
                  children: [
                    if (interaction.listening)
                      IconButton(
                        tooltip: '取消录音',
                        onPressed: interaction.cancelRecording,
                        icon: const Icon(Icons.close_rounded),
                      ),
                    if (interaction.speechEnabled && !interaction.generating)
                      IconButton(
                        tooltip: interaction.listening ? '结束录音' : '开始说话',
                        onPressed: interaction.finishingRecording
                            ? null
                            : interaction.listening
                            ? () => interaction.stopRecording()
                            : () {
                                composerFocus.unfocus();
                                unawaited(interaction.startRecording());
                              },
                        icon: Icon(
                          interaction.listening
                              ? Icons.mic_rounded
                              : Icons.mic_none_rounded,
                          color: cyan,
                        ),
                      ),
                    if (!compact) const Spacer(),
                    ValueListenableBuilder(
                      valueListenable: input,
                      builder: (_, value, _) {
                        final generating = interaction.generating;
                        final listening = interaction.listening;
                        final enabled =
                            generating ||
                            (!interaction.loading &&
                                !interaction.finishingRecording &&
                                (listening || value.text.trim().isNotEmpty));
                        return Padding(
                          padding: const EdgeInsets.all(2),
                          child: IconButton.filled(
                            tooltip: generating
                                ? '停止回答'
                                : listening
                                ? '结束并发送'
                                : '发送',
                            style: IconButton.styleFrom(
                              backgroundColor: cyan,
                              foregroundColor: backdrop,
                              minimumSize: const Size.square(48),
                            ),
                            onPressed: !enabled
                                ? null
                                : generating
                                ? interaction.cancelAnswer
                                : () {
                                    if (!listening) composerFocus.unfocus();
                                    unawaited(interaction.send());
                                  },
                            icon: Icon(
                              generating
                                  ? Icons.stop_rounded
                                  : Icons.arrow_upward_rounded,
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _RobotMark extends StatelessWidget {
  const _RobotMark({this.size = 30});
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: cyan.withAlpha(17),
        border: Border.all(color: cyan.withAlpha(115)),
        borderRadius: BorderRadius.circular(size * .29),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        spacing: size * .10,
        children: [
          for (final color in [cyan, violet])
            Container(
              width: size * .15,
              height: size * .26,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(size),
              ),
            ),
        ],
      ),
    ),
  );
}

class SpeakButton extends StatelessWidget {
  const SpeakButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.icon = Icons.mic_none,
  });
  final VoidCallback? onPressed;
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: onPressed,
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(0, 48),
      foregroundColor: cyan,
      backgroundColor: panelColor,
      side: const BorderSide(color: borderColor),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    icon: Icon(icon, size: 19),
    label: Text(label),
  );
}

class _ListeningFeedback extends StatelessWidget {
  const _ListeningFeedback(this.interaction);
  final RobotInteraction interaction;

  @override
  Widget build(BuildContext context) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: panelColor,
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Center(
          child: !reducedMotion && !interaction.finishingRecording
              ? ExcludeSemantics(
                  child: TweenAnimationBuilder<double>(
                    duration: const Duration(milliseconds: 95),
                    tween: Tween(end: interaction.inputLevel),
                    builder: (_, level, _) => SizedBox(
                      width: 32,
                      height: 25,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          for (final (index, scale) in [
                            0.45,
                            0.73,
                            1.0,
                            0.64,
                            0.40,
                          ].indexed)
                            Container(
                              height: 4 + 20 * scale * level,
                              width: 4,
                              decoration: BoxDecoration(
                                color: index.isEven ? cyan : violet,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                )
              : const Icon(Icons.mic_none, color: cyan, size: 22),
        ),
      ),
    );
  }
}

class _ChatMessagePair extends StatelessWidget {
  const _ChatMessagePair({
    super.key,
    required this.question,
    required this.reply,
    required this.reasoning,
    required this.label,
    this.generating = false,
    this.speaking = false,
    this.mute,
  });

  final String question;
  final String reply;
  final String reasoning;
  final String label;
  final bool generating;
  final bool speaking;
  final VoidCallback? mute;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: reply));
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('已复制回复')));
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 19),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) => Align(
            alignment: AlignmentDirectional.centerEnd,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth * .84),
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  color: Color(0xff24203a),
                  borderRadius: BorderRadiusDirectional.only(
                    topStart: Radius.circular(18),
                    topEnd: Radius.circular(18),
                    bottomStart: Radius.circular(18),
                    bottomEnd: Radius.circular(5),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 11,
                  ),
                  child: SelectableText(
                    question,
                    style: const TextStyle(
                      color: primaryInk,
                      fontSize: 15,
                      height: 1.45,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (generating || reply.isNotEmpty || reasoning.trim().isNotEmpty) ...[
          const SizedBox(height: 18),
          Row(
            children: [
              const _RobotMark(),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: cyan,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (reasoning.trim().isNotEmpty)
            ExpansionTile(
              title: const Text(
                '思考过程',
                style: TextStyle(color: secondaryInk, fontSize: 13),
              ),
              tilePadding: const EdgeInsets.symmetric(horizontal: 4),
              childrenPadding: const EdgeInsets.fromLTRB(12, 0, 8, 12),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              shape: const Border(),
              collapsedShape: const Border(),
              children: [
                SelectableText(
                  reasoning.trim(),
                  style: const TextStyle(color: secondaryInk, height: 1.5),
                ),
              ],
            ),
          if (reply.isNotEmpty) ...[
            const SizedBox(height: 9),
            SelectionArea(
              child: MarkdownBody(
                data: reply,
                imageBuilder: (_, _, alt) => Text(alt ?? ''),
                styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                    .copyWith(
                      p: const TextStyle(
                        color: primaryInk,
                        fontSize: 15,
                        height: 1.55,
                      ),
                      codeblockDecoration: BoxDecoration(
                        color: panelColor,
                        border: Border.all(color: borderColor),
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
              ),
            ),
          ] else if (generating)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text('正在思考…', style: TextStyle(color: secondaryInk)),
            ),
          if ((!generating && reply.isNotEmpty) || speaking)
            Row(
              children: [
                if (!generating && reply.isNotEmpty)
                  IconButton(
                    tooltip: '复制回复',
                    onPressed: () => _copy(context),
                    icon: const Icon(Icons.content_copy_rounded, size: 18),
                  ),
                if (speaking)
                  IconButton(
                    tooltip: '停止朗读',
                    onPressed: mute,
                    icon: const Icon(Icons.volume_off_outlined, size: 20),
                  ),
              ],
            ),
        ],
      ],
    ),
  );
}

class InteractionBubbles extends StatelessWidget {
  const InteractionBubbles(
    this.interaction, {
    super.key,
    this.showReply = false,
    this.includeNotice = true,
  });

  final RobotInteraction interaction;
  final bool showReply;
  final bool includeNotice;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: interaction,
    builder: (context, _) {
      final notice = includeNotice ? interaction.notice : null;
      final shared = interaction.sharedText;
      final showAnswer =
          showReply && (interaction.generating || interaction.reply.isNotEmpty);
      if (notice == null && shared == null && !showAnswer) {
        return const SizedBox.shrink();
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (notice != null)
            _NoticeHud(interaction, notice, key: ValueKey(notice)),
          if (showAnswer)
            _bubble(
              icon: Icons.chat_bubble_outline,
              title: interaction.replyModel ?? 'Robot Eyes',
              text:
                  interaction.spokenReply ??
                  (interaction.reply.isEmpty ? '正在思考…' : interaction.reply),
              open: () => openConversation(context, interaction),
              trailing: interaction.spokenText == null
                  ? null
                  : IconButton(
                      tooltip: '停止朗读',
                      icon: const Icon(Icons.volume_off_outlined),
                      onPressed: interaction.muteCurrent,
                    ),
            ),
          if (shared != null)
            _bubble(
              icon: Icons.share_outlined,
              title: '收到分享',
              text: shared,
              open: () => openConversation(context, interaction, draft: shared),
              trailing: IconButton(
                tooltip: '关闭分享',
                icon: const Icon(Icons.close),
                onPressed: interaction.dismissShared,
              ),
            ),
        ],
      );
    },
  );

  static Widget _bubble({
    required IconData icon,
    required String title,
    required String text,
    required VoidCallback open,
    Widget? trailing,
  }) => Material(
    color: panelColor,
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: const BorderSide(color: borderColor),
    ),
    child: ListTile(
      leading: Icon(icon, color: cyan),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis),
      onTap: open,
      trailing: trailing,
    ),
  );
}

class NoticeSignal extends StatelessWidget {
  const NoticeSignal(this.interaction, {super.key});

  final RobotInteraction interaction;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: interaction,
    builder: (context, _) {
      final notice = interaction.notice;
      final duration = MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 410);
      return IgnorePointer(
        ignoring: notice == null,
        child: AnimatedSwitcher(
          duration: duration,
          reverseDuration: duration == Duration.zero
              ? Duration.zero
              : const Duration(milliseconds: 180),
          layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.bottomCenter,
            children: [
              for (final child in previous) IgnorePointer(child: child),
              ?current,
            ],
          ),
          transitionBuilder: (child, animation) {
            final ease = animation.drive(
              CurveTween(curve: Curves.easeOutCubic),
            );
            return SlideTransition(
              position: Tween(
                begin: const Offset(.035, .12),
                end: Offset.zero,
              ).animate(ease),
              child: FadeTransition(
                opacity: ease,
                child: CustomPaint(
                  foregroundPainter: _NoticeSweep(animation),
                  child: child,
                ),
              ),
            );
          },
          child: notice == null
              ? const SizedBox.shrink()
              : _NoticeHud(interaction, notice, key: ValueKey(notice)),
        ),
      );
    },
  );
}

class _NoticeSweep extends CustomPainter {
  _NoticeSweep(this.animation) : super(repaint: animation);

  final Animation<double> animation;

  @override
  void paint(Canvas canvas, Size size) {
    final t = animation.value;
    if (t <= 0 || t >= 1 || size.isEmpty) return;
    final x = (size.width + 48) * t - 24;
    final band = Rect.fromLTRB(x - 24, 0, x + 24, size.height);
    final strength = 1 - (2 * t - 1).abs();
    canvas.save();
    canvas.clipRect((Offset.zero & size).deflate(2));
    canvas.drawRect(
      band,
      Paint()
        ..shader = LinearGradient(
          colors: [
            cyan.withValues(alpha: 0),
            cyan.withValues(alpha: strength * .20),
            cyan.withValues(alpha: 0),
          ],
        ).createShader(band),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_NoticeSweep oldDelegate) =>
      animation != oldDelegate.animation;
}

class _NoticeHud extends StatefulWidget {
  const _NoticeHud(this.interaction, this.notice, {super.key});

  final RobotInteraction interaction;
  final PhoneNotice notice;

  @override
  State<_NoticeHud> createState() => _NoticeHudState();
}

class _NoticeHudState extends State<_NoticeHud> {
  late final _logo = widget.interaction.noticeAppIcon(widget.notice);

  @override
  Widget build(BuildContext context) {
    final notice = widget.notice;
    return Semantics(
      liveRegion: true,
      button: true,
      child: GestureDetector(
        onTap: () => showNotice(context, widget.interaction, notice),
        child: CustomPaint(
          painter: const _NoticeHudFrame(),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(13, 10, 15, 11),
            child: Row(
              children: [
                FutureBuilder<Uint8List?>(
                  future: _logo,
                  builder: (context, snapshot) => snapshot.data == null
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.only(right: 10),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Image.memory(
                              snapshot.data!,
                              width: 30,
                              height: 30,
                              excludeFromSemantics: true,
                              errorBuilder: (_, _, _) =>
                                  const SizedBox.shrink(),
                            ),
                          ),
                        ),
                ),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        notice.source,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: cyan,
                          fontSize: 11,
                          letterSpacing: 1.3,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        notice.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: primaryInk,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (notice.text.isNotEmpty)
                        Text(
                          notice.text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: secondaryInk,
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NoticeHudFrame extends CustomPainter {
  const _NoticeHudFrame();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    const corner = 11.0;
    final frame = Path()
      ..moveTo(0, corner)
      ..lineTo(corner, 0)
      ..lineTo(w, 0)
      ..lineTo(w, h - corner)
      ..lineTo(w - corner, h)
      ..lineTo(0, h)
      ..close();
    final paint = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xf0132635), Color(0xf008101c)],
      ).createShader(Offset.zero & size);
    canvas.drawPath(frame, paint);
    paint
      ..shader = null
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = cyan.withValues(alpha: .34);
    canvas.drawPath(frame, paint);
    final corners = Path()
      ..moveTo(0, 25)
      ..lineTo(0, corner)
      ..lineTo(corner, 0)
      ..lineTo(31, 0)
      ..moveTo(w - 31, h)
      ..lineTo(w - corner, h)
      ..lineTo(w, h - corner)
      ..lineTo(w, h - 25);
    paint
      ..strokeWidth = 1.5
      ..color = cyan.withValues(alpha: .9);
    canvas.drawPath(corners, paint);
  }

  @override
  bool shouldRepaint(_NoticeHudFrame oldDelegate) => false;
}

Future<void> openInteractionSettings(
  BuildContext context,
  RobotInteraction interaction,
) => showDialog<void>(
  context: context,
  builder: (context) => ListenableBuilder(
    listenable: interaction,
    builder: (context, _) => AlertDialog(
      title: const Text('语音与手机提醒'),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('朗读 AI 回复'),
              value: interaction.readAnswers,
              onChanged: interaction.setReadAnswers,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('播报重要提醒'),
              value: interaction.readNotices,
              onChanged: interaction.setReadNotices,
            ),
            if (interaction.supportsNotifications) ...[
              OutlinedButton(
                onPressed: interaction.openNotificationSettings,
                child: Text(
                  interaction.notificationAccess ? '管理通知访问权限' : '开启通知访问权限',
                ),
              ),
              if (interaction.notificationAccess) NoticeRules(interaction),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ],
    ),
  ),
);

Future<void> openRecentNotices(
  BuildContext context,
  RobotInteraction interaction,
) async {
  final item = await showDialog<PhoneNotice>(
    context: context,
    builder: (context) => ListenableBuilder(
      listenable: interaction,
      builder: (context, _) => SimpleDialog(
        title: const Text('最近提醒'),
        children: [
          if (interaction.recentNotices.isEmpty)
            const Padding(padding: EdgeInsets.all(16), child: Text('暂无提醒')),
          for (final item in interaction.recentNotices)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, item),
              child: Text(
                '${item.source} · ${item.title}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    ),
  );
  if (item != null && context.mounted) {
    await showNotice(context, interaction, item);
  }
}
