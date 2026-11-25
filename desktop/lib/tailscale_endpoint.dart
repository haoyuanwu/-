import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<String?> findTailscaleEndpoint(int localPort, int preferredPort) async {
  final env = Platform.environment;
  final commands = Platform.isWindows
      ? [
          'tailscale.exe',
          for (final folder in [env['ProgramFiles'], env['ProgramFiles(x86)']])
            if (folder != null) '$folder/Tailscale/tailscale.exe',
        ]
      : [
          'tailscale',
          '/usr/local/bin/tailscale',
          '/opt/homebrew/bin/tailscale',
          '/Applications/Tailscale.app/Contents/MacOS/Tailscale',
        ];
  for (final command in commands) {
    try {
      final result = await Process.run(command, [
        'serve',
        'status',
        '--json',
      ]).timeout(const Duration(seconds: 3));
      if (result.exitCode != 0) continue;
      final config = jsonDecode(result.stdout as String);
      final web = config is Map ? config['Web'] : null;
      final funnel = config is Map ? config['AllowFunnel'] : null;
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
        if (uri.port == preferredPort) return uri.toString();
        fallback ??= uri.toString();
      }
      return fallback;
    } on ProcessException {
      // Try the next installed Tailscale executable.
    } on TimeoutException {
      return null;
    } on FormatException {
      return null;
    }
  }
  return null;
}
