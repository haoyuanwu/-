import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:robot_eyes_models/lan_crypto.dart';

typedef _LanPhone = ({
  Uri url,
  String authorization,
  String? phoneKey,
  String? name,
});

typedef PhoneDevice = ({
  String name,
  String detail,
  bool connected,
  void Function()? forget,
});

String? readPhoneName(Object? value) {
  if (value is! String) return null;
  final name = value.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
  if (name.isEmpty) return null;
  return String.fromCharCodes(name.runes.take(80));
}

/// Sends snapshots over the phone's existing ADB and same-subnet MCP listeners.
class PhoneLinks {
  PhoneLinks(this.directory, this._readRemotePairing, this._onChanged);

  final Directory directory;
  final Future<String?> Function() _readRemotePairing;
  final void Function() _onChanged;
  final _lan = <String, _LanPhone>{};
  final _lanReachable = <String, bool>{};
  final _lanSeen = <String, DateTime>{};
  final _remote = <String, String>{};
  final _remoteSeen = <String, DateTime>{};
  String? _adb;
  ({String serial, int port, bool owned})? _forward;
  ({String serial, String id})? _usbTransport;
  bool _usbLanHandled = false;
  bool _usbRemoteHandled = false;
  bool _inFlight = false;
  Map<String, Object?>? _pendingSnapshot;
  int _generation = 0;
  String? _adbTransport;

  File get _lanFile => File('${directory.path}/phone-lan.json');
  File get _remoteFile => File('${directory.path}/phone-tailscale.json');
  String? get adbTransport => _adbTransport;
  bool lanModelService = false;

  List<PhoneDevice> get lanDevices {
    final now = DateTime.now();
    return [
      for (final phone in _lan.values)
        (
          name: phone.name ?? 'Android 手机',
          detail: phone.url.host,
          connected:
              _lanReachable[phone.authorization] == true ||
              _recentlySeen(_lanSeen[phone.authorization], now),
          forget: () => _forgetLanPhone(phone.authorization),
        ),
    ];
  }

  List<PhoneDevice> get tailscaleDevices {
    final now = DateTime.now();
    return [
      for (final entry in _remote.entries)
        (
          name: entry.value,
          detail: '设备 ${entry.key.substring(entry.key.length - 6)}',
          connected: _recentlySeen(_remoteSeen[entry.key], now),
          forget: null,
        ),
    ];
  }

  bool _recentlySeen(DateTime? seen, DateTime now) =>
      now.difference(seen ?? _never) < const Duration(seconds: 15);

