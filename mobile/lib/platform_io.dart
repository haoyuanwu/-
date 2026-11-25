import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

const channel = MethodChannel('com.reareyes/mobile');
bool get isAndroid => Platform.isAndroid;

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
  Map<String, String>? data,
) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
  const timeout = Duration(seconds: 4);
  try {
    final request =
        await (data == null ? client.getUrl(url) : client.postUrl(url)).timeout(
          timeout,
        );
    request.followRedirects = false;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
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
      if (bytes.length + chunk.length > 8192) {
        throw const FormatException('电脑返回的数据过大');
      }
      bytes.addAll(chunk);
    }
    return (status: response.statusCode, body: utf8.decode(bytes));
  } finally {
    client.close(force: true);
  }
}
