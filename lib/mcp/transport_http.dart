import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'auth.dart';
import 'mcp_server.dart';

/// Loopback-only (`127.0.0.1`) Streamable HTTP / SSE transport for [McpServer].
class McpHttpServer {
  McpHttpServer({
    required this.mcpServer,
    required this.tokenStore,
  });

  final McpServer mcpServer;
  final McpTokenStore tokenStore;

  HttpServer? _server;
  final Set<HttpResponse> _sseClients = {};

  bool get isRunning => _server != null;
  int? get port => _server?.port;

  Future<int> start({int port = 47832}) async {
    if (_server != null) return _server!.port;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server = server;
    server.listen(
      _handleHttp,
      onError: (_) {},
      cancelOnError: false,
    );
    return server.port;
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    await disconnectAllSessions();
    await s?.close(force: true);
  }

  Future<void> disconnectAllSessions() async {
    final clients = _sseClients.toList();
    _sseClients.clear();
    for (final res in clients) {
      try {
        await res.close();
      } catch (_) {}
    }
  }

  Future<void> _handleHttp(HttpRequest req) async {
    // Reject DNS-rebinding attempts by requiring a loopback Host header.
    final hostHeader = req.headers.value(HttpHeaders.hostHeader) ?? '';
    final hostOnly = hostHeader.split(':').first.toLowerCase();
    if (hostOnly.isNotEmpty &&
        hostOnly != '127.0.0.1' &&
        hostOnly != 'localhost' &&
        hostOnly != '[::1]') {
      req.response.statusCode = HttpStatus.forbidden;
      req.response.write('Forbidden Host');
      await req.response.close();
      return;
    }

    if (req.uri.path == '/health' && req.method == 'GET') {
      _sendJson(req.response, HttpStatus.ok, {
        'ok': true,
        'service': mcpServer.serverName,
        'version': mcpServer.serverVersion,
      });
      return;
    }

    if (req.uri.path != '/mcp') {
      _sendJson(req.response, HttpStatus.notFound, {'error': 'Not found'});
      return;
    }

    final agent = _authenticate(req);
    if (agent == null) {
      req.response.headers.set(
        HttpHeaders.wwwAuthenticateHeader,
        'Bearer realm="marsa-mcp"',
      );
      _sendJson(req.response, HttpStatus.unauthorized, {
        'error': 'Invalid or missing bearer token',
      });
      return;
    }

    if (req.method == 'POST') {
      final body = await utf8.decoder.bind(req).join();
      final res = await mcpServer.handleRaw(body, agent);
      if (res == null) {
        req.response.statusCode = HttpStatus.accepted;
        await req.response.close();
        return;
      }
      _sendJson(req.response, HttpStatus.ok, res);
      return;
    }

    if (req.method == 'GET') {
      req.response.statusCode = HttpStatus.ok;
      req.response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
      req.response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      req.response.headers.set(HttpHeaders.connectionHeader, 'keep-alive');
      req.response.write(': marsa-mcp connected\n\n');
      await req.response.flush();
      _sseClients.add(req.response);
      req.response.done.whenComplete(() => _sseClients.remove(req.response));
      return;
    }

    req.response.statusCode = HttpStatus.methodNotAllowed;
    await req.response.close();
  }

  McpAgentToken? _authenticate(HttpRequest req) {
    final auth = req.headers.value(HttpHeaders.authorizationHeader);
    if (auth == null) return null;
    const prefix = 'Bearer ';
    if (!auth.startsWith(prefix)) return null;
    final rawToken = auth.substring(prefix.length).trim();
    return tokenStore.authenticate(rawToken);
  }

  void _sendJson(HttpResponse res, int status, Map<String, dynamic> body) {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
    res.close();
  }
}
