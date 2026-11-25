import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'chat_reasoning.dart';
import 'phone_model.dart';
import 'remote.dart';

enum InteractionPhase { idle, listening, thinking, answering }

typedef ChatTurn = ({
  String id,
  String question,
  String reply,
  String reasoning,
  String label,
});

typedef PhoneNotice = ({
  String source,
  String title,
  String text,
  bool verification,
  String? id,
});

class NoticeChoice {
  const NoticeChoice(this.id, this.name, [this.aliases = const []]);

  final String id;
  final String name;
  final List<String> aliases;

  static NoticeChoice? parse(Object? raw) {
    if (raw is! Map || raw['id'] is! String || raw['name'] is! String) {
      return null;
    }
    final aliases = raw['aliases'];
    return NoticeChoice(
      raw['id'] as String,
      raw['name'] as String,
      aliases is List ? aliases.whereType<String>().toList() : const [],
    );
  }

  Map<String, Object> toJson() => {'id': id, 'name': name, 'aliases': aliases};

  bool matchesSender(String sender) {
    final nameKey = sender.trim().toLowerCase();
    if (nameKey.isEmpty) return false;
    if (name.trim().toLowerCase() == nameKey) return true;
    if (!RegExp(r'^\+?[\d ()-]+$').hasMatch(nameKey)) return false;
    final digits = nameKey.replaceAll(RegExp(r'\D'), '');
    return digits.length >= 7 &&
        aliases.any((alias) => alias.replaceAll(RegExp(r'\D'), '') == digits);
  }
}

class RobotInteraction extends ChangeNotifier {
  RobotInteraction(this.remote, this.pairing);

  static const bridge = MethodChannel('com.reareyes/interaction');
  static const events = EventChannel('com.reareyes/interactionEvents');
  static final _sentenceEnd = RegExp(r'[。！？!?\n]|\.(?=\s)');

  final RemoteClient remote;
  final Pairing? Function() pairing;
  final _utterances = Queue<({String text, bool notice})>();
  final _history = <Map<String, String>>[];
  final _recentNotices = <PhoneNotice>[];
  final _sources = <String, String>{};
  final _allowedSources = <String>{};
  final _contacts = <String, NoticeChoice>{};
  final _seenEvents = <String>{};
  StreamSubscription<dynamic>? _events;
  StreamSubscription<ChatChunk>? _answer;
  final _recentTurns = <ChatTurn>[];
  bool _replyCompleted = false;
  String? turnId;
  ({Pairing pairing, String id})? _activeRequest;
  Timer? _noticeTimer;
  Timer? _speakingTimer;
  Timer? _recordingDeadline;
  bool _disposed = false;
  bool _initialized = false;
  bool _foreground = true;
  bool _speechPending = false;
  String? _speechId;
  int _nextSpeechId = 0;
  bool _stopSpeechPending = false;
  int _request = 0;
  int _catalog = 0;
  int _spokenThrough = 0;
  bool _muteReply = false;
  bool _speechEnabled = false;
  bool _canRead = false;
  bool _liveActivity = false;
  bool _listeningStarting = false;
  bool _sendAfterRecording = false;
  bool _preparingSend = false;
  String _previousDraft = '';
  String? _activityState;
  String? _historyTarget;
  String? _pendingNotice;
  EyeMood? _expression;

  InteractionPhase phase = InteractionPhase.idle;
  List<DesktopModel> models = const [];
  ModelSource modelSource = ModelSource.desktop;
  PhoneModel? phoneModel;
  double inputLevel = 0;
  bool loading = false;
  bool readAnswers = true;
  bool readNotices = false;
  bool notificationAccess = false;
  List<String> _keywords = const [];
  String draft = '';
  String question = '';
  String reply = '';
  String reasoning = '';
  String? replyModel;
  String? spokenText;
  String? error;
  String? modelError;
  String? sharedText;
  PhoneNotice? notice;

  bool get nativeEnabled => _initialized;
  bool get speechEnabled => _speechEnabled;
  bool get supportsNotifications => _canRead;
  bool get generating =>
      phase == InteractionPhase.thinking || phase == InteractionPhase.answering;
  bool get listening => phase == InteractionPhase.listening;
  bool get finishingRecording => _recordingDeadline != null;
  List<PhoneNotice> get recentNotices => List.unmodifiable(_recentNotices);
  List<ChatTurn> get recentTurns => List.unmodifiable(_recentTurns);
  List<NoticeChoice> get selectedApps => [
    for (final id in _allowedSources) NoticeChoice(id, _sources[id] ?? id),
  ];
  List<NoticeChoice> get selectedContacts =>
      List.unmodifiable(_contacts.values);
  List<String> get keywords => List.unmodifiable(_keywords);

