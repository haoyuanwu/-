import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:robot_eyes_models/robot_eyes_models.dart';

const channel = MethodChannel('com.reareyes/mobile');
bool get isAndroid => Platform.isAndroid;

Future<Map<String, String>?>? _phoneIdentity;

Future<Map<String, String>?> _loadPhoneIdentity() async {
  try {
    return await channel.invokeMapMethod<String, String>('phoneIdentity');
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}

Future<String?> loadPairing() => channel.invokeMethod<String>('loadPairing');
Future<void> savePairing(String? value) =>
    channel.invokeMethod<void>('savePairing', value);
Future<int?> sleepSetting([int? seconds]) =>
    channel.invokeMethod<int>('sleep', seconds);
Future<void> keepScreenOn(bool enabled) async {
  if (Platform.isIOS || Platform.isAndroid) {
    await channel.invokeMethod<void>('keepScreenOn', enabled);
  }
}

Future<({int status, String body})> request(
  Uri url,
  String token,
  Map<String, String>? data, {
  int maxBytes = 16384,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
  const timeout = Duration(seconds: 4);
  try {
    final request =
        await (data == null ? client.getUrl(url) : client.postUrl(url)).timeout(
          timeout,
        );
    request.followRedirects = false;
    if (token.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (Platform.isIOS &&
        url.scheme == 'https' &&
        url.host.endsWith('.ts.net') &&
        url.path == '/status') {
      final phone = await (_phoneIdentity ??= _loadPhoneIdentity());
      if (phone?['id'] case final id?) {
        request.headers.set('X-Robot-Eyes-Phone-Id', id);
        request.headers.set(
          'X-Robot-Eyes-Phone-Name',
          Uri.encodeComponent(phone?['name'] ?? 'iPhone'),
        );
      }
    }
    if (data != null) {
      final body = utf8.encode(jsonEncode(data));
      request.headers.contentType = ContentType.json;
      request.contentLength = body.length;
      request.add(body);
    }
    final response = await request.close().timeout(timeout);
    if (response.statusCode != 200 && response.statusCode != 201) {
      return (status: response.statusCode, body: '');
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(timeout)) {
      if (bytes.length + chunk.length > maxBytes) {
        throw const FormatException('电脑返回的数据过大');
      }
      bytes.addAll(chunk);
    }
    return (status: response.statusCode, body: utf8.decode(bytes));
  } finally {
    client.close(force: true);
  }
}

Stream<String> modelChat(Uri url, String token, Map<String, Object> data) {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  late final StreamController<String> controller;
  StreamSubscription<String>? responseLines;
  var cancelled = false;

  void fail(Object error, StackTrace stack) {
    if (cancelled) return;
    controller.addError(
      error is TimeoutException
          ? const FormatException('等待模型数据超时，请检查网络或模型服务。')
          : error,
      stack,
    );
    unawaited(controller.close());
  }

  Future<void> pump() async {
    try {
      final request = await client
          .postUrl(url)
          .timeout(const Duration(seconds: 8));
      if (cancelled) return;
      request.followRedirects = false;
      if (token.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      request.headers.contentType = ContentType.json;
      final body = utf8.encode(jsonEncode(data));
      request.contentLength = body.length;
      request.add(body);
      final response = await request.close().timeout(
        modelRelayTimeout,
      );
      if (cancelled) return;
      if (response.statusCode != HttpStatus.ok) {
        controller.addError(
          FormatException('模型请求失败（HTTP ${response.statusCode}）'),
        );
        unawaited(controller.close());
        return;
      }
      responseLines = response
          .timeout(modelRelayTimeout)
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            controller.add,
            onError: fail,
            onDone: () => unawaited(controller.close()),
            cancelOnError: true,
          );
    } catch (error, stack) {
      fail(error, stack);
    }
  }

  controller = StreamController<String>(
    onListen: () => unawaited(pump()),
    onPause: () => responseLines?.pause(),
    onResume: () => responseLines?.resume(),
    onCancel: () async {
      cancelled = true;
      client.close(force: true);
      await responseLines?.cancel();
    },
  );
  return controller.stream;
}

Future<void> cancelModelChat(Uri url, String token) async {
  const timeout = Duration(seconds: 3);
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client.deleteUrl(url).timeout(timeout);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    final response = await request.close().timeout(timeout);
    await response.drain<void>().timeout(timeout);
  } on IOException {
    // Closing the streaming client also drops the downstream connection.
  } on TimeoutException {
    // The streaming client has already been closed.
  } finally {
    client.close(force: true);
  }
}
