import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rear_eyes_desktop/phone_links.dart';

void main() {
  const first = '11111111-1111-4111-8111-111111111111';
  const second = '22222222-2222-4222-8222-222222222222';
  late Directory directory;

  PhoneLinks open() => PhoneLinks(directory, () async => null, () {})..load();

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('phone-links-');
    addTearDown(() => directory.delete(recursive: true));
  });

  test('adding a LAN phone preserves the old pairing and scopes its key', () {
    File('${directory.path}/phone-lan.json').writeAsStringSync(
      jsonEncode({
        'mcpServers': {
          'robot-eyes': {
            'url': 'http://192.168.1.10:8789/mcp',
            'headers': {'Authorization': 'Bearer $first'},
          },
        },
      }),
    );
    final links = open();
    expect(links.lanDevices.single.detail, '192.168.1.10');
    expect(
      links.registerLanPhone(
        '192.168.1.11',
        second,
        name: '第二台手机',
        phoneKey: base64UrlEncode(List.filled(32, 1)).replaceAll('=', ''),
        trustedKey: true,
      ),
      isTrue,
    );
    links.recordLanPhone('Bearer $first');
    links.recordLanPhone('Bearer $second');
    expect(links.lanDevices.where((device) => device.connected), hasLength(2));
    expect(links.keyFor('Bearer $first'), isNull);
    expect(links.keyFor('Bearer $second'), isNotNull);
    expect(
      links.isLanPhone('Bearer $first', InternetAddress('192.168.1.11')),
      isFalse,
    );

    final reopened = open();
    expect(reopened.lanDevices, hasLength(2));
    expect(reopened.lanDevices.every((device) => !device.connected), isTrue);
    reopened.lanDevices
        .singleWhere((device) => device.name == '第二台手机')
        .forget!();
    expect(open().lanDevices.single.detail, '192.168.1.10');
  });

  test('Tailscale tracks simultaneous phones and restores them as offline', () {
    final links = open();
    links.recordTailscalePhone(first, '同型号手机');
    links.recordTailscalePhone(second, '同型号手机');
    links.recordTailscalePhone(first, '同型号手机');
    expect(
      links.tailscaleDevices.where((device) => device.connected),
      hasLength(2),
    );
    expect(
      links.tailscaleDevices.map((device) => device.detail).toSet(),
      hasLength(2),
    );

    links.stop();
    expect(links.tailscaleDevices.every((device) => !device.connected), isTrue);
    final reopened = open();
    expect(reopened.tailscaleDevices, hasLength(2));
    reopened.recordTailscalePhone(second, null);
    expect(
      reopened.tailscaleDevices.where((device) => device.connected),
      hasLength(1),
    );
  });
}
