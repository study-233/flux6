import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef JsonMap = Map<String, dynamic>;
JsonMap object(Object? raw) =>
    raw is Map ? raw.map((k, v) => MapEntry(k.toString(), v)) : {};

class ApiFailure implements Exception {
  const ApiFailure(this.message, {this.code = '', this.status = 0});
  final String message, code;
  final int status;
  @override
  String toString() => message;
}

class WireReply {
  const WireReply(this.status, this.body);
  final int status;
  final String body;
}

abstract class Transport {
  Future<WireReply> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
    Duration timeout = const Duration(seconds: 15),
  });
  void close() {}
}

class IoTransport extends Transport {
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8)
    ..findProxy = ((_) => 'DIRECT');
  @override
  Future<WireReply> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    HttpClientRequest? request;
    var cancelled = false;
    try {
      return await (() async {
        request = await _client.openUrl(method, uri);
        if (cancelled) {
          request!.abort();
          throw const ApiFailure('请求已取消');
        }
        request!.followRedirects = false;
        headers.forEach((k, v) => request!.headers.set(k, v));
        if (body != null) request!.write(body);
        final response = await request!.close();
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
          if (bytes.length > 8 * 1024 * 1024)
            throw const ApiFailure('响应超过大小限制');
        }
        return WireReply(response.statusCode, utf8.decode(bytes));
      })().timeout(timeout);
    } on TimeoutException {
      cancelled = true;
      request?.abort();
      throw const ApiFailure('请求超时，请重试', code: 'timeout');
    } on SocketException {
      throw const ApiFailure('无法连接本地组件或网络暂不可用', code: 'offline');
    } finally {
      // Aborting an already completed request is a no-op; it also closes a
      // response rejected by the size or decoding checks.
      request?.abort();
    }
  }

  @override
  void close() => _client.close(force: true);
}

class HelperCredentials {
  const HelperCredentials(this.port, this.token);
  final int port;
  final String token;
  factory HelperCredentials.decode(Object? raw) {
    final data = object(raw);
    final port = data['port'], token = data['token'];
    if (port is! int ||
        port < 1 ||
        port > 65535 ||
        token is! String ||
        token.isEmpty) {
      throw const ApiFailure('本地组件连接信息无效', code: 'bootstrap');
    }
    return HelperCredentials(port, token);
  }
}

JsonMap decodeReply(WireReply reply) {
  JsonMap data;
  try {
    final raw = jsonDecode(reply.body);
    if (raw is! Map) throw const FormatException('Expected object');
    data = object(raw);
  } on FormatException {
    throw ApiFailure('组件返回了无效响应（HTTP ${reply.status}）', status: reply.status);
  }
  if (reply.status < 200 || reply.status >= 300) {
    throw ApiFailure(
      data['error']?.toString() ?? 'HTTP ${reply.status}',
      code: data['code']?.toString() ?? '',
      status: reply.status,
    );
  }
  return data;
}

class HelperApi {
  HelperApi(this.transport, this.credentials);
  final Transport transport;
  final Future<HelperCredentials> Function() credentials;
  HelperCredentials? _cached;
  Future<JsonMap> call(
    String path, {
    String method = 'GET',
    JsonMap? body,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final auth = _cached ??= await credentials();
    Future<WireReply> send(HelperCredentials current) => transport.send(
      method,
      Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: current.port,
        path: '/api/v1$path',
      ),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${current.token}',
      },
      body: body == null ? null : jsonEncode(body),
      timeout: timeout,
    );
    var reply = await send(auth);
    if (reply.status == 401) {
      final fresh = await credentials();
      _cached = fresh;
      if (fresh.token != auth.token || fresh.port != auth.port)
        reply = await send(fresh);
    }
    return decodeReply(reply);
  }
}

class ControllerApi {
  ControllerApi(this.transport, this.secret);
  final Transport transport;
  final String Function() secret;
  Future<JsonMap> call(
    List<String> path, {
    String method = 'GET',
    JsonMap? body,
    Map<String, String>? query,
  }) async {
    final token = secret();
    final uri = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: 9090,
      pathSegments: path,
      queryParameters: query,
    );
    final reply = await transport.send(
      method,
      uri,
      headers: {
        'Content-Type': 'application/json',
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      },
      body: body == null ? null : jsonEncode(body),
      timeout: const Duration(seconds: 8),
    );
    if (reply.status == 204 && reply.body.isEmpty) return {};
    return decodeReply(reply);
  }
}

bool campusIPv6(String raw) {
  final address = InternetAddress.tryParse(raw.trim().split('%').first);
  if (address == null || address.type != InternetAddressType.IPv6) return false;
  final bytes = address.rawAddress;
  return bytes[0] == 0x20 &&
      bytes[1] == 0x01 &&
      ((bytes[2] == 0x0d && bytes[3] == 0xa8) ||
          (bytes[2] == 0x02 && bytes[3] == 0x50));
}

int compareVersions(String a, String b) {
  List<int> parts(String value) => value
      .replaceFirst(RegExp(r'^v'), '')
      .split(RegExp(r'[.+-]'))
      .take(3)
      .map((n) => int.tryParse(n) ?? 0)
      .toList();
  final left = parts(a), right = parts(b);
  for (var i = 0; i < 3; i++) {
    final result = (i < left.length ? left[i] : 0).compareTo(
      i < right.length ? right[i] : 0,
    );
    if (result != 0) return result;
  }
  return 0;
}