  static final _never = DateTime.fromMillisecondsSinceEpoch(0);
  static final _id = RegExp(r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$');

  void recordTailscalePhone(String? id, String? name) {
    if (id == null || !_id.hasMatch(id)) return;
    final label = readPhoneName(name) ?? _remote[id] ?? '手机';
    final renamed = _remote[id] != label;
    final now = DateTime.now();
    final wasOnline = _recentlySeen(_remoteSeen[id], now);
    if (renamed) {
      final next = {..._remote, id: label};
      try {
        _save(_remoteFile, next);
      } on FileSystemException {
        // Keep serving status even if the device list cannot be persisted.
      }
      _remote[id] = label;
    }
    _remoteSeen[id] = now;
    if (renamed || !wasOnline) _onChanged();
  }

  bool isLanPhone(String? authorization, InternetAddress? address) =>
      address != null && _lan[authorization]?.url.host == address.address;

  bool hasPhoneToken(String authorization) => _lan.containsKey(authorization);
  String? keyFor(String? authorization) => _lan[authorization]?.phoneKey;

  void recordLanPhone(String authorization) {
    final now = DateTime.now();
    final wasOnline = _recentlySeen(_lanSeen[authorization], now);
    _lanSeen[authorization] = now;
    if (!wasOnline && _lanReachable[authorization] != true) _onChanged();
  }

  bool registerLanPhone(
    String address,
    String token, {
    bool trustedKey = false,
    String? phoneKey,
    String? name,
  }) {
    final ip = InternetAddress.tryParse(address);
    if (ip == null || !_privateAddress(ip) || !_id.hasMatch(token)) {
      return false;
    }
    final authorization = 'Bearer $token';
    final previous = _lan[authorization];
    _savePhone((
      url: Uri(scheme: 'http', host: address, port: 8789, path: '/status-sync'),
      authorization: authorization,
      phoneKey: trustedKey
          ? phoneKey ?? previous?.phoneKey
          : previous?.phoneKey,
      name: readPhoneName(name) ?? previous?.name,
    ));
    return true;
  }

  void stop() {
    _generation++;
    _pendingSnapshot = null;
    _lanReachable.clear();
    _lanSeen.clear();
    _remoteSeen.clear();
    _adbTransport = null;
  }

  void load() {
    _lan.clear();
    _remote.clear();
    if (_lanFile.existsSync()) {
      try {
        final data = jsonDecode(_lanFile.readAsStringSync());
        for (final entry in data is List ? data : [data]) {
          try {
            final phone = _parse(entry);
            _lan[phone.authorization] = phone;
          } on FormatException {
            // Keep the other paired phones if one record was damaged.
          }
        }
      } on FormatException {
        // An unreadable file should not block the service.
      }
    }
    if (_remoteFile.existsSync()) {
      try {
        final data = jsonDecode(_remoteFile.readAsStringSync());
        if (data is Map<String, dynamic>) {
          for (final entry in data.entries) {
            final name = readPhoneName(entry.value);
            if (_id.hasMatch(entry.key) && name != null) {
              _remote[entry.key] = name;
            }
          }
        }
      } on FormatException {
        // The phone will be listed again on its next status request.
      }
    }
  }

  void _savePhone(_LanPhone phone) {
    if (_lan[phone.authorization] == phone) return;
    _saveLan({..._lan, phone.authorization: phone});
    _lan[phone.authorization] = phone;
    _lanReachable.remove(phone.authorization);
    _lanSeen.remove(phone.authorization);
  }

  void _forgetLanPhone(String authorization) {
    if (!_lan.containsKey(authorization)) return;
    _saveLan({..._lan}..remove(authorization));
    _lan.remove(authorization);
    _lanReachable.remove(authorization);
    _lanSeen.remove(authorization);
    _usbLanHandled = true;
    _onChanged();
  }

  void _saveLan(Map<String, _LanPhone> phones) {
    _save(_lanFile, [
      for (final row in phones.values)
        {
          'mcpServers': {
            'robot-eyes': {
              'url': row.url.replace(path: '/mcp').toString(),
              'headers': {'Authorization': row.authorization},
            },
          },
          'phoneKey': ?row.phoneKey,
          'phoneName': ?row.name,
        },
    ]);
  }

  void _save(File file, Object data) {
    directory.createSync(recursive: true);
    final draft = File('${file.path}.tmp');
    if (!Platform.isWindows) {
      draft.createSync();
      Process.runSync('/bin/chmod', ['600', draft.path]);
    }
    draft.writeAsStringSync(jsonEncode(data), flush: true);
    draft.renameSync(file.path);
  }

  _LanPhone _parse(Object? data) {
    final servers = data is Map ? data['mcpServers'] : null;
    final phone = servers is Map
        ? servers['robot-eyes'] ?? servers['rear-eyes']
        : null;
    final url = phone is Map ? phone['url'] : null;
    final headers = phone is Map ? phone['headers'] : null;
    final authorization = headers is Map ? headers['Authorization'] : null;
    final phoneKey = data is Map ? data['phoneKey'] : null;
    final uri = url is String ? Uri.tryParse(url) : null;
    final address = uri == null ? null : InternetAddress.tryParse(uri.host);
    if (uri == null ||
        uri.scheme != 'http' ||
        uri.port != 8789 ||
        uri.path != '/mcp' ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty ||
        address == null ||
        !_privateAddress(address) ||
        !RegExp(r'^Bearer [a-f0-9-]{36}$')
            .hasMatch(authorization is String ? authorization : '')) {
      throw const FormatException('Invalid phone LAN configuration');
    }
    return (
      url: uri.replace(path: '/status-sync'),
      authorization: authorization as String,
      phoneKey: LanCrypto.validKey(phoneKey) ? phoneKey as String : null,
      name: readPhoneName(data is Map ? data['phoneName'] : null),
    );
  }

  bool _privateAddress(InternetAddress address) {
    if (address.type != InternetAddressType.IPv4) return false;
    final bytes = address.rawAddress;
    return bytes[0] == 10 ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
        (bytes[0] == 192 && bytes[1] == 168) ||
        (bytes[0] == 169 && bytes[1] == 254);
  }

  Future<void> push(Map<String, Object?> snapshot) async {
    _pendingSnapshot = snapshot;
    if (_inFlight) return;
    _inFlight = true;
    try {
      while (true) {
        final next = _pendingSnapshot;
        if (next == null) break;
        _pendingSnapshot = null;
        final generation = _generation;
        await _sendAdb(next, _sendLan(next, generation), generation);
      }
    } finally {
      _inFlight = false;
    }
  }

  Future<void> _sendLan(Map<String, Object?> snapshot, int generation) async {
    await Future.wait([
      for (final phone in _lan.values.toList())
        _sendLanPhone(phone, snapshot, generation),
    ]);
  }

  Future<void> _sendLanPhone(
    _LanPhone phone,
    Map<String, Object?> snapshot,
    int generation,
  ) async {
    final reachable = await _postSnapshot({
      ...snapshot,
      if (lanModelService) 'modelApi': 1,
      if (phone.phoneKey != null) 'configSync': true,
    }, phone);
    final id = phone.authorization;
    if (generation != _generation || _lan[id] != phone) return;
    if (_lanReachable[id] != reachable) {
      _lanReachable[id] = reachable;
      _onChanged();
    }
  }

  Future<bool> _postSnapshot(
    Map<String, Object?> snapshot,
    _LanPhone lan,
  ) async {
    final client = _client();
    try {
      final request = await client.postUrl(lan.url).timeout(_timeout);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.authorizationHeader, lan.authorization);
      request.headers.contentType = ContentType.json;
      final body = utf8.encode(jsonEncode(snapshot));
      request.contentLength = body.length;
      request.add(body);
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != HttpStatus.ok) return false;
      final bytes = <int>[];
      await for (final chunk in response.timeout(_timeout)) {
        if (bytes.length + chunk.length > 1024) return false;
        bytes.addAll(chunk);
      }
      final result = jsonDecode(utf8.decode(bytes));
      return result is Map && result['ok'] == true && result['active'] != false;
    } on IOException {
      return false;
    } on TimeoutException {
      return false;
    } on FormatException {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _sendAdb(
    Map<String, Object?> snapshot,
    Future<void> lanConnected,
    int generation,
  ) async {
    String? transport;
    try {
      final devices = await _devices();
      final usb = _usbTransport;
      if (usb != null && devices[usb.serial]?.id != usb.id) {
        _usbTransport = null;
      }
      final serial = await _selectDevice(devices);
      final device = devices[serial];
      if (serial == null || device == null || generation != _generation) return;
      if (device.kind == 'USB') {
        final usbTransport = (serial: serial, id: device.id);
        if (_usbTransport != usbTransport) {
          _usbTransport = usbTransport;
          _usbLanHandled = false;
          _usbRemoteHandled = false;
          await _removeForward();
        }
        await Future.wait([
          _syncAdb(serial, device.kind, snapshot).then((synced) {
            if (synced) transport = device.kind;
            _updateAdbTransport(transport, generation);
          }),
          _repairUsbLan(serial, snapshot, generation),
          _repairUsbTailscale(serial),
        ]);
      } else {
        if (await _syncAdb(serial, device.kind, snapshot)) {
          transport = device.kind;
        }
      }
    } on IOException {
      await _removeForward();
    } on TimeoutException {
      await _removeForward();
    } finally {
      _updateAdbTransport(transport, generation);
      await lanConnected;
    }
  }

  void _updateAdbTransport(String? transport, int generation) {
    if (generation != _generation || _adbTransport == transport) return;
    _adbTransport = transport;
    _onChanged();
  }

  Future<String?> _selectDevice(
    Map<String, ({String kind, String id})> devices,
  ) async {
    if (devices.isEmpty) return null;
    final configured = Platform.environment['ANDROID_SERIAL'];
    if (configured != null || devices.length == 1) {
      return configured ?? devices.keys.first;
    }
    final identifiers = <String>{};
    for (final candidate in devices.keys) {
      final result = await _adbRun([
        '-s',
        candidate,
        'shell',
        'getprop',
        'ro.serialno',
      ]);
      if (result.exitCode != 0) return null;
      identifiers.add((result.stdout as String).trim());
    }
    if (identifiers.length != 1 || identifiers.contains('')) return null;
    return devices.keys.firstWhere(
      (key) => devices[key]?.kind == 'USB',
      orElse: () => devices.keys.first,
    );
  }

  Future<void> _repairUsbLan(
    String serial,
    Map<String, Object?> snapshot,
    int generation,
  ) async {
    if (_usbLanHandled || generation != _generation) return;
    final phone = await _importUsbLan(serial, generation);
    if (phone != null) await _sendLanPhone(phone, snapshot, generation);
  }

  Future<void> _repairUsbTailscale(String serial) async {
    if (_usbRemoteHandled) return;
    _usbRemoteHandled = true;
    await _pairOverUsb(serial);
  }

  Future<bool> _syncAdb(
    String serial,
    String kind,
    Map<String, Object?> snapshot,
  ) async {
    final client = _client();
    try {
      if (_forward?.serial != serial) {
        await _removeForward();
        final reused = await _forwardedPort(serial);
        if (reused != null) {
          _forward = (serial: serial, port: reused, owned: false);
        } else {
          final result = await _adbRun([
            '-s',
            serial,
            'forward',
            'tcp:0',
            'tcp:8788',
          ]);
          final port = int.tryParse((result.stdout as String).trim());
          if (result.exitCode != 0 || port == null) return false;
          _forward = (serial: serial, port: port, owned: true);
        }
      }
      final uri = Uri.parse('http://127.0.0.1:${_forward!.port}/codex-sync');
      final reply = (await _get(client, uri)).trim();
      if (!reply.startsWith('sync ')) return false;
      final result = await _get(
        client,
        uri.replace(
          queryParameters: {
            'ticket': reply.substring(5),
            'transport': kind,
            'state': '${snapshot['state']}',
            if (snapshot['desktopId'] case final String id) 'desktopId': id,
            if (snapshot['desktopName'] case final String name)
              'desktopName': name,
            if (snapshot['lanKey'] case final String key) 'lanKey': key,
            if (snapshot['agents'] != null)
              'agents': jsonEncode(snapshot['agents']),
            if (snapshot['models'] != null)
              'models': jsonEncode(snapshot['models']),
            for (final name in ['five', 'week', 'fiveReset', 'weekReset'])
              name: snapshot[name]?.toString() ?? '-',
          },
        ),
      );
      return result.trim() == 'ok sync';
    } on IOException {
      await _removeForward();
      return false;
    } on TimeoutException {
      await _removeForward();
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<ProcessResult> _usbCall(String serial, String method) => _adbRun([
    '-s',
    serial,
    'shell',
    'content',
    'call',
    '--uri',
    'content://com.reareyes.app.usb-lan',
    '--method',
    method,
  ]);

  Future<_LanPhone?> _importUsbLan(String serial, int generation) async {
    try {
      final result = await _usbCall(serial, 'getConfig');
      if (_usbLanHandled || generation != _generation || result.exitCode != 0) {
        return null;
      }
      final encoded = RegExp(
        r'^Result: Bundle\[\{lan_config=([A-Za-z0-9+/=]+)\}\]$',
      ).firstMatch((result.stdout as String).trim())?.group(1);
      if (encoded == null) return null;
      final config = utf8.decode(base64Decode(encoded));
      final imported = _parse(jsonDecode(config));
      final previous = _lan[imported.authorization];
      final phone = (
        url: imported.url,
        authorization: imported.authorization,
        phoneKey: imported.phoneKey ?? previous?.phoneKey,
        name: imported.name ?? previous?.name,
      );
      _savePhone(phone);
      _usbLanHandled = true;
      return phone;
    } on IOException {
      return null;
    } on TimeoutException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<bool> _pairOverUsb(String serial) async {
    Process? process;
    try {
      final pairing = await _readRemotePairing();
      if (pairing == null) return false;
      process = await Process.start(_adb!, [
        '-s',
        serial,
        'shell',
        '-T',
        'read -r pairing && content call --uri content://com.reareyes.app.usb-lan '
            r'--method setRemotePairing --arg "$pairing"',
      ]);
      final output = process.stdout.transform(utf8.decoder).join();
      unawaited(process.stderr.drain<void>());
      process.stdin.writeln(pairing);
      await process.stdin.flush().timeout(const Duration(seconds: 2));
      final [_, exitCode, reply] = await Future.wait<Object?>([
        process.stdin.close(),
        process.exitCode,
        output,
      ]).timeout(const Duration(seconds: 4));
      return exitCode == 0 &&
          reply is String &&
          reply.trim() == 'Result: Bundle[{paired=true}]';
    } on IOException {
      return false;
    } on TimeoutException {
      return false;
    } finally {
      process?.kill();
    }
  }

  Future<Map<String, ({String kind, String id})>> _devices() async {
    if (_adb == null) {
      final env = Platform.environment;
      final sdk =
          env['ANDROID_SDK_ROOT'] ??
          env['ANDROID_HOME'] ??
          (Platform.isWindows
              ? '${env['LOCALAPPDATA']}/Android/Sdk'
              : '${env['HOME']}/Library/Android/sdk');
      final executable = Platform.isWindows ? 'adb.exe' : 'adb';
      final app = '$sdk/platform-tools/$executable';
      _adb = File(app).existsSync() ? app : executable;
    }
    final result = await _adbRun(['devices', '-l']);
    final devices = <String, ({String kind, String id})>{};
    if (result.exitCode != 0) return devices;
    for (final row in (result.stdout as String).split('\n')) {
      final fields = row.trim().split(RegExp(r'\s+'));
      if (fields.length < 2 ||
          fields[1] != 'device' ||
          fields.first.startsWith('emulator-')) {
        continue;
      }
      final serial = fields.first;
      devices[serial] = (
        kind: serial.contains(':') || serial.endsWith('._adb-tls-connect._tcp')
            ? 'LAN'
            : 'USB',
        id: fields.firstWhere(
          (field) => field.startsWith('transport_id:'),
          orElse: () => serial,
        ),
      );
    }
    return devices;
  }

  Future<int?> _forwardedPort(String serial) async {
    final result = await _adbRun(['forward', '--list']);
    if (result.exitCode != 0) return null;
    for (final row in (result.stdout as String).split('\n')) {
      final fields = row.trim().split(RegExp(r'\s+'));
      if (fields.length == 3 &&
          fields.first == serial &&
          fields[1].startsWith('tcp:') &&
          fields.last == 'tcp:8788') {
        return int.tryParse(fields[1].substring(4));
      }
    }
    return null;
  }

  Future<ProcessResult> _adbRun(List<String> args) =>
      Process.run(_adb!, args).timeout(const Duration(seconds: 4));

  Future<void> _removeForward() async {
    final forward = _forward;
    _forward = null;
    if (forward == null || !forward.owned) return;
    try {
      await _adbRun([
        '-s',
        forward.serial,
        'forward',
        '--remove',
        'tcp:${forward.port}',
      ]);
    } on IOException {
      // ADB or the device is already unavailable.
    } on TimeoutException {
      // The OS releases the forward when the device disconnects.
    }
  }

  static const _timeout = Duration(seconds: 2);
  HttpClient _client() => HttpClient()
    ..connectionTimeout = _timeout
    ..findProxy = (_) => 'DIRECT';

  Future<String> _get(HttpClient client, Uri uri) async {
    final request = await client.getUrl(uri).timeout(_timeout);
    request.followRedirects = false;
    final response = await request.close().timeout(_timeout);
    if (response.statusCode != 200) {
      throw const HttpException('ADB sync failed');
    }
    return utf8.decoder.bind(response).join().timeout(_timeout);
  }
}
