enum ModelSource {
  desktop('电脑默认'),
  cloud('云端模型'),
  lan('局域网模型'),
  local('本机模型');

  const ModelSource(this.label);
  final String label;
}

class PhoneModel {
  PhoneModel(this.source, String address, String model, String key)
    : endpoint = _endpoint(source, address.trim()),
      model = model.trim(),
      key = key.trim() {
    if (this.model.isEmpty || this.model.length > 200) {
      throw const FormatException('请输入模型 ID。');
    }
    if (this.key.length > 2048 || RegExp(r'[^\x21-\x7e]').hasMatch(this.key)) {
      throw const FormatException('访问密钥格式无效。');
    }
  }

  final ModelSource source;
  final Uri endpoint;
  final String model;
  final String key;

  static Uri _endpoint(ModelSource source, String address) {
    final uri = Uri.tryParse(address);
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.port < 1 ||
        uri.port > 65535) {
      throw const FormatException('请输入有效的 HTTP 或 HTTPS 模型地址。');
    }
    final host = uri.host.toLowerCase();
    final loopback = const {'localhost', '127.0.0.1', '::1'}.contains(host);
    final parts = host.split('.').map(int.tryParse).toList();
    final privateIpv4 =
        parts.length == 4 &&
        parts.every((part) => part != null && part >= 0 && part <= 255) &&
        (parts[0] == 10 ||
            (parts[0] == 172 && parts[1]! >= 16 && parts[1]! <= 31) ||
            (parts[0] == 192 && parts[1] == 168));
    switch (source) {
      case ModelSource.cloud:
        if (uri.scheme != 'https') {
          throw const FormatException('云端模型需要 HTTPS 地址。');
        }
      case ModelSource.lan:
        if (!privateIpv4 && !host.endsWith('.local')) {
          throw const FormatException('请输入内网 IPv4 地址或 .local 主机名。');
        }
      case ModelSource.local:
        if (!loopback) {
          throw const FormatException('本机模型需要手机上的回环地址。');
        }
      case ModelSource.desktop:
        throw const FormatException('请在电脑上设置默认模型。');
    }
    final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    return uri.replace(
      path: path.endsWith('/chat/completions')
          ? path
          : '${path.isEmpty ? '/v1' : path}/chat/completions',
    );
  }

  Map<String, String> toJson() => {
    'source': source.name,
    'url': endpoint.toString(),
    'model': model,
    'key': key,
  };

  static PhoneModel? fromJson(Object? value) {
    if (value is! Map) return null;
    final source = ModelSource.values
        .where((source) => source.name == value['source'])
        .firstOrNull;
    if (source == null ||
        value['url'] is! String ||
        value['model'] is! String ||
        value['key'] is! String) {
      return null;
    }
    return PhoneModel(source, value['url'], value['model'], value['key']);
  }
}
