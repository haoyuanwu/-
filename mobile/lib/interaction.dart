import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:robot_eyes_models/robot_eyes_models.dart';

import 'chat_reasoning.dart';
import 'offline_voice.dart';
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
  String? eventKey,
  String? packageName,
});

const _verificationLabel =
    r'验证码|驗證碼|校验码|認証コード|인증번호|동적\s*코드|\bOTP\b|'
    r'one[- ]time (?:passcode|password|pin|code)|verification code|'
    r'authentication code|security code|login code|confirmation code';
const _codeToken =
    r'(?<![a-z0-9])((?=[a-z0-9]{0,7}[0-9])[a-z0-9]{4,8})(?![a-z0-9])';
final _labeledCode = RegExp(
  '(?:$_verificationLabel)[ \\t]*(?:为|為|是|is\\b)?[ \\t:：]*$_codeToken'
  '|$_codeToken[ \\t]*(?:是|为|為|is[ \\t]+(?:your[ \\t]+(?:[a-z]+[ \\t]+){0,3})?)?[ \\t]*(?:您的?)?[ \\t]*(?:$_verificationLabel)',
  caseSensitive: false,
);
final _standaloneCode = RegExp('^$_codeToken\$', caseSensitive: false);

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
  static final _speechText = RegExp(r'[a-zA-Z0-9\u3400-\u9fff]');

  final RemoteClient remote;
  final Pairing? Function() pairing;
  final _offlineVoice = OfflineVoice();
  AudioPlayer? _voicePlayer;
  StreamSubscription<void>? _voiceCompletion;
  Future<void> Function()? _deleteVoiceFile;
  bool _installingVoice = false;
  bool _removingVoice = false;
  double? voiceDownloadProgress;
  String? voiceInstallError;
  final _utterances = Queue<({String text, bool notice})>();
  final _history = <({Map<String, String> message, GgufMedia? media})>[];
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
  ({PhoneNotice notice, bool initial, String speech})? _unshownNotice;
  Timer? _noticeTimer;
  Timer? _noticeReactionTimer;
  Timer? _speakingTimer;
  Timer? _recordingDeadline;
  Timer? _minimumRecording;
  String _earlyTranscript = '';
  bool get _recordingTooShort => _minimumRecording?.isActive ?? true;
  bool _disposed = false;
  bool _initialized = false;
  bool _foreground = true;
  bool _speechPending = false;
  bool _speakingNotice = false;
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
  bool _cancellingRecording = false;
  bool _sendAfterRecording = false;
  bool _preparingSend = false;
  String? _retryInput;
  bool _settingsLoaded = false;
  Future<void>? _phoneSyncTask;
  bool _phoneSyncQueued = false;
  String? phoneModelSyncError;
  DateTime? _nextPhoneModelSync;
  String? _phoneSyncId;
  String? _phoneSyncOwner;
  String? _phoneSyncRevision;
  String? _phoneCatalogRevision;
  String? _phoneSyncEdit;
  bool _phoneSyncAdd = false;
  String? _phoneSyncCompare;
  bool _phoneSyncConnected = false;
  ({int id, String message})? phoneModelUpdate;
  CloudConflictSummary? phoneModelConflict;
  List<SavedCloudModel> savedCloudModels = const [];
  final _cloudProfiles = <PhoneModel>[];
  final _localProfiles = <PhoneModel>[];
  List<PhoneModel> get localProfiles => List.unmodifiable(_localProfiles);
  List<PhoneModel> get cloudProfiles => [
    ..._cloudProfiles.where(
      (profile) =>
          profile.modelIds.isNotEmpty ||
          !savedCloudModels.any((item) => profile.sameCloud(item.profile)),
    ),
    ...savedCloudModels
        .map((item) => item.profile)
        .where(
          (profile) => !_cloudProfiles.any(
            (local) => local.modelIds.isNotEmpty && profile.sameCloud(local),
          ),
        ),
    if (phoneModel case final active? when active.source == ModelSource.cloud)
      if (!_cloudProfiles.any(active.sameCloud) &&
          !savedCloudModels.any((item) => active.sameCloud(item.profile)))
        active,
  ];
  String _previousDraft = '';
  String? _activityState;
  String? _historyTarget;
  ({PhoneNotice notice, String? text})? _pendingNotice;
  bool _readingNoticeCode = false;
  EyeMood? _expression;

  InteractionPhase phase = InteractionPhase.idle;
  List<DesktopModel> models = const [];
  ModelSource modelSource = ModelSource.desktop;
  PhoneModel? phoneModel;
  double inputLevel = 0;
  int speechActivity = 0;
  bool loading = false;
  bool readAnswers = true;
  bool readNotices = false;
  bool notificationAccess = false;
  List<String> _keywords = const [];
  String draft = '';
  GgufMedia? draftMedia;
  GgufMedia? _activeMedia;
  String? _activeMediaPrompt;

  Set<GgufMediaType> get localMediaTypes => modelSource == ModelSource.local
      ? phoneModel?.mediaTypes ?? const {}
      : const {};

  void setDraftMedia(GgufMedia? media) {
    if (media != null && !localMediaTypes.contains(media.type)) return;
    draftMedia = media;
    error = null;
    _retryInput = null;
    notifyListeners();
  }

  String question = '';
  String reply = '';
  String reasoning = '';
  String? replyModel;
  String? spokenText;
  String? error;
  String? modelError;
  String? sharedText;
  PhoneNotice? notice;

  String? get spokenReply => _speakingNotice ? null : spokenText;

  bool get nativeEnabled => _initialized;
  bool get speechEnabled => _speechEnabled;
  bool get supportsOfflineVoice =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  bool get offlineVoiceInstalled => _offlineVoice.installed;
  bool get installingVoice => _installingVoice;
  bool get removingVoice => _removingVoice;
  bool get canPreviewVoice =>
      _speechEnabled && !listening && !generating && !_speechPending;
  bool get supportsNotifications => _canRead;
  bool get generating =>
      phase == InteractionPhase.thinking || phase == InteractionPhase.answering;
  bool get listening => phase == InteractionPhase.listening;
  bool get conversationActive => listening || generating || spokenReply != null;
  bool get startingRecording => listening && _minimumRecording == null;
  bool get finishingRecording => _recordingDeadline != null;
  bool get canRetryReply => error != null && _retryInput == draft.trim();
  bool get phoneModelSyncing => _phoneSyncTask != null;
  bool get canSyncPhoneModel => _settingsLoaded && pairing() != null;
  bool get needsDesktopCatalogUpdate =>
      _phoneSyncConnected && _phoneCatalogRevision == null;
  String? get phoneModelSyncLabel => !canSyncPhoneModel
      ? null
      : phoneModelConflict != null
      ? '云端配置不同，等待处理'
      : _phoneSyncEdit != null
      ? '待同步到电脑'
      : _phoneSyncConnected
      ? '已与电脑同步'
      : '等待连接电脑同步';
  List<PhoneNotice> get recentNotices => List.unmodifiable(_recentNotices);
  List<ChatTurn> get recentTurns => List.unmodifiable(_recentTurns);
  List<NoticeChoice> get selectedApps => [
    for (final id in _allowedSources) NoticeChoice(id, _sources[id] ?? id),
  ];
  List<NoticeChoice> get selectedContacts =>
      List.unmodifiable(_contacts.values);
  List<String> get keywords => List.unmodifiable(_keywords);

  PhoneNotice? get noticeReaction =>
      phase == InteractionPhase.idle &&
          spokenReply == null &&
          _noticeReactionTimer?.isActive == true
      ? notice
      : null;

  Future<Uint8List?> noticeAppIcon(PhoneNotice notice) {
    final packageName = notice.packageName;
    return packageName == null
        ? Future.value(null)
        : _invoke<Uint8List>('notificationAppIcon', packageName);
  }

  EyeMood? get mood => switch (phase) {
    InteractionPhase.listening => EyeMood.focus,
    InteractionPhase.thinking => EyeMood.thinking,
    InteractionPhase.answering => EyeMood.hello,
    InteractionPhase.idle => spokenReply != null ? EyeMood.hello : _expression,
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
      if (supportsOfflineVoice) unawaited(_checkOfflineVoice());
      _settingsLoaded = true;
      if (_canRead) {
        notificationAccess = await _invoke<bool>('notificationAccess') ?? false;
        await _loadRecentNotices();
      }
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
      if (data['cloudProfiles'] case final List cloud) {
        _cloudProfiles.addAll(
          cloud
              .map(PhoneModel.fromJson)
              .nonNulls
              .where((profile) => profile.source == ModelSource.cloud),
        );
      }
      if (data['localProfiles'] case final List local) {
        _localProfiles.addAll(
          local
              .map(PhoneModel.fromJson)
              .nonNulls
              .where((profile) => profile.localPath != null),
        );
      }
      if (data['phoneModelSync'] case final Map sync) {
        if (sync['id'] case final String id) _phoneSyncId = id;
        if (sync['owner'] case final String owner) _phoneSyncOwner = owner;
        if (sync['revision'] case final String revision) {
          _phoneSyncRevision = revision;
        }
        _phoneCatalogRevision = sync['catalogRevision'] as String?;
        if (sync['edit'] case final String edit) _phoneSyncEdit = edit;
        _phoneSyncAdd = sync['add'] == true;
        if (sync['compare'] case final String compare) {
          _phoneSyncCompare = compare;
        }
        if (sync['options'] case final List options) {
          savedCloudModels = options
              .map(SavedCloudModel.read)
              .nonNulls
              .toList();
        }
      }
      if (phoneModel?.source.name == data['modelSource'] &&
          (phoneModel?.source != ModelSource.local ||
              phoneModel?.localPath != null)) {
        modelSource = phoneModel?.source ?? ModelSource.desktop;
      }
      if (phoneModel case final profile?) {
        if (_phoneSyncRevision == null || profile.source == ModelSource.local) {
          _rememberModel(profile);
        }
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

  Future<void> _loadRecentNotices() async {
    final raw = await _invoke<String>('loadRecentNotices');
    if (raw == null || _disposed) return;
    try {
      final data = jsonDecode(raw);
      if (data is! List) return;
      for (final item in data.take(20)) {
        if (item is! Map ||
            item['source'] is! String ||
            item['title'] is! String ||
            item['text'] is! String) {
          continue;
        }
        final verification = item['verification'] == true;
        final eventKey = item['eventKey'] is String
            ? item['eventKey'] as String
            : null;
        if (eventKey != null && !_seenEvents.add(eventKey)) continue;
        _recentNotices.add((
          source: item['source'] as String,
          title: verification ? '收到验证消息' : item['title'] as String,
          text: verification ? '' : item['text'] as String,
          verification: verification,
          id: item['id'] is String ? item['id'] as String : null,
          eventKey: eventKey,
          packageName: item['packageName'] is String
              ? item['packageName'] as String
              : null,
        ));
      }
    } on FormatException {
      // Ignore a damaged local history.
    }
  }

  void _saveRecentNotices() {
    if (!_canRead) return;
    unawaited(
      _invoke<void>(
        'saveRecentNotices',
        jsonEncode([
          for (final item in _recentNotices)
            {
              'source': item.source,
              'title': item.title,
              'text': item.text,
              'verification': item.verification,
              'id': item.id,
              'eventKey': item.eventKey,
              'packageName': item.packageName,
            },
        ]),
      ),
    );
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
          'cloudProfiles': _cloudProfiles
              .map((profile) => profile.toJson())
              .toList(),
          'localProfiles': _localProfiles
              .map((profile) => profile.toJson())
              .toList(),
          if (_phoneSyncId != null)
            'phoneModelSync': {
              'id': _phoneSyncId,
              'owner': _phoneSyncOwner,
              'revision': _phoneSyncRevision,
              'catalogRevision': _phoneCatalogRevision,
              'edit': _phoneSyncEdit,
              'add': _phoneSyncAdd,
              'compare': _phoneSyncCompare,
              'options': savedCloudModels.map((item) => item.toJson()).toList(),
            },
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
      notificationAccess =
          await _invoke<bool>('notificationAccess') ?? notificationAccess;
      if (!notificationAccess) {
        if (_recentNotices.isNotEmpty) {
          _recentNotices.clear();
          _seenEvents.clear();
          _saveRecentNotices();
        }
        _pendingNotice = null;
        _unshownNotice = null;
        clearNotice();
      }
    }
    final pending = await _invoke<List<dynamic>>('pendingEvents');
    if (!_disposed) {
      if (_unshownNotice case final deferred? when _foreground) {
        _unshownNotice = null;
        _showNotice(
          deferred.notice,
          initial: deferred.initial,
          speech: deferred.speech,
        );
      }
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

  Future<String?> noticeCode(PhoneNotice item) async {
    if (!item.verification || item.id == null) return null;
    final message = await _invoke<String>('notificationDetails', item.id);
    if (message == null) return null;
    final labeled = _labeledCode
        .allMatches(message)
        .map((match) => (match[1] ?? match[2])!)
        .toSet();
    if (labeled.isNotEmpty) return labeled.length == 1 ? labeled.single : null;

    final body = message.contains('\n')
        ? message.substring(message.indexOf('\n') + 1)
        : message;
    return _standaloneCode.firstMatch(body.trim())?[1];
  }

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

  void configureModel(
    ModelSource source,
    PhoneModel? profile, {
    bool add = false,
  }) {
    _phoneSyncId ??= RemoteClient.messageId();
    _phoneSyncEdit = RemoteClient.messageId();
    _phoneSyncAdd = source == ModelSource.cloud && add;
    phoneModelConflict = null;
    if (source != ModelSource.cloud) _phoneSyncCompare = null;
    if (profile != null) _rememberModel(profile);
    _applyModel(source, profile);
    unawaited(syncPhoneModel(force: true));
  }

  void _rememberModel(PhoneModel profile) {
    if (profile.source == ModelSource.cloud) {
      final existing = _cloudProfiles.indexWhere(profile.sameCloud);
      if (existing >= 0) {
        _cloudProfiles[existing] = profile;
      } else if (!savedCloudModels.any(
        (item) =>
            profile.sameCloud(item.profile) &&
            (profile.modelIds.isEmpty ||
                listEquals(profile.modelIds, item.profile.modelIds)),
      )) {
        _cloudProfiles.insert(0, profile);
      }
    }
    if (profile.localPath != null) {
      final index = _localProfiles.indexWhere(
        (item) => item.localPath == profile.localPath,
      );
      if (index < 0) {
        _localProfiles.insert(0, profile);
      } else {
        _localProfiles[index] = profile;
      }
    }
  }

  void rememberLocalModel(PhoneModel profile) {
    _rememberModel(profile);
    _saveSettings();
  }

  Future<void> removeLocalModel(PhoneModel profile) async {
    final path = profile.localPath;
    if (path == null || !_localProfiles.any((item) => item.localPath == path)) {
      return;
    }
    if (modelSource == ModelSource.local && phoneModel?.localPath == path) {
      await cancelAnswer();
    }
    if (_disposed) return;
    _localProfiles.removeWhere((item) => item.localPath == path);
    if (phoneModel?.localPath == path) {
      phoneModel = null;
      if (modelSource == ModelSource.local) {
        draftMedia = null;
        configureModel(ModelSource.desktop, null);
        return;
      }
    }
    _saveSettings();
  }

  void _applyModel(ModelSource source, PhoneModel? profile) {
    ++_catalog;
    if (draftMedia case final media?
        when source != ModelSource.local ||
            phoneModel?.localPath != profile?.localPath ||
            profile?.mediaTypes.contains(media.type) != true) {
      draftMedia = null;
    }
    modelSource = source;
    if (profile != null) phoneModel = profile;
    modelError = null;
    loading = false;
    _saveSettings();
  }

  Future<void> syncPhoneModel({bool force = false}) {
    if (_disposed || !canSyncPhoneModel) return Future.value();
    if (_phoneSyncTask case final task?) {
      if (force) _phoneSyncQueued = true;
      return task;
    }
    final now = DateTime.now();
    if (!force && (_nextPhoneModelSync?.isAfter(now) ?? false)) {
      return Future.value();
    }
    _nextPhoneModelSync = now.add(const Duration(seconds: 5));
    return _phoneSyncTask = Future.microtask(() async {
      notifyListeners();
      try {
        do {
          _phoneSyncQueued = false;
          final connection = pairing();
          if (_disposed || connection == null) break;
          await _exchangePhoneModel(connection);
        } while (_phoneSyncQueued);
      } finally {
        _phoneSyncTask = null;
        notifyListeners();
      }
    });
  }

  Future<void> _exchangePhoneModel(Pairing connection) async {
    try {
      final owner = connection.url.toString();
      if (_phoneSyncId == null || owner != _phoneSyncOwner) {
        final firstPairing = _phoneSyncOwner == null;
        _phoneSyncId ??= RemoteClient.messageId();
        _phoneSyncOwner = owner;
        _phoneSyncRevision = null;
        _phoneCatalogRevision = null;
        _phoneSyncCompare = null;
        _phoneSyncConnected = false;
        phoneModelConflict = null;
        savedCloudModels = const [];
        if (firstPairing && modelSource == ModelSource.cloud) {
          _phoneSyncEdit ??= RemoteClient.messageId();
        }
        _saveSettings();
      }
      final edit = _phoneSyncEdit;
      final revision = _phoneSyncRevision;
      final direct = modelSource == ModelSource.desktop ? null : phoneModel;
      if (!_phoneSyncConnected &&
          direct?.source == ModelSource.cloud &&
          _phoneSyncCompare == null) {
        _phoneSyncCompare = RemoteClient.messageId();
        _saveSettings();
      }
      final compare = _phoneSyncCompare;
      final response = await remote.syncPhoneModel(connection, {
        'device': _phoneSyncId!,
        'source': modelSource.name,
        'model': modelSource == ModelSource.cloud ? direct?.model ?? '' : '',
        'seen': ?revision,
        'cloudCatalog': _phoneCatalogRevision ?? '',
        'edit': ?edit,
        if (_phoneSyncAdd) 'add': '1',
        'compare': ?compare,
        'conflictSupport': '1',
        if ((edit != null || compare != null) &&
            direct?.source == ModelSource.cloud) ...{
          'url': direct!.endpoint.toString(),
          'key': direct.key,
        },
      });
      if (_disposed || pairing()?.encode() != connection.encode()) return;
      if (_phoneSyncEdit != edit) {
        _phoneSyncQueued = true;
        return;
      }
      if (response.compareRequired) {
        _phoneSyncConnected = false;
        _nextPhoneModelSync = null;
        if (compare == null && direct?.source == ModelSource.cloud) {
          _phoneSyncQueued = true;
        }
        return;
      }
      final wasConnected = _phoneSyncConnected;
      _phoneSyncConnected = true;
      phoneModelSyncError = null;
      final catalogChanged = response.catalogRevision != _phoneCatalogRevision;
      _phoneCatalogRevision = response.catalogRevision;
      var optionsChanged = false;
      if (response.options case final options?) {
        optionsChanged = jsonEncode(savedCloudModels) != jsonEncode(options);
        savedCloudModels = options;
      }
      if (response.conflict case final conflict?) {
        if (phoneModelConflict != conflict) {
          phoneModelConflict = conflict;
          notifyListeners();
        }
        if (catalogChanged || response.options != null) _saveSettings();
        return;
      }
      final resolvedConflict = phoneModelConflict != null;
      phoneModelConflict = null;
      _phoneSyncEdit = null;
      _phoneSyncAdd = false;
      _phoneSyncCompare = null;
      _phoneSyncRevision = response.revision;
      if (response.selection case final source?) {
        final profile = response.profile;
        final changed =
            source != modelSource ||
            (profile != null &&
                (phoneModel?.sameCloud(profile) != true ||
                    !listEquals(phoneModel?.modelIds, profile.modelIds)));
        if (changed) {
          _reportPhoneModelUpdate(
            profile == null ? '已切换到电脑默认模型' : '已从电脑同步模型 · ${profile.model}',
          );
        } else if (optionsChanged && edit == null) {
          _reportPhoneModelUpdate('已从电脑同步云端模型列表');
        }
        _nextPhoneModelSync = null;
        if (source == ModelSource.desktop &&
            phoneModel?.source == ModelSource.cloud) {
          phoneModel = null;
        }
        final withCatalog = profile == null
            ? null
            : cloudProfiles
                  .where(
                    (item) =>
                        item.modelIds.isNotEmpty && profile.sameCloud(item),
                  )
                  .firstOrNull;
        _applyModel(
          source,
          profile != null && profile.modelIds.isNotEmpty
              ? profile
              : withCatalog ?? profile,
        );
        if (changed && source == ModelSource.desktop) unawaited(fetchModels());
      } else if (edit != null ||
          compare != null ||
          catalogChanged ||
          resolvedConflict ||
          response.options != null ||
          revision != response.revision) {
        if (optionsChanged && edit == null) {
          _reportPhoneModelUpdate('已从电脑同步云端模型列表');
        }
        _saveSettings();
      } else if (!wasConnected) {
        notifyListeners();
      }
    } catch (error) {
      if (!_disposed && pairing()?.encode() == connection.encode()) {
        _phoneSyncConnected = false;
        phoneModelSyncError = switch (error) {
          RemoteFailure(status: 404) => '桌面端未提供模型同步，请更新并重启桌面端。',
          RemoteFailure(status: 400) => '电脑拒绝了模型配置，请检查配置后重试。',
          RemoteFailure(status: 500) => '电脑无法保存模型配置，请检查桌面端。',
          _ => RemoteClient.describe(error),
        };
        notifyListeners();
      }
    }
  }

  void _reportPhoneModelUpdate(String message) {
    phoneModelUpdate = (id: (phoneModelUpdate?.id ?? 0) + 1, message: message);
  }

  void resetConnection() {
    _nextPhoneModelSync = null;
    _phoneSyncConnected = false;
    phoneModelSyncError = null;
    phoneModelConflict = null;
    ++_catalog;
    unawaited(cancelAnswer());
    models = const [];
    loading = false;
    modelError = null;
    _history.clear();
    _historyTarget = null;
    notifyListeners();
    unawaited(syncPhoneModel(force: true));
  }

  Future<void> _checkOfflineVoice() async {
    try {
      await _offlineVoice.check();
      if (offlineVoiceInstalled) notifyListeners();
    } catch (_) {
      // System speech remains available when storage is unavailable.
    }
  }

  Future<void> installOfflineVoice() async {
    if (!supportsOfflineVoice ||
        _installingVoice ||
        removingVoice ||
        offlineVoiceInstalled) {
      return;
    }
    _installingVoice = true;
    voiceInstallError = null;
    voiceDownloadProgress = 0;
    notifyListeners();
    try {
      await _offlineVoice.install((progress) {
        final previous = voiceDownloadProgress;
        if (_disposed ||
            (progress != null &&
                previous != null &&
                progress < 1 &&
                progress - previous < 0.01)) {
          return;
        }
        voiceDownloadProgress = progress;
        notifyListeners();
      });
    } catch (error, stackTrace) {
      debugPrint('离线语音安装失败：$error\n$stackTrace');
      voiceInstallError = switch (error) {
        FormatException() => '安装失败：${error.message}。请重新下载。',
        TimeoutException() => '模型下载超时，请检查网络后重试。',
        _ => '安装失败，请检查网络和可用存储空间后重试。',
      };
    } finally {
      _installingVoice = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> removeOfflineVoice() async {
    if (!offlineVoiceInstalled || _installingVoice || removingVoice) return;
    _removingVoice = true;
    voiceInstallError = null;
    notifyListeners();
    try {
      await _stopSpeech();
      await _offlineVoice.remove();
    } catch (_) {
      voiceInstallError = '删除失败，请重试。';
    } finally {
      _removingVoice = false;
      if (!_disposed) notifyListeners();
    }
  }

  void previewVoice() {
    if (!canPreviewVoice) return;
    _enqueueSpeech('你听，雨停了。');
    _enqueueSpeech('要不要出去走走？');
    _enqueueSpeech('走吧，刚好吹吹风！');
  }

  void setReadAnswers(bool value) {
    if (readAnswers == value) return;
    readAnswers = value;
    if (!value) {
      _muteReply = true;
      _utterances.removeWhere((item) => !item.notice);
      if (spokenReply != null) {
        unawaited(_stopSpeech().then((_) => _queueNotice()));
      }
    }
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
    final choices = <String, NoticeChoice>{};
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
    draftMedia = null;
    _activeMedia = null;
    _activeMediaPrompt = null;
    replyModel = error = null;
    notifyListeners();
  }

  Future<void> startRecording({bool sendAfter = false}) async {
    if (!_speechEnabled ||
        _listeningStarting ||
        _cancellingRecording ||
        listening) {
      return;
    }
    _listeningStarting = true;
    _retryInput = null;
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
      if (!_disposed && listening) {
        _minimumRecording = Timer(const Duration(milliseconds: 600), () {
          if (_earlyTranscript.isEmpty) return;
          draft = _earlyTranscript;
          _earlyTranscript = '';
          speechActivity++;
          notifyListeners();
        });
        notifyListeners();
      }
    } on PlatformException catch (failure) {
      _finishListening(failure.message ?? '无法开始录音，请检查麦克风和语音识别权限。');
    } on MissingPluginException {
      _finishListening('当前设备无法使用语音识别。');
    } finally {
      _listeningStarting = false;
    }
  }

  Future<void> stopRecording({bool sendAfter = false}) async {
    if (!listening) return;
    if (_recordingTooShort) {
      await cancelRecording();
      return;
    }
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
    _cancellingRecording = true;
    _sendAfterRecording = false;
    draft = '';
    _finishListening(null);
    try {
      await _invoke<void>('cancelListening');
    } finally {
      _cancellingRecording = false;
    }
  }

  void _finishListening(String? message) {
    if (!listening) return;
    _recordingDeadline?.cancel();
    _recordingDeadline = null;
    inputLevel = 0;
    final longEnough = !_recordingTooShort;
    _minimumRecording?.cancel();
    _minimumRecording = null;
    _earlyTranscript = '';
    final heard = longEnough && draft.trim().isNotEmpty;
    final submit = _sendAfterRecording && heard;
    final missingTranscript = _sendAfterRecording && longEnough && !heard;
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
    final attachment = draftMedia;
    if (attachment != null && !localMediaTypes.contains(attachment.type)) {
      error = '当前模型不支持此类附件。';
      notifyListeners();
      return;
    }
    final prompt = (text ?? draft).trim();
    final input = prompt.isNotEmpty
        ? prompt
        : switch (attachment?.type) {
            GgufMediaType.image => '请描述这张图片。',
            GgufMediaType.audio => '请理解这段语音并回应。',
            null => '',
          };
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
      _retryInput = input;
      notifyListeners();
      return;
    }
    final target = direct != null
        ? '${direct.endpoint}\n${direct.model}\n${direct.key}\n'
              '${direct.projectorPath}\n${direct.mediaTypes.map((type) => type.name).join(',')}'
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
    draftMedia = null;
    _activeMedia = attachment;
    _activeMediaPrompt = attachment == null ? null : input;
    question = attachment == null
        ? input
        : '$input\n${attachment.type.label} · ${attachment.name}';
    reply = '';
    reasoning = '';
    replyModel = direct?.model ?? chosen!.name;
    error = null;
    _retryInput = null;
    _spokenThrough = 0;
    _muteReply = false;
    phase = InteractionPhase.thinking;
    notifyListeners();
    await _stopSpeech();
    if (generation != _request || _disposed) return;
    if (conversation != null) {
      _activeRequest = (pairing: conversation, id: requestId);
    }
    final userMessage = {'role': 'user', 'content': input};
    final messages = [for (final item in _history) item.message, userMessage];
    final media = <int, GgufMedia>{
      for (final (index, item) in _history.indexed) index: ?item.media,
      _history.length: ?attachment,
    };
    final response = direct == null
        ? remote.chat(conversation!, chosen!, messages, requestId)
        : media.isEmpty
        ? remote.directChat(direct, messages)
        : remote.localMediaChat(direct, messages, media);
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
          _retryInput = input;
          _restoreAnswerDraft();
        } else {
          _replyCompleted = true;
          _history.addAll([
            (message: userMessage, media: attachment),
            (
              message: {
                'role': 'assistant',
                'content': reply.length > 4000
                    ? reply.substring(0, 4000)
                    : reply,
              },
              media: null,
            ),
          ]);
          _activeMedia = null;
          _activeMediaPrompt = null;
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
        _retryInput = input;
        _restoreAnswerDraft();
        unawaited(_stopSpeech());
        notifyListeners();
      },
      cancelOnError: true,
    );
  }

  void _restoreAnswerDraft() {
    if (draft.isEmpty) draft = _activeMediaPrompt ?? question;
    draftMedia ??= _activeMedia;
    _activeMedia = null;
    _activeMediaPrompt = null;
  }

  Future<void> cancelAnswer({bool discardReasoning = false}) async {
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
      if (discardReasoning) reasoning = '';
      _restoreAnswerDraft();
      if (discardReasoning) notifyListeners();
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
    _speakingNotice = false;
    spokenText = null;
    _speakingTimer?.cancel();
    if (wasSpeaking && !_stopSpeechPending) {
      _stopSpeechPending = true;
      await Future.wait([_invoke<void>('stopSpeaking'), _releaseVoicePlayer()]);
      _stopSpeechPending = false;
    }
    if (_disposed) return;
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
    _speakingNotice = utterance.notice;
    _speechId = (++_nextSpeechId).toString();
    spokenText = utterance.text;
    _speakingTimer = Timer(const Duration(seconds: 40), _speechDone);
    unawaited(_speak(utterance.text, _speechId!));
    notifyListeners();
  }

  Future<void> _speak(String text, String id) async {
    if (!removingVoice && offlineVoiceInstalled && _speechText.hasMatch(text)) {
      try {
        final wav = await _offlineVoice.synthesize(text);
        if (_disposed || _speechId != id) return;
        Source source = BytesSource(wav, mimeType: 'audio/wav');
        if (defaultTargetPlatform == TargetPlatform.iOS) {
          final staged = await _offlineVoice.stageAudio(wav);
          if (_disposed || _speechId != id) {
            await staged.delete();
            return;
          }
          _deleteVoiceFile = staged.delete;
          source = DeviceFileSource(staged.path, mimeType: 'audio/wav');
        }
        final player = _voicePlayer = AudioPlayer();
        _voiceCompletion = player.onPlayerComplete.listen((_) {
          if (!_disposed && _speechId == id) _speechDone();
        });
        await player.play(
          source,
          ctx: AudioContext(
            android: const AudioContextAndroid(
              contentType: AndroidContentType.speech,
            ),
            iOS: AudioContextIOS(
              category: AVAudioSessionCategory.playback,
              options: {AVAudioSessionOptions.duckOthers},
            ),
          ),
        );
        if (!_disposed && _speechId == id) {
          final byteRate = ByteData.sublistView(wav)
              .getUint32(28, Endian.little);
          final seconds = (wav.length - 44) ~/ byteRate;
          _speakingTimer?.cancel();
          _speakingTimer = Timer(Duration(seconds: seconds + 10), _speechDone);
        }
        return;
      } catch (_) {
        if (_disposed || _speechId != id) return;
        await _releaseVoicePlayer();
      }
    }
    if (_disposed || _speechId != id) return;
    try {
      await bridge.invokeMethod<void>('speak', {'text': text, 'id': id});
    } on PlatformException {
      if (!_disposed && _speechId == id) _speechDone();
    } on MissingPluginException {
      if (!_disposed && _speechId == id) _speechDone();
    }
  }

  Future<void> _releaseVoicePlayer() async {
    final player = _voicePlayer;
    final completion = _voiceCompletion;
    final delete = _deleteVoiceFile;
    _voicePlayer = null;
    _voiceCompletion = null;
    _deleteVoiceFile = null;
    try {
      await completion?.cancel();
      await player?.dispose();
    } catch (_) {
      // Playback may have been interrupted while the player was opening.
    }
    try {
      await delete?.call();
    } catch (_) {
      // The OS may already have cleared the temporary file.
    }
  }

  void _speechDone() {
    if (!_speechPending) return;
    unawaited(_releaseVoicePlayer());
    _speakingTimer?.cancel();
    _speechPending = false;
    _speechId = null;
    _speakingNotice = false;
    spokenText = null;
    _queueNotice();
    _playNext();
    notifyListeners();
  }

  void _queueNotice() {
    if (!_foreground ||
        !readNotices ||
        listening ||
        generating ||
        spokenText != null ||
        _utterances.isNotEmpty) {
      return;
    }
    final pending = _pendingNotice;
    if (pending == null) return;
    final text = pending.text;
    if (text == null) {
      if (!_readingNoticeCode) unawaited(_readPendingCode(pending.notice));
      return;
    }
    _pendingNotice = null;
    _enqueueSpeech(text, notice: true);
  }

  Future<void> _readPendingCode(PhoneNotice notice) async {
    _readingNoticeCode = true;
    final pending = _pendingNotice;
    final code = await noticeCode(notice);
    _readingNoticeCode = false;
    if (_disposed) return;
    if (identical(_pendingNotice, pending) && pending != null) {
      _pendingNotice = (
        notice: notice,
        text: code == null
            ? '收到一条验证消息。'
            : '收到验证码为，${code.split('').join(' ')}。',
      );
    }
    _queueNotice();
  }

  void clearNotice() {
    notice = null;
    _noticeTimer?.cancel();
    _noticeReactionTimer?.cancel();
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
          if (_recordingTooShort) {
            if (!finishingRecording) _earlyTranscript = text;
          } else {
            if (text != draft) speechActivity++;
            draft = text;
          }
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
      case 'speechDetected':
        if (!listening || finishingRecording) return;
        speechActivity++;
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
      // Android evaluates the rules before removing verification message content.
      if (event['matchesNoticeRules'] == false) return;
      final hasRules =
          _allowedSources.isNotEmpty ||
          _keywords.isNotEmpty ||
          _contacts.isNotEmpty;
      if (event['matchesNoticeRules'] != true &&
          hasRules &&
          !_allowedSources.contains(key)) {
        final content = [
          sender,
          title,
          text,
        ].whereType<String>().join(' ').toLowerCase();
        final matchesKeyword = _keywords.any(
          (term) => content.contains(term.toLowerCase()),
        );
        final matchesContact =
            sender is String &&
            _contacts.values.any((entry) => entry.matchesSender(sender));
        if (!matchesKeyword && !matchesContact) return;
      }
    }
    final id = event['id'];
    final eventKey = id is String ? '$id:${event['timestamp'] ?? ''}' : null;
    if (eventKey != null) {
      if (!_seenEvents.add(eventKey)) return;
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
      id: id is String ? id : null,
      eventKey: eventKey,
      packageName: package is String ? package : null,
    );
    if (_recentNotices.firstOrNull == received) return;
    _recentNotices.insert(0, received);
    if (_recentNotices.length > 20) _recentNotices.removeLast();
    _saveRecentNotices();
    final initial = event['initial'] == true;
    final isSms = event['sms'] == true;
    final speech = verification
        ? ''
        : _noticeSpeech(
            received,
            sender: sender is String ? sender : '',
            isSms: isSms,
          );
    if (!_foreground) {
      _unshownNotice = (notice: received, initial: initial, speech: speech);
      return;
    }
    _showNotice(received, initial: initial, speech: speech);
  }

  String _noticeSpeech(
    PhoneNotice notice, {
    required String sender,
    required bool isSms,
  }) {
    final who = sender.trim();
    final content = notice.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final points = content.runes;
    final limit = isSms ? 50 : 120;
    final excerpt = points.length > limit
        ? '${String.fromCharCodes(points.take(limit)).trimRight()}，后面还有内容。'
        : content;
    if (isSms) {
      final from = who.isEmpty ? notice.title.trim() : who;
      final prefix = from.isEmpty || from == '新提醒' ? '收到一条短信' : '收到来自$from的短信';
      return excerpt.isEmpty ? '$prefix。' : '$prefix，内容是：$excerpt';
    }
    if (who.isEmpty || who == notice.source) {
      final prefix = '你在${notice.source}收到一条消息';
      return excerpt.isEmpty ? '$prefix。' : '$prefix，内容是：$excerpt';
    }
    final prefix = '$who在${notice.source}';
    return excerpt.isEmpty ? '$prefix给你发消息了。' : '$prefix对你说：$excerpt';
  }

  void _showNotice(
    PhoneNotice received, {
    required bool initial,
    required String speech,
  }) {
    notice = received;
    _expression = null;
    _noticeTimer?.cancel();
    _noticeTimer = Timer(const Duration(seconds: 9), clearNotice);
    _noticeReactionTimer?.cancel();
    if (!initial && phase == InteractionPhase.idle) {
      _noticeReactionTimer = Timer(
        const Duration(milliseconds: 1050),
        notifyListeners,
      );
    }
    if (readNotices && !initial) {
      _pendingNotice = (
        notice: received,
        text: received.verification ? null : speech,
      );
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
    _minimumRecording?.cancel();
    final request = _activeRequest;
    if (request != null) {
      unawaited(remote.cancelChat(request.pairing, request.id));
    }
    if (_speechPending) unawaited(_invoke<void>('stopSpeaking'));
    if (listening) unawaited(_invoke<void>('cancelListening'));
    _disposed = true;
    unawaited(_releaseVoicePlayer());
    _offlineVoice.dispose();
    _noticeTimer?.cancel();
    _noticeReactionTimer?.cancel();
    _speakingTimer?.cancel();
    unawaited(_events?.cancel());
    unawaited(_answer?.cancel());
    super.dispose();
  }
}
