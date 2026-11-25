import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Sends snapshots over the phone's existing ADB and same-subnet MCP listeners.
class PhoneLinks {
  PhoneLinks(this.directory, this._readRemotePairing);

  final Directory directory;
  final Future<String?> Function() _readRemotePairing;
  ({Uri url, String authorization})? _lan;
  String? _adb;
  ({String serial, int port, bool owned})? _forward;
  String? _usbLanTransport;
  bool _usbLanHandled = false;
  bool _usbRemotePaired = false;
  DateTime? _nextUsbPairingAttempt;
  bool _inFlight = false;
  Map<String, Object?>? _pendingSnapshot;

  File get _lanFile => File('${directory.path}/phone-lan.json');
  String? get lanAddress => _lan?.url.toString();

  void load() {
    if (!_lanFile.existsSync()) return;
    try {
      _lan = _parse(_lanFile.readAsStringSync());
    } on FormatException {
      _lan = null;
    }
  }

  void configureLan(String config) {
    _saveLan(config);
    // A manual edit or removal takes precedence until the next USB connection.
    _usbLanHandled = true;
  }

  void _saveLan(String config) {
    if (config.trim().isEmpty) {
      if (_lanFile.existsSync()) _lanFile.deleteSync();
      _lan = null;
      return;
    }
    final parsed = _parse(config);
    directory.createSync(recursive: true);
    _lanFile.writeAsStringSync(config, flush: true);
    if (!Platform.isWindows) {
      Process.runSync('/bin/chmod', ['600', _lanFile.path]);
    }
    _lan = parsed;
  }

  ({Uri url, String authorization}) _parse(String config) {
    final data = jsonDecode(config);
    final servers = data is Map ? data['mcpServers'] : null;
    final phone = servers is Map
        ? servers['robot-eyes'] ?? servers['rear-eyes']
        : null;
    final url = phone is Map ? phone['url'] : null;
    final headers = phone is Map ? phone['headers'] : null;
    final authorization = headers is Map ? headers['Authorization'] : null;
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
        await Future.wait([_sendAdb(next), _sendLan(next)]);
      }
    } finally {
      _inFlight = false;
    }
  }

  Future<void> _sendLan(Map<String, Object?> snapshot) async {
    final lan = _lan;
    if (lan == null) return;
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
      await response.drain<void>().timeout(_timeout);
    } on IOException {
      // The phone may have left the network.
    } on TimeoutException {
      // Retry on the next scheduled push.
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _sendAdb(Map<String, Object?> snapshot) async {
    final client = _client();
    try {
      final devices = await _devices();
      if (!devices.values.any((device) => device.id == _usbLanTransport)) {
        _usbLanTransport = null;
      }
      if (devices.isEmpty) return;
      final configured = Platform.environment['ANDROID_SERIAL'];
      var serial = configured ?? devices.keys.first;
      if (configured == null && devices.length > 1) {
        final identifiers = <String>{};
        for (final candidate in devices.keys) {
          final result = await _adbRun([
            '-s',
            candidate,
            'shell',
            'getprop',
            'ro.serialno',
          ]);
          identifiers.add((result.stdout as String).trim());
        }
        if (identifiers.length != 1 || identifiers.contains('')) return;
        serial = devices.keys.firstWhere(
          (key) => devices[key]?.kind == 'USB',
          orElse: () => devices.keys.first,
        );
      }
      final device = devices[serial];
      if (device == null) return;
      if (device.kind == 'USB') {
        if (_usbLanTransport != device.id) {
          _usbLanTransport = device.id;
          _usbLanHandled = false;
          _usbRemotePaired = false;
          _nextUsbPairingAttempt = null;
        }
        if (!_usbLanHandled) await _importUsbLan(serial);
        final now = DateTime.now();
        if (!_usbRemotePaired && _nextUsbPairingAttempt?.isAfter(now) != true) {
          _nextUsbPairingAttempt = now.add(const Duration(seconds: 15));
          _usbRemotePaired = await _pairOverUsb(serial);
        }
      }
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
          if (result.exitCode != 0 || port == null) return;
          _forward = (serial: serial, port: port, owned: true);
        }
      }
      final uri = Uri.parse('http://127.0.0.1:${_forward!.port}/codex-sync');
      final reply = (await _get(client, uri)).trim();
      if (!reply.startsWith('sync ')) return;
      await _get(
        client,
        uri.replace(
          queryParameters: {
            'ticket': reply.substring(5),
            'transport': device.kind,
            'state': '${snapshot['state']}',
            if (snapshot['agents'] != null)
              'agents': jsonEncode(snapshot['agents']),
            for (final name in ['five', 'week', 'fiveReset', 'weekReset'])
              name: snapshot[name]?.toString() ?? '-',
          },
        ),
      );
    } on IOException {
      await _removeForward();
    } on TimeoutException {
      await _removeForward();
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _importUsbLan(String serial) async {
    try {
      final result = await _adbRun([
        '-s',
        serial,
        'shell',
        'content',
        'call',
        '--uri',
        'content://com.reareyes.app.usb-lan',
        '--method',
        'getConfig',
      ]);
      if (_usbLanHandled || result.exitCode != 0) return;
      final encoded = RegExp(
        r'^Result: Bundle\[\{lan_config=([A-Za-z0-9+/=]+)\}\]$',
      ).firstMatch((result.stdout as String).trim())?.group(1);
      if (encoded == null) return;
      _saveLan(utf8.decode(base64Decode(encoded)));
      _usbLanHandled = true;
    } on IOException {
      // Keep the existing configuration and USB sync if import fails.
    } on TimeoutException {
      // Retry on a later push.
    } on FormatException {
      // Ignore unsupported or invalid configuration.
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