  EyeMood? get mood => switch (phase) {
    InteractionPhase.listening => EyeMood.focus,
    InteractionPhase.thinking => EyeMood.thinking,
    InteractionPhase.answering => EyeMood.hello,
    InteractionPhase.idle =>
      spokenText != null
          ? EyeMood.hello
          : _expression ?? (notice == null ? null : EyeMood.idea),
  };

  DesktopModel? get model => models.firstOrNull;
  String get modelLabel => modelSource == ModelSource.desktop
      ? model == null
            ? modelSource.label
            : '电脑默认 · ${model!.name}'
      : '${modelSource.label} · ${phoneModel?.model ?? '待配置'}';

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  Future<void> initialize() async {
    if (kIsWeb) return;
    try {
      final capabilities = await bridge.invokeMapMethod<String, dynamic>(
        'capabilities',
      );
      if (_disposed) return;
      _speechEnabled = capabilities?['speech'] == true;
      _canRead = capabilities?['notifications'] == true;
      _liveActivity = capabilities?['liveActivity'] == true;
      _initialized = true;
      await _loadSettings();
      if (_disposed) return;
      _events = events.receiveBroadcastStream().listen(
        _handleEvent,
        onError: (Object _) {
          if (listening) _finishListening('语音连接已中断');
        },
      );
      await resume();
    } on MissingPluginException {
      // The desktop Web App and older native hosts do not provide this channel.
    } on PlatformException {
      error = '无法初始化手机联动';
    } finally {
      notifyListeners();
    }
  }

  Future<void> _loadSettings() async {
    try {
      final raw = await bridge.invokeMethod<String>('loadSettings');
      if (raw == null) return;
      final data = jsonDecode(raw);
      if (data is! Map) return;
      readAnswers = data['readAnswers'] != false;
      readNotices = data['readNotices'] == true;
      phoneModel = PhoneModel.fromJson(data['phoneModel']);
      if (phoneModel?.source.name == data['modelSource']) {
        modelSource = phoneModel?.source ?? ModelSource.desktop;
      }
      final filter = data['filter'];
      final keywords = data['keywords'];
      if (keywords is List) {
        _keywords = keywords.whereType<String>().toList();
      } else if (filter is String) {
        _keywords = filter
            .split(RegExp(r'[,，\n]+'))
            .map((term) => term.trim())
            .where((term) => term.isNotEmpty)
            .toSet()
            .toList();
      }
      final contacts = data['contacts'];
      if (contacts is List) {
        for (final raw in contacts) {
          if (NoticeChoice.parse(raw) case final entry?) {
            _contacts[entry.id] = entry;
          }
        }
      }
      final sources = data['sources'];
      if (sources is Map) {
        for (final entry in sources.entries) {
          if (entry.key is String && entry.value is String) {
            _sources[entry.key as String] = entry.value as String;
            _allowedSources.add(entry.key as String);
          }
        }
      }
    } on PlatformException {
      error = '无法读取交互设置';
    } on FormatException {
      error = '已保存的交互设置无效';
    } on MissingPluginException {
      // Older native hosts use the defaults.
    }
  }

  void _saveSettings() {
    unawaited(
      _invoke<void>(
        'saveSettings',
        jsonEncode({
          'readAnswers': readAnswers,
          'readNotices': readNotices,
          'modelSource': modelSource.name,
          'phoneModel': phoneModel?.toJson(),
          'keywords': _keywords,
          'contacts': _contacts.values.map((entry) => entry.toJson()).toList(),
          'sources': {
            for (final key in _allowedSources) key: _sources[key] ?? key,
          },
        }),
      ),
    );
    notifyListeners();
  }

