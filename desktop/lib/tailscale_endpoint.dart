import 'dart:async';
import 'dart:convert';
import 'dart:io';

enum TailscaleState {
  unavailable,
  disconnected,
  serveMissing,
  serveUnknown,
  ready,
}

typedef TailscaleStatus = ({
  TailscaleState state,
  String? endpoint,
  String setupCommand,
});

Future<String?> findTailscaleEndpoint(int localPort, int preferredPort) =>
    _detectTailscale(
      localPort,
      preferredPort,
      checkConnection: false,
    ).then((status) => status.endpoint);

Future<TailscaleStatus> detectTailscale(int localPort, int preferredPort) =>
    _detectTailscale(localPort, preferredPort, checkConnection: true);

Future<TailscaleStatus> _detectTailscale(
  int localPort,
  int preferredPort, {
  required bool checkConnection,
}) async {
  final env = Platform.environment;
  final commands = Platform.isWindows
      ? {
          for (final folder in [
            env['ProgramW6432'],
            env['ProgramFiles'],
            env['ProgramFiles(x86)'],
          ])
            if (folder != null) '$folder\\Tailscale\\tailscale.exe',
          'tailscale.exe',
        }
      : [
          'tailscale',
          '/usr/local/bin/tailscale',
          '/opt/homebrew/bin/tailscale',
          '/Applications/Tailscale.app/Contents/MacOS/Tailscale',
        ];
  TailscaleStatus status(
    TailscaleState state, {
    String command = 'tailscale',
    String? endpoint,
  }) {
    final escapedCommand = command.replaceAll(
      "'",
      Platform.isWindows ? "''" : "'\\''",
    );
    final executable = command == 'tailscale' || command == 'tailscale.exe'
        ? command
        : Platform.isWindows
        ? "& '$escapedCommand'"
        : "'$escapedCommand'";
    return (
      state: state,
      endpoint: endpoint,
      setupCommand: '$executable serve --bg --https=$preferredPort $localPort',
    );
  }

  TailscaleStatus? diagnostic;
  for (final command in commands) {
    final serve = await _readTailscaleJson(command, [
      'serve',
      'status',
      '--json',
    ]);
    final endpoint = serve == null
        ? null
        : _serveEndpoint(serve, localPort, preferredPort);
    if (!checkConnection) {
      if (endpoint != null) {
        return status(TailscaleState.ready, endpoint: endpoint);
      }
      continue;
    }

    final connection = await _readTailscaleJson(command, ['status', '--json']);
    final backendState = connection?['BackendState'];
    if (backendState == 'Running') {
      return status(
        endpoint != null
            ? TailscaleState.ready
            : serve == null
            ? TailscaleState.serveUnknown
            : TailscaleState.serveMissing,
        command: command,
        endpoint: endpoint,
      );
    }
    if (backendState is String) {
      return status(TailscaleState.disconnected, command: command);
    }
    if (serve != null) {
      diagnostic ??= status(
        endpoint == null ? TailscaleState.serveUnknown : TailscaleState.ready,
        command: command,
        endpoint: endpoint,
      );
    }
  }
  return diagnostic ?? status(TailscaleState.unavailable);
}

Future<Map<String, dynamic>?> _readTailscaleJson(
  String command,
  List<String> arguments,
) async {
  try {
    final result = await Process.run(
      command,
      arguments,
      stdoutEncoding: utf8,
    ).timeout(const Duration(seconds: 3));
    if (result.exitCode != 0) return null;
    final config = jsonDecode(result.stdout as String);
    return config is Map<String, dynamic> ? config : null;
  } on ProcessException {
    return null;
  } on TimeoutException {
    return null;
  } on FormatException {
    return null;
  }
}

String? _serveEndpoint(
  Map<String, dynamic> config,
  int localPort,
  int preferredPort,
) {
  final web = config['Web'];
  final funnel = config['AllowFunnel'];
  final tcp = config['TCP'];
  if (web is! Map) return null;
  String? fallback;
  for (final entry in web.entries) {
    final host = entry.key;
    if (host is! String || (funnel is Map && funnel[host] == true)) {
      continue;
    }
    final webConfig = entry.value;
    final handlers = webConfig is Map ? webConfig['Handlers'] : null;
    final root = handlers is Map ? handlers['/'] : null;
    final proxy = root is Map ? root['Proxy'] : null;
    final target = proxy is String ? Uri.tryParse(proxy) : null;
    if (target == null ||
        target.port != localPort ||
        !['127.0.0.1', 'localhost'].contains(target.host) ||
        (target.path.isNotEmpty && target.path != '/')) {
      continue;
    }
    final uri = Uri.tryParse('https://$host');
    if (uri == null ||
        !uri.host.endsWith('.ts.net') ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.port < 1 ||
        uri.port > 65535) {
      continue;
    }
    final listener = tcp is Map ? tcp['${uri.port}'] : null;
    if (tcp is Map && (listener is! Map || listener['HTTPS'] != true)) {
      continue;
    }
    if (uri.port == preferredPort) return uri.toString();
    fallback ??= uri.toString();
  }
  return fallback;
}
