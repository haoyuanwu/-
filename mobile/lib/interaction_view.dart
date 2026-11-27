import 'dart:async';
import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:robot_eyes_models/robot_eyes_models.dart';

import 'design.dart';
import 'interaction.dart';
import 'model_settings_view.dart';
import 'notice_queue.dart';
import 'notice_rules_view.dart';
import 'notice_window.dart';
import 'reply_frame.dart';
import 'settings_page.dart';

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

Future<void> _showNotice(
  BuildContext context,
  RobotInteraction interaction,
  PhoneNotice item, {
  NoticeGroup<PhoneNotice>? group,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final source = context.findRenderObject()! as RenderBox;
  final overlay = navigator.overlay!.context.findRenderObject()! as RenderBox;
  final origin = MatrixUtils.transformRect(
    source.getTransformTo(overlay),
    Offset.zero & source.size,
  );
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  final route = RawDialogRoute<String>(
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: backdrop.withValues(alpha: .80),
    transitionDuration: reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 340),
    transitionBuilder: (_, _, _, child) => child,
    pageBuilder: (context, animation, _) => LayoutBuilder(
      builder: (context, constraints) {
        final padding =
            (const EdgeInsets.all(16) +
                    MediaQuery.viewInsetsOf(context) +
                    MediaQuery.paddingOf(context))
                .resolve(Directionality.of(context));
        final center = padding
            .deflateRect(Offset.zero & constraints.biggest)
            .center;
        return Padding(
          padding: padding,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: SizedBox(
                width: double.infinity,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: IgnorePointer(
                        child: LayoutBuilder(
                          builder: (context, card) {
                            final target = Rect.fromCenter(
                              center: center,
                              width: card.maxWidth,
                              height: card.maxHeight,
                            );
                            final motion = animation.drive(
                              CurveTween(curve: Curves.easeInOutCubic),
                            );
                            return AnimatedBuilder(
                              animation: motion,
                              child: const RepaintBoundary(
                                child: CustomPaint(
                                  painter: NoticeWindowFrame(),
                                ),
                              ),
                              builder: (context, frame) {
                                final bounds = reduceMotion
                                    ? target
                                    : Rect.lerp(origin, target, motion.value)!;
                                return Transform.translate(
                                  offset: bounds.center - center,
                                  child: OverflowBox(
                                    minWidth: bounds.width,
                                    maxWidth: bounds.width,
                                    minHeight: bounds.height,
                                    maxHeight: bounds.height,
                                    child: frame,
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ),
                    ),
                    FadeTransition(
                      opacity: animation.drive(
                        CurveTween(
                          curve: const Interval(.38, 1, curve: Curves.easeOut),
                        ),
                      ),
                      child: ListenableBuilder(
                        listenable: interaction.noticeQueue,
                        builder: (_, _) {
                          final latest = group?.latest ?? item;
                          return _NoticeDialog(
                            interaction,
                            latest,
                            older: group?.items.reversed.skip(1) ?? const [],
                            key: ValueKey(latest),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
  interaction.noticeQueue.pause();
  String? draft;
  try {
    draft = await navigator.push(route);
    await route.completed;
  } finally {
    interaction.noticeQueue.resume();
  }
  if (draft != null && navigator.mounted) {
    await openConversation(navigator.context, interaction, draft: draft);
  }
}

class _NoticeDialog extends StatefulWidget {
  const _NoticeDialog(
    this.interaction,
    this.item, {
    super.key,
    required this.older,
  });

  final RobotInteraction interaction;
  final PhoneNotice item;
  final Iterable<PhoneNotice> older;

  @override
  State<_NoticeDialog> createState() => _NoticeDialogState();
}

class _NoticeDialogState extends State<_NoticeDialog> {
  late final _code = widget.interaction.noticeCode(widget.item);
  late final _logo = widget.interaction.noticeAppIcon(widget.item);

  bool _opening = false;
  String? _openError;

  Future<void> _openSource() async {
    setState(() {
      _opening = true;
      _openError = null;
    });
    final interaction = widget.interaction;
    final item = widget.item;
    String? result = await interaction.openNoticeApp(item) ?? 'unavailable';
    if (!mounted) return;
    if (result == 'permission') {
      final authorize = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('开启贴边返回便签'),
          content: const Text('允许在其他应用上层显示后，点便签即可返回 Robot Eyes 横屏。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('直接打开'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('去授权'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (authorize == true) {
        final opened = await interaction.openNoticeOverlaySettings();
        result = opened ? null : 'settingsUnavailable';
      } else if (authorize == false) {
        result =
            await interaction.openNoticeApp(item, withShortcut: false) ??
            'unavailable';
      } else {
        result = null;
      }
    }
    if (!mounted) return;
    if (result == 'opened') {
      interaction.noticeQueue.remove(item);
      if (ModalRoute.of(context)?.isCurrent == true) Navigator.pop(context);
      return;
    }
    setState(() {
      _opening = false;
      _openError = switch (result) {
        'settingsUnavailable' => '无法打开悬浮窗权限设置。',
        null => null,
        _ => '无法打开来源 App。',
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final canOpenApp = widget.interaction.canOpenNoticeApp(item);
    const bodyStyle = TextStyle(color: secondaryInk, height: 1.5);
    final close = IconButton(
      tooltip: '关闭',
      onPressed: () => Navigator.pop(context),
      icon: const Icon(Icons.close_rounded, color: secondaryInk),
    );
    return Material(
      type: MaterialType.transparency,
      child: Semantics(
        scopesRoute: true,
        namesRoute: item.verification,
        label: item.verification ? '验证码' : null,
        explicitChildNodes: true,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: item.verification
                ? [
                    Row(
                      children: [
                        const SizedBox(width: 44),
                        Expanded(
                          child: FutureBuilder<String?>(
                            future: _code,
                            builder: (context, result) {
                              if (result.connectionState !=
                                  ConnectionState.done) {
                                return const LinearProgressIndicator();
                              }
                              final code = result.data;
                              if (code == null) {
                                return const Text(
                                  '验证码不可用',
                                  style: bodyStyle,
                                  textAlign: TextAlign.center,
                                );
                              }
                              return SelectableText(
                                code,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: cyan,
                                  fontFamily: 'monospace',
                                  fontSize: 30,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 2,
                                ),
                              );
                            },
                          ),
                        ),
                        close,
                      ],
                    ),
                  ]
                : [
                    Row(
                      children: [
                        NoticeAppLogo(_logo),
                        Expanded(
                          child: Text(
                            item.source,
                            style: const TextStyle(
                              color: cyan,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        close,
                      ],
                    ),
                    Semantics(
                      header: true,
                      namesRoute: true,
                      child: Text(
                        item.title,
                        style: const TextStyle(
                          color: primaryInk,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (item.text.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      SelectableText(item.text, style: bodyStyle),
                    ],
                    NoticeMessageHistory(
                      messages: widget.older.map(
                        (notice) => (title: notice.title, text: notice.text),
                      ),
                    ),
                    if (_openError case final message?)
                      Text(message, style: bodyStyle),
                    if (canOpenApp || item.text.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerRight,
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: cyan,
                            side: const BorderSide(color: borderColor),
                            minimumSize: const Size(48, 48),
                          ),
                          onPressed: canOpenApp
                              ? (_opening ? null : _openSource)
                              : () => Navigator.pop(context, item.text),
                          child: Text(canOpenApp ? '打开 App' : '问 AI'),
                        ),
                      ),
                    ],
                  ],
          ),
        ),
      ),
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
          IconButton(
            tooltip: '朗读音色',
            onPressed: () => _openVoiceSettings(context, interaction),
            icon: const Icon(Icons.record_voice_over_outlined),
          ),
          IconButton(
            tooltip: interaction.readAnswers ? '关闭自动朗读' : '开启自动朗读',
            isSelected: interaction.readAnswers,
            onPressed: () =>
                interaction.setReadAnswers(!interaction.readAnswers),
            icon: const Icon(Icons.volume_off_outlined),
            selectedIcon: const Icon(Icons.volume_up_rounded, color: cyan),
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
                  speaking: interaction.spokenReply != null,
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

  Future<void> _attachMedia(GgufMediaType type) async {
    final profile = interaction.phoneModel;
    try {
      final media = await pickGgufMedia(type);
      if (mounted &&
          media != null &&
          identical(profile, interaction.phoneModel)) {
        interaction.setDraftMedia(media);
      }
    } catch (failure) {
      if (!mounted) return;
      final message = failure is FormatException
          ? failure.message
          : '无法读取所选附件。';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
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
        hintText: interaction.startingRecording
            ? '正在准备麦克风…'
            : interaction.listening
            ? '正在聆听…'
            : '发消息',
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
        if (interaction.draftMedia case final media?)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: InputChip(
              avatar: Icon(
                media.type == GgufMediaType.image
                    ? Icons.image_outlined
                    : Icons.audiotrack,
              ),
              label: Text(
                media.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              deleteButtonTooltipMessage: '移除附件',
              onDeleted: () => interaction.setDraftMedia(null),
            ),
          ),
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
                    if (interaction.localMediaTypes.isNotEmpty &&
                        !interaction.generating &&
                        !interaction.listening)
                      PopupMenuButton<GgufMediaType>(
                        tooltip: '添加附件',
                        icon: const Icon(Icons.attach_file_outlined),
                        onSelected: _attachMedia,
                        itemBuilder: (context) => [
                          for (final type in interaction.localMediaTypes)
                            PopupMenuItem(
                              value: type,
                              child: Text('选择${type.label}文件'),
                            ),
                        ],
                      ),
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
                                (listening ||
                                    value.text.trim().isNotEmpty ||
                                    interaction.draftMedia != null));
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
                                ? () => interaction.cancelAnswer(
                                    discardReasoning: true,
                                  )
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
  });

  final String question;
  final String reply;
  final String reasoning;
  final String label;
  final bool generating;
  final bool speaking;

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
          ReplyFrame(
            model: label,
            stage: ReplyStage.fromActivity(
              generating: generating,
              hasReply: reply.isNotEmpty,
              speaking: speaking,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
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
                        style: const TextStyle(
                          color: secondaryInk,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                if (reply.isNotEmpty) ...[
                  const SizedBox(height: 9),
                  SelectionArea(
                    child: MarkdownBody(
                      data: reply,
                      imageBuilder: (_, _, alt) => Text(alt ?? ''),
                      styleSheet:
                          MarkdownStyleSheet.fromTheme(Theme.of(context))
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
                if (!generating && reply.isNotEmpty)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: IconButton(
                      tooltip: '复制回复',
                      onPressed: () => _copy(context),
                      icon: const Icon(Icons.content_copy_rounded, size: 18),
                    ),
                  ),
              ],
            ),
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
    listenable: Listenable.merge([interaction, interaction.noticeQueue]),
    builder: (context, _) {
      final hasNotices = includeNotice && interaction.notice != null;
      final shared = interaction.sharedText;
      final showAnswer =
          showReply && (interaction.generating || interaction.reply.isNotEmpty);
      if (!hasNotices && shared == null && !showAnswer) {
        return const SizedBox.shrink();
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (includeNotice) NoticeSignal(interaction),
          if (showAnswer) ReplyPreview(interaction),
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
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(
      maxHeight: math.min(320, MediaQuery.sizeOf(context).height * .62),
    ),
    child: ListenableBuilder(
      listenable: interaction.noticeQueue,
      builder: (context, _) => NoticeStack(
        items: interaction.noticeQueue.groups,
        onDismissed: interaction.noticeQueue.removeGroup,
        itemBuilder: (group) => _NoticeHud(
          interaction,
          group.latest,
          group: group,
          key: ObjectKey(group),
        ),
      ),
    ),
  );
}

class _NoticeHud extends StatefulWidget {
  const _NoticeHud(
    this.interaction,
    this.notice, {
    this.summaryOnly = false,
    this.group,
    super.key,
  });

  final RobotInteraction interaction;
  final PhoneNotice notice;
  final bool summaryOnly;
  final NoticeGroup<PhoneNotice>? group;

  @override
  State<_NoticeHud> createState() => _NoticeHudState();
}

class _NoticeHudState extends State<_NoticeHud> {
  late final _logo = widget.interaction.noticeAppIcon(widget.notice);

  @override
  Widget build(BuildContext context) {
    final notice = widget.notice;
    final count = widget.group?.items.length ?? 1;
    return Semantics(
      liveRegion: !widget.summaryOnly,
      child: NoticeCardFrame(
        count: count,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: () => _showNotice(
              context,
              widget.interaction,
              notice,
              group: widget.group,
            ),
            child: NoticeCardContent(
              source: notice.source,
              title: notice.title,
              text: widget.summaryOnly ? '' : notice.text,
              icon: NoticeAppLogo(_logo),
              count: count,
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _openVoiceSettings(
  BuildContext context,
  RobotInteraction interaction,
) => openSettingsPage(context, '语音模型管理', (_) => _VoiceSettings(interaction));

class _VoiceSettings extends StatelessWidget {
  const _VoiceSettings(this.interaction);

  final RobotInteraction interaction;

  Future<void> _removeModel(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除 ZipVoice 模型'),
        content: const Text('删除后会释放模型占用的空间。需要时可以重新下载。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (context.mounted && confirmed == true) {
      await interaction.removeOfflineVoice();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: interaction,
    builder: (context, _) {
      final installed = interaction.offlineVoiceInstalled;
      final progress = interaction.voiceDownloadProgress;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (interaction.supportsOfflineVoice)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('ZipVoice Distill INT8'),
              subtitle: Text(
                interaction.removingVoice
                    ? '正在删除…'
                    : installed
                    ? '已安装 · 普通话和英语'
                    : '未安装 · 下载约 163 MB',
              ),
            )
          else
            const Text('此设备使用系统朗读。'),
          if (interaction.installingVoice) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 8),
            Text(
              progress == null
                  ? '正在校验并安装模型…'
                  : '正在下载模型 ${(progress * 100).round()}%',
            ),
          ],
          if (interaction.voiceInstallError case final error?)
            Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          Wrap(
            spacing: 8,
            children: [
              if (interaction.supportsOfflineVoice &&
                  !installed &&
                  !interaction.removingVoice)
                OutlinedButton(
                  onPressed: interaction.installingVoice
                      ? null
                      : interaction.installOfflineVoice,
                  child: const Text('下载模型'),
                ),
              if (installed)
                TextButton.icon(
                  onPressed: interaction.removingVoice
                      ? null
                      : () => _removeModel(context),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('删除模型'),
                ),
              TextButton.icon(
                onPressed:
                    interaction.canPreviewVoice &&
                        !interaction.removingVoice &&
                        (installed || !interaction.supportsOfflineVoice)
                    ? interaction.previewVoice
                    : null,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('试听'),
              ),
            ],
          ),
        ],
      );
    },
  );
}

Future<void> openInteractionSettings(
  BuildContext context,
  RobotInteraction interaction,
) => openSettingsPage(
  context,
  '语音与提醒',
  (route) => ListenableBuilder(
    listenable: interaction,
    builder: (context, _) => SettingsGroup([
      SwitchListTile(
        title: const Text('朗读 AI 回复'),
        value: interaction.readAnswers,
        onChanged: interaction.setReadAnswers,
      ),
      SwitchListTile(
        title: const Text('播报重要提醒'),
        value: interaction.readNotices,
        onChanged: interaction.setReadNotices,
      ),
      SettingsEntry(
        Icons.record_voice_over_outlined,
        '语音模型管理',
        () => _openVoiceSettings(route, interaction),
      ),
      if (interaction.supportsNotifications)
        SettingsEntry(
          Icons.rule,
          '提醒规则',
          () => _openNoticeRules(route, interaction),
          detail: '通知访问权限、关注的 App、联系人和关键词',
        ),
      SettingsEntry(
        Icons.history,
        '最近提醒',
        () => openRecentNotices(route, interaction),
      ),
    ]),
  ),
);

Future<void> _openNoticeRules(
  BuildContext context,
  RobotInteraction interaction,
) => openSettingsPage(
  context,
  '提醒规则',
  (_) => ListenableBuilder(
    listenable: interaction,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton(
          onPressed: interaction.openNotificationSettings,
          child: Text(interaction.notificationAccess ? '管理通知访问权限' : '开启通知访问权限'),
        ),
        if (interaction.notificationAccess) NoticeRules(interaction),
      ],
    ),
  ),
);

Future<void> openRecentNotices(
  BuildContext context,
  RobotInteraction interaction,
) => openSettingsPage(
  context,
  '最近提醒',
  (_) => ListenableBuilder(
    listenable: interaction,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (interaction.recentNotices.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('暂无提醒', style: TextStyle(color: secondaryInk)),
          ),
        for (final item in interaction.recentNotices)
          Padding(
            key: ValueKey(item),
            padding: const EdgeInsets.only(bottom: 8),
            child: _NoticeHud(interaction, item, summaryOnly: true),
          ),
      ],
    ),
  ),
);
