import 'dart:io';

class WebApp {
  WebApp(this.root);

  final Directory root;
  bool get available => File('${root.path}/index.html').existsSync();

  static const _types = {
    'html': 'text/html; charset=utf-8',
    'js': 'text/javascript; charset=utf-8',
    'json': 'application/json; charset=utf-8',
    'css': 'text/css; charset=utf-8',
    'wasm': 'application/wasm',
    'png': 'image/png',
    'webp': 'image/webp',
    'svg': 'image/svg+xml',
    'ico': 'image/x-icon',
    'ttf': 'font/ttf',
    'otf': 'font/otf',
    'woff': 'font/woff',
    'woff2': 'font/woff2',
    'bin': 'application/octet-stream',
  };

  Future<bool> serve(HttpRequest request) async {
    if (request.method != 'GET' && request.method != 'HEAD') return false;
    final segments = request.uri.path == '/'
        ? const ['index.html']
        : request.uri.pathSegments;
    if (segments.isEmpty ||
        segments.any(
          (part) =>
              part == '.' ||
              part == '..' ||
              !RegExp(r'^[A-Za-z0-9_@. +%-]+$').hasMatch(part),
        )) {
      return false;
    }
    final type = _types[segments.last.split('.').last];
    if (type == null) return false;
    final file = File('${root.path}/${segments.join('/')}');
    if (!await file.exists()) return false;

    final directory = await root.resolveSymbolicLinks();
    final resolved = await file.resolveSymbolicLinks();
    if (!resolved.startsWith('$directory${Platform.pathSeparator}')) {
      return false;
    }

    final response = request.response;
    response.headers.contentType = ContentType.parse(type);
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    response.headers.set('X-Content-Type-Options', 'nosniff');
    response.headers.set('Referrer-Policy', 'same-origin');
    response.contentLength = await file.length();
    if (request.method == 'GET') await response.addStream(file.openRead());
    return true;
  }
}
