import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Sends snapshots over the phone's existing ADB and same-subnet MCP listeners.
class PhoneLinks {
  PhoneLinks(this.directory, this._readRemotePairing, this._onChanged);

  final Directory directory;
  final Future<String?> Function() _readRemotePairing;
  final void Function() _onChanged;
  ({Uri url, String authorization})? _lan;
  String? _adb;
  ({String serial, int port, bool owned})? _forward;
  ({String serial, String id})? _usbTransport;
  bool _usbLanHandled = false;
  bool _usbRemoteHandled = false;
  bool _inFlight = false;
  Map<String, Object?>? _pendingSnapshot;
  int _generation = 0;
  int _lanRevision = 0;
  bool? _lanReachable;
  String? _adbTransport;

  File get _lanFile => File('${directory.path}/phone-lan.json');
  String? get lanAddress => _lan?.url.replace(path: '/mcp').toString();
  bool? get lanReachable => _lanReachable;
  String? get adbTransport => _adbTransport;

  void stop() {
    _generation++;
    _pendingSnapshot = null;
    _lanReachable = null;
    _adbTransport = null;
  }

  void load() {
    _lan = null;
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
    } else {
      final parsed = _parse(config);
      directory.createSync(recursive: true);
      _lanFile.writeAsStringSync(config, flush: true);
      if (!Platform.isWindows) {
        Process.runSync('/bin/chmod', ['600', _lanFile.path]);
      }
      _lan = parsed;
    }
    _lanRevision++;
    _lanReachable = null;
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
        final generation = _generation;
        await _sendAdb(next, _sendLan(next, generation), generation);
      }
    } finally {
      _inFlight = false;
    }
  }

  Future<bool> _sendLan(Map<String, Object?> snapshot, int generation) async {
    final lan = _lan;
    if (lan == null) return false;
    final revision = _lanRevision;
    final reachable = await _postSnapshot(snapshot, lan);
    if (generation != _generation || revision != _lanRevision) return false;
    if (_lanReachable != reachable) {
      _lanReachable = reachable;
      _onChanged();
    }
    return reachable;
  }

  Future<bool> _postSnapshot(
    Map<String, Object?> snapshot,
    ({Uri url, String authorization}) lan,
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
      await response.drain<void>().timeout(_timeout);
      return response.statusCode == HttpStatus.ok;
    } on IOException {
      return false;
    } on TimeoutException {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _sendAdb(
    Map<String, Object?> snapshot,
    Future<bool> lanConnected,
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
          _repairUsbLan(serial, snapshot, lanConnected, generation),
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
    Future<bool> lanConnected,
    int generation,
  ) async {
    if (_usbLanHandled) return;
    if (await lanConnected) {
      _usbLanHandled = true;
      return;
    }
    if (_usbLanHandled || generation != _generation) return;
    if (await _importUsbLan(serial, generation)) {
      await _sendLan(snapshot, generation);
    }
  }

  Future<void> _repairUsbTailscale(String serial) async {
    if (_usbRemoteHandled) return;
    _usbRemoteHandled = true;
    try {
      final result = await _usbCall(serial, 'getLinkStatus');
      if (result.exitCode == 0 &&
          (result.stdout as String).trim() ==
              'Result: Bundle[{tailscale_connected=true}]') {
        return;
      }
    } on IOException {
      return;
    } on TimeoutException {
      return;
    }
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

  Future<bool> _importUsbLan(String serial, int generation) async {
    try {
      final result = await _usbCall(serial, 'getConfig');
      if (_usbLanHandled || generation != _generation || result.exitCode != 0) {
        return false;
      }
      final encoded = RegExp(
        r'^Result: Bundle\[\{lan_config=([A-Za-z0-9+/=]+)\}\]$',
      ).firstMatch((result.stdout as String).trim())?.group(1);
      if (encoded == null) return false;
      _saveLan(utf8.decode(base64Decode(encoded)));
      return true;
    } on IOException {
      return false;
    } on TimeoutException {
      return false;
    } on FormatException {
      return false;
    } finally {
      if (generation == _generation) _usbLanHandled = true;
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
