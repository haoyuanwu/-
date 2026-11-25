import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

bool get isAndroid => false;

@JS('localStorage')
external _Storage get _storage;

extension type _Storage._(JSObject _) implements JSObject {
  external String? getItem(String key);
  external void setItem(String key, String value);
  external void removeItem(String key);
}

@JS('fetch')
external JSPromise<_Response> _fetch(String url, _RequestOptions options);

extension type _RequestOptions._(JSObject _) implements JSObject {
  external factory _RequestOptions({
    String method,
    JSObject headers,
    String? body,
    String redirect,
    String credentials,
    String cache,
    String mode,
    JSObject signal,
  });
}

extension type _Response._(JSObject _) implements JSObject {
  external int get status;
  external JSPromise<JSString> text();
}

@JS('AbortController')
extension type _AbortController._(JSObject _) implements JSObject {
  external factory _AbortController();
  external JSObject get signal;
  external void abort();
}

const _pairingKey = 'rearEyes.pairing';
const _sleepKey = 'rearEyes.sleepSeconds';

Future<String?> loadPairing() async => _storage.getItem(_pairingKey);

Future<void> savePairing(String? value) async {
  if (value == null) {
    _storage.removeItem(_pairingKey);
  } else {
    _storage.setItem(_pairingKey, value);
  }
}

Future<int?> sleepSetting([int? seconds]) async {
  if (seconds != null) _storage.setItem(_sleepKey, seconds.toString());
  return int.tryParse(_storage.getItem(_sleepKey) ?? '') ?? 90;
}

@JS('navigator.wakeLock')
external _WakeLock? get _wakeLock;

@JS('document')
external _Document get _document;

extension type _Document._(JSObject _) implements JSObject {
  external String get visibilityState;
  external void addEventListener(String type, JSFunction listener);
  external void removeEventListener(String type, JSFunction listener);
}

extension type _WakeLock._(JSObject _) implements JSObject {
  external JSPromise<_WakeLockSentinel> request(String kind);
}

extension type _WakeLockSentinel._(JSObject _) implements JSObject {
  external bool get released;
  external JSPromise<JSAny?> release();
}

_WakeLockSentinel? _screenLock;
bool _screenWanted = false;
bool _screenPending = false;
final _visibilityListener = (() => unawaited(_acquireScreenLock())).toJS;

Future<void> _acquireScreenLock() async {
  final wakeLock = _wakeLock;
  if (!_screenWanted ||
      _screenPending ||
      wakeLock == null ||
      _document.visibilityState != 'visible' ||
      _screenLock?.released == false) {
    return;
  }
  _screenPending = true;
  try {
    final lock = await wakeLock.request('screen').toDart;
    if (_screenWanted) {
      _screenLock = lock;
    } else {
      await lock.release().toDart;
    }
  } catch (_) {
    // Browsers may deny a wake lock in low power mode or when the tab is hidden.
  } finally {
    _screenPending = false;
  }
}

Future<void> keepScreenOn(bool enabled) async {
  if (_screenWanted == enabled) return;
  _screenWanted = enabled;
  if (enabled) {
    _document.addEventListener('visibilitychange', _visibilityListener);
    unawaited(_acquireScreenLock());
    return;
  }
  _document.removeEventListener('visibilitychange', _visibilityListener);
  final lock = _screenLock;
  _screenLock = null;
  if (lock != null && !lock.released) {
    try {
      await lock.release().toDart;
    } catch (_) {
      // The browser can release the same sentinel as the app exits full screen.
    }
  }
}

Future<({int status, String body})> request(
  Uri url,
  String token,
  Map<String, String>? data,
) async {
  if (url.origin != Uri.base.origin) {
    throw const FormatException('请在这台电脑的 Tailscale 地址打开 Web App，再使用它的配对配置。');
  }
  final controller = _AbortController();
  final timeout = Timer(const Duration(seconds: 8), () => controller.abort());
  try {
    final headers =
        {
              'Authorization': 'Bearer $token',
              if (data != null) 'Content-Type': 'application/json',
            }.jsify()
            as JSObject;
    final result = await _fetch(
      url.toString(),
      _RequestOptions(
        method: data == null ? 'GET' : 'POST',
        headers: headers,
        body: data == null ? null : jsonEncode(data),
        redirect: 'error',
        credentials: 'omit',
        cache: 'no-store',
        mode: 'same-origin',
        signal: controller.signal,
      ),
    ).toDart;
    if (result.status != 200 && result.status != 201) {
      return (status: result.status, body: '');
    }
    final body = (await result.text().toDart).toDart;
    if (body.length > 8192) throw const FormatException('电脑返回的数据过大');
    return (status: result.status, body: body);
  } finally {
    timeout.cancel();
  }
}