  Future<T?> _invoke<T>(String method, [Object? args]) async {
    if (!_initialized || _disposed) return null;
    try {
      return await bridge.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<void> resume() async {
    _foreground = true;
    if (!_initialized) return;
    if (_canRead) {
      notificationAccess = await _invoke<bool>('notificationAccess') ?? false;
      if (!notificationAccess) {
        _recentNotices.clear();
        _pendingNotice = null;
        clearNotice();
      }
    }
    final pending = await _invoke<List<dynamic>>('pendingEvents');
    if (!_disposed) {
      for (final event in pending ?? const []) {
        _handleEvent(event);
      }
      notifyListeners();
    }
  }

  void pause() {
    _foreground = false;
    if (listening) unawaited(cancelRecording());
    // Native engines may change audio focus when the app leaves the foreground.
    unawaited(muteCurrent());
  }

  Future<void> openNotificationSettings() =>
      _invoke<void>('openNotificationSettings');

  Future<String?> noticeDetails(PhoneNotice item) => item.id == null
      ? Future.value(null)
      : _invoke<String>('notificationDetails', item.id);

  Future<void> fetchModels() async {
    if (modelSource != ModelSource.desktop) return;
    final scope = ++_catalog;
    final connection = pairing();
    if (connection == null) {
      models = const [];
      loading = false;
      modelError = '请先配对运行 Robot Eyes 的电脑。';
      notifyListeners();
      return;
    }
    loading = true;
    modelError = null;
    notifyListeners();
    try {
      final result = await remote.models(connection);
      if (scope != _catalog || _disposed) return;
      models = result;
      if (result.isEmpty) modelError = '请在电脑的「模型连接」添加模型。';
    } catch (_) {
      if (scope == _catalog) modelError = '无法读取电脑模型，请检查配对和桌面服务。';
    } finally {
      if (scope == _catalog) {
        loading = false;
        notifyListeners();
      }
    }
  }

  void configureModel(ModelSource source, PhoneModel? profile) {
    ++_catalog;
    modelSource = source;
    if (profile != null) phoneModel = profile;
    modelError = null;
    loading = false;
    _saveSettings();
  }

  void resetConnection() {
    ++_catalog;
    unawaited(cancelAnswer());
    models = const [];
    loading = false;
    modelError = null;
    _history.clear();
    _historyTarget = null;
    notifyListeners();
  }

  void setReadAnswers(bool value) {
    readAnswers = value;
    if (!value) unawaited(muteCurrent());
    _saveSettings();
  }

  void setReadNotices(bool value) {
    readNotices = value;
    if (!value) {
      _pendingNotice = null;
      _utterances.removeWhere((item) => item.notice);
    }
    _saveSettings();
  }

  Future<List<NoticeChoice>> loadNoticeChoices({required bool contacts}) async {
    final raw = await bridge.invokeListMethod<Object?>(
      contacts ? 'notificationContacts' : 'notificationApps',
    );
    final choices = <String, NoticeChoice>{
      if (!contacts)
        for (final entry in _sources.entries)
          entry.key: NoticeChoice(entry.key, entry.value),
    };
    for (final item in raw ?? const []) {
      if (NoticeChoice.parse(item) case final entry?) choices[entry.id] = entry;
    }
    return choices.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  void saveNoticeChoices(List<NoticeChoice> choices, {required bool contacts}) {
    if (contacts) {
      _contacts
        ..clear()
        ..addEntries(choices.map((choice) => MapEntry(choice.id, choice)));
    } else {
      _allowedSources
        ..clear()
        ..addAll(choices.map((choice) => choice.id));
      _sources.addEntries(
        choices.map((choice) => MapEntry(choice.id, choice.name)),
      );
    }
    _saveSettings();
  }

  void saveKeywords(List<String> values) {
    _keywords = values;
    _saveSettings();
  }

  void setDraft(String value) => draft = value;

  void startNewConversation() {
    unawaited(cancelAnswer());
    _history.clear();
    _historyTarget = null;
    _recentTurns.clear();
    _replyCompleted = false;
    turnId = null;
    draft = question = reply = reasoning = '';
    replyModel = error = null;
    notifyListeners();
  }

  Future<void> startRecording({bool sendAfter = false}) async {
    if (!_speechEnabled || _listeningStarting || listening) return;
    _listeningStarting = true;
    await cancelAnswer();
    if (_disposed) return;
    _previousDraft = draft;
    _sendAfterRecording = sendAfter;
    draft = '';
    inputLevel = 0;
    error = null;
    phase = InteractionPhase.listening;
    notifyListeners();
    try {
      await bridge.invokeMethod<void>('startListening');
    } on PlatformException {
      _finishListening('无法开始录音，请检查麦克风和语音识别权限。');
    } on MissingPluginException {
      _finishListening('当前设备无法使用语音识别。');
    } finally {
      _listeningStarting = false;
    }
  }

  Future<void> stopRecording({bool sendAfter = false}) async {
    if (!listening) return;
    _sendAfterRecording = _sendAfterRecording || sendAfter;
    if (finishingRecording) return;
    _recordingDeadline = Timer(const Duration(seconds: 4), () {
      _finishListening(draft.trim().isEmpty ? '没有听清，请重试。' : null);
      unawaited(_invoke<void>('cancelListening'));
    });
    notifyListeners();
    await _invoke<void>('stopListening');
  }

  Future<void> cancelRecording() async {
    if (!listening) return;
    _sendAfterRecording = false;
    draft = '';
    _finishListening(null);
    await _invoke<void>('cancelListening');
  }

  void _finishListening(String? message) {
    if (!listening) return;
    _recordingDeadline?.cancel();
    _recordingDeadline = null;
    inputLevel = 0;
    final heard = draft.trim().isNotEmpty;
    final submit = _sendAfterRecording && heard;
    final missingTranscript = _sendAfterRecording && !heard;
    _sendAfterRecording = false;
    phase = InteractionPhase.idle;
    error = heard ? null : message ?? (missingTranscript ? '没有听清，请重试。' : null);
    if (!heard) draft = _previousDraft;
    _previousDraft = '';
    notifyListeners();
    if (submit) {
      unawaited(send());
    } else {
      _queueNotice();
    }
  }

  Future<void> send([String? text]) async {
    if (listening) {
      await stopRecording(sendAfter: true);
      return;
    }
    if (generating || _preparingSend) return;
    final input = (text ?? draft).trim();
    if (input.isEmpty) return;
    if (input.length > 4000) {
      error = '问题最多 4000 个字符。';
      notifyListeners();
      return;
    }
    final source = modelSource;
    final conversation = source == ModelSource.desktop ? pairing() : null;
    final direct = source == ModelSource.desktop ? null : phoneModel;
    final attempt = _request;
    if (conversation != null) {
      _preparingSend = true;
      try {
        await fetchModels();
      } finally {
        _preparingSend = false;
      }
      if (_disposed ||
          attempt != _request ||
          modelSource != source ||
          pairing()?.encode() != conversation.encode() ||
          listening) {
        return;
      }
    }
    final chosen = conversation == null ? null : model;
    if (direct == null &&
        (conversation == null || chosen == null || modelError != null)) {
      error = source != ModelSource.desktop
          ? '请在「模型设置」填写连接配置。'
          : modelError ?? '请先配对电脑并在电脑端设置默认模型。';
      notifyListeners();
      return;
    }
    final target = direct != null
        ? '${direct.endpoint}\n${direct.model}\n${direct.key}'
        : '${conversation!.url}\n${conversation.token}\n${chosen!.id}';
    if (target != _historyTarget) {
      _historyTarget = target;
      _history.clear();
    }
    final generation = ++_request;
    final requestId = RemoteClient.messageId();
    if (_replyCompleted ||
        (question != input && (reply.isNotEmpty || reasoning.isNotEmpty))) {
      _recentTurns.add((
        id: turnId!,
        question: question,
        reply: reply,
        reasoning: reasoning,
        label: replyModel ?? 'Robot Eyes',
      ));
      if (_recentTurns.length > 20) _recentTurns.removeAt(0);
    }
    _replyCompleted = false;
    turnId = requestId;
    draft = '';
    question = input;
    reply = '';
    reasoning = '';
    replyModel = direct?.model ?? chosen!.name;
    error = null;
    _spokenThrough = 0;
    _muteReply = false;
    phase = InteractionPhase.thinking;
    notifyListeners();
    await _stopSpeech();
    if (generation != _request || _disposed) return;
    if (conversation != null) {
      _activeRequest = (pairing: conversation, id: requestId);
    }
    final messages = [
      ..._history,
      {'role': 'user', 'content': input},
    ];
    final response = direct == null
        ? remote.chat(conversation!, chosen!, messages, requestId)
        : remote.directChat(direct, messages);
    final parser = ChatReasoning();
    void append(ChatChunk chunk) {
      if (chunk.text.isEmpty) return;
      if (chunk.thinking) {
        reasoning += chunk.text;
      } else {
        reply += chunk.text;
        phase = InteractionPhase.answering;
      }
    }

    _answer = response.listen(
      (chunk) {
        if (generation != _request || chunk.text.isEmpty) return;
        if (chunk.thinking) {
          append(chunk);
        } else {
          parser.add(chunk.text).forEach(append);
        }
        _speakReplySentences();
        notifyListeners();
      },
      onDone: () {
        if (generation != _request) return;
        _answer = null;
        _activeRequest = null;
        append(parser.finish());
        phase = InteractionPhase.idle;
        if (reply.trim().isEmpty) {
          error = '模型没有返回内容。';
          if (draft.isEmpty) draft = question;
        } else {
          _replyCompleted = true;
          _history.addAll([
            {'role': 'user', 'content': input},
            {
              'role': 'assistant',
              'content': reply.length > 4000 ? reply.substring(0, 4000) : reply,
            },
          ]);
          if (_history.length > 6) _history.removeRange(0, 2);
          _speakReplySentences(finished: true);
        }
        _queueNotice();
        notifyListeners();
      },
      onError: (Object failure) {
        if (generation != _request) return;
        _answer = null;
        final request = _activeRequest;
        _activeRequest = null;
        if (request != null) {
          unawaited(remote.cancelChat(request.pairing, request.id));
        }
        phase = InteractionPhase.idle;
        error = failure is FormatException
            ? failure.message
            : '模型连接中断，请检查当前模型设置后重试。';
        if (draft.isEmpty) draft = question;
        unawaited(_stopSpeech());
        notifyListeners();
      },
      cancelOnError: true,
    );
  }

  Future<void> cancelAnswer() async {
    ++_request;
    final answer = _answer;
    _answer = null;
    final request = _activeRequest;
    _activeRequest = null;
    if (request != null) {
      unawaited(remote.cancelChat(request.pairing, request.id));
    }
    if (generating) {
      phase = InteractionPhase.idle;
      if (draft.isEmpty) draft = question;
    }
    await Future.wait([if (answer != null) answer.cancel(), _stopSpeech()]);
    notifyListeners();
  }

  Future<void> muteCurrent() {
    _muteReply = true;
    _pendingNotice = null;
    return _stopSpeech();
  }

  Future<void> _stopSpeech() async {
    _utterances.clear();
    final wasSpeaking = _speechPending || spokenText != null;
    _speechPending = false;
    _speechId = null;
    spokenText = null;
    _speakingTimer?.cancel();
    if (wasSpeaking && !_stopSpeechPending) {
      _stopSpeechPending = true;
      await _invoke<void>('stopSpeaking');
      _stopSpeechPending = false;
    }
    notifyListeners();
    _playNext();
  }

  void _speakReplySentences({bool finished = false}) {
    if (!readAnswers || _muteReply) return;
    final rest = reply.substring(_spokenThrough);
    var start = 0;
    for (final match in _sentenceEnd.allMatches(rest)) {
      _enqueueSpeech(rest.substring(start, match.end));
      start = match.end;
    }
    if (finished && start < rest.length) {
      _enqueueSpeech(rest.substring(start));
      start = rest.length;
    }
    _spokenThrough += start;
  }

  void _enqueueSpeech(String text, {bool notice = false}) {
    final trimmed = text.trim();
    if (!_speechEnabled || trimmed.isEmpty) return;
    for (var offset = 0; offset < trimmed.length; offset += 400) {
      final end = offset + 400;
      _utterances.add((
        text: end < trimmed.length
            ? trimmed.substring(offset, end)
            : trimmed.substring(offset),
        notice: notice,
      ));
    }
    _playNext();
  }

  void _playNext() {
    if (_stopSpeechPending ||
        _speechPending ||
        _disposed ||
        _utterances.isEmpty) {
      return;
    }
    final utterance = _utterances.removeFirst();
    _speechPending = true;
    _speechId = (++_nextSpeechId).toString();
    spokenText = utterance.text;
    _speakingTimer = Timer(const Duration(seconds: 40), _speechDone);
    unawaited(_speak(utterance.text, _speechId!));
    notifyListeners();
  }

  Future<void> _speak(String text, String id) async {
    try {
      await bridge.invokeMethod<void>('speak', {'text': text, 'id': id});
    } on PlatformException {
      if (!_disposed && _speechId == id) _speechDone();
    } on MissingPluginException {
      if (!_disposed && _speechId == id) _speechDone();
    }
  }

  void _speechDone() {
    if (!_speechPending) return;
    _speakingTimer?.cancel();
    _speechPending = false;
    _speechId = null;
    spokenText = null;
    _queueNotice();
    _playNext();
    notifyListeners();
  }

  void _queueNotice() {
    if (listening ||
        generating ||
        spokenText != null ||
        _utterances.isNotEmpty) {
      return;
    }
    final pending = _pendingNotice;
    _pendingNotice = null;
    if (pending != null && readNotices) _enqueueSpeech(pending, notice: true);
  }

  void clearNotice() {
    notice = null;
    _noticeTimer?.cancel();
    notifyListeners();
  }

  void dismissShared() {
    sharedText = null;
    notifyListeners();
  }

  void _handleEvent(dynamic value) {
    if (_disposed || value is! Map) return;
    switch (value['type']) {
      case 'speech':
        if (!listening) return;
        if (value['text'] case final String text when text.trim().isNotEmpty) {
          draft = text;
        }
        if (value['final'] == true) _finishListening(null);
      case 'speechEnd':
        _finishListening(null);
      case 'speechError':
        _finishListening(
          value['text'] is String
              ? value['text'] as String
              : '没有完成语音识别，请重试或使用文字输入。',
        );
      case 'speechLevel':
        if (!listening || finishingRecording) return;
        if (value['level'] case final num level when level.isFinite) {
          inputLevel = level.toDouble().clamp(0.0, 1.0);
        }
      case 'speechDone':
        if (value['id'] == null || value['id'] == _speechId) _speechDone();
      case 'notification':
        _receiveNotice(value);
      case 'expression':
        for (final mood in EyeMood.values) {
          if (value['expression'] == mood.wire) {
            _expression = mood;
            _noticeTimer?.cancel();
            _noticeTimer = Timer(const Duration(seconds: 6), () {
              _expression = null;
              clearNotice();
            });
          }
        }
      case 'share':
        if (value['text'] case final String text when text.trim().isNotEmpty) {
          sharedText = text;
        }
      default:
        return;
    }
    notifyListeners();
  }

  void _receiveNotice(Map<dynamic, dynamic> event) {
    final source = event['app'];
    final title = event['title'];
    final text = event['text'];
    final verification = event['verification'] == true;
    final sender = event['sender'];
    final package = event['package'];
    final key = package is String ? package : source;
    if (source is! String || source.isEmpty || key is! String) return;
    if (_canRead) {
      if (_sources.length < 64 || _sources.containsKey(key)) {
        _sources[key] = source;
      }
      if (!_allowedSources.contains(key)) return;
      final content = [
        sender,
        title,
        text,
      ].whereType<String>().join(' ').toLowerCase();
      if (!verification &&
          (_keywords.isNotEmpty || _contacts.isNotEmpty) &&
          !_keywords.any((term) => content.contains(term.toLowerCase())) &&
          !(sender is String &&
              _contacts.values.any((entry) => entry.matchesSender(sender)))) {
        return;
      }
    }
    if (event['id'] case final String id) {
      final received = '$id:${event['timestamp'] ?? ''}';
      if (!_seenEvents.add(received)) return;
      if (_seenEvents.length > 96) _seenEvents.remove(_seenEvents.first);
    }
    final received = (
      source: source,
      title: verification
          ? '收到验证消息'
          : title is String
          ? title
          : '新提醒',
      text: verification
          ? ''
          : text is String
          ? text
          : '',
      verification: verification,
      id: event['id'] is String ? event['id'] as String : null,
    );
    if (_recentNotices.firstOrNull == received) return;
    _recentNotices.insert(0, received);
    if (_recentNotices.length > 20) _recentNotices.removeLast();
    notice = received;
    _expression = null;
    _noticeTimer?.cancel();
    _noticeTimer = Timer(const Duration(seconds: 9), clearNotice);
    if (_foreground &&
        readNotices &&
        !verification &&
        event['initial'] != true) {
      _pendingNotice = '${received.source}，${received.title}';
      _queueNotice();
    }
  }

  void updateActivity(EyeMood mood) {
    if (!_liveActivity || _activityState == mood.wire) return;
    _activityState = mood.wire;
    if (mood == EyeMood.thinking || mood == EyeMood.question) {
      unawaited(
        _invoke<void>('updateLiveActivity', {
          'state': mood.wire,
          'title': mood.label,
        }),
      );
    } else {
      unawaited(_invoke<void>('endLiveActivity'));
    }
  }

  @override
  void dispose() {
    _recordingDeadline?.cancel();
    final request = _activeRequest;
    if (request != null) {
      unawaited(remote.cancelChat(request.pairing, request.id));
    }
    if (_speechPending) unawaited(_invoke<void>('stopSpeaking'));
    if (listening) unawaited(_invoke<void>('cancelListening'));
    _disposed = true;
    _noticeTimer?.cancel();
    _speakingTimer?.cancel();
    unawaited(_events?.cancel());
    unawaited(_answer?.cancel());
    super.dispose();
  }
}
