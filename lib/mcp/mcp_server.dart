import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'auth.dart';
import 'tools.dart';

/// Core JSON-RPC 2.0 / Model Context Protocol server for Marsa.
class McpServer {
  McpServer(
    this.registry, {
    this.serverName = 'marsa-mcp',
    this.serverVersion = '0.4.2',
  });

  final McpToolRegistry registry;
  final String serverName;
  final String serverVersion;

  static const String protocolVersion = '2025-03-26';

  /// Handles a raw JSON-RPC 2.0 message string.
  /// Returns `null` for notifications (requests without `id`).
  Future<Map<String, dynamic>?> handleRaw(
    String raw,
    McpAgentToken agent,
  ) async {
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      return _errorResponse(null, -32700, 'Parse error: ${e.message}');
    }
    if (decoded is! Map<String, dynamic>) {
      return _errorResponse(null, -32600, 'Invalid Request: expected JSON object');
    }
    return handleRequest(decoded, agent);
  }

  /// Handles a decoded JSON-RPC 2.0 request object.
  Future<Map<String, dynamic>?> handleRequest(
    Map<String, dynamic> req,
    McpAgentToken agent,
  ) async {
    final id = req['id'];
    final method = req['method'];
    if (req['jsonrpc'] != '2.0' || method is! String) {
      return _errorResponse(id, -32600, 'Invalid Request');
    }
    final params = req['params'] is Map<String, dynamic>
        ? req['params'] as Map<String, dynamic>
        : const <String, dynamic>{};

    // Notifications have no `id` and expect no response.
    final isNotification = !req.containsKey('id') || id == null;

    try {
      switch (method) {
        case 'initialize':
          return _okResponse(id, {
            'protocolVersion': protocolVersion,
            'capabilities': {
              'tools': {'listChanged': false},
              'resources': {'subscribe': false, 'listChanged': false},
            },
            'serverInfo': {'name': serverName, 'version': serverVersion},
          });
        case 'notifications/initialized':
        case 'notifications/cancelled':
          return isNotification ? null : _okResponse(id, const {});
        case 'ping':
          return _okResponse(id, const {});
        case 'tools/list':
          return _okResponse(id, {'tools': registry.listTools(agent)});
        case 'tools/call':
          final name = params['name'];
          if (name is! String || name.isEmpty) {
            return _errorResponse(id, -32602, 'Missing tool name');
          }
          final args = params['arguments'] is Map<String, dynamic>
              ? params['arguments'] as Map<String, dynamic>
              : const <String, dynamic>{};
          final result = await registry.callTool(name, args, agent);
          return _okResponse(id, result);
        case 'resources/list':
          return _okResponse(id, {'resources': registry.listResources(agent)});
        case 'resources/read':
          final uri = params['uri'];
          if (uri is! String || uri.isEmpty) {
            return _errorResponse(id, -32602, 'Missing resource uri');
          }
          final result = await registry.readResource(uri, agent);
          return _okResponse(id, result);
        default:
          if (isNotification) return null;
          return _errorResponse(id, -32601, 'Method not found: $method');
      }
    } on McpToolError catch (e) {
      if (isNotification) return null;
      final code = switch (e.code) {
        'INVALID_PARAMS' => -32602,
        'TOOL_NOT_FOUND' || 'RESOURCE_NOT_FOUND' => -32601,
        'PERMISSION_DENIED' || 'CONSENT_DENIED' => -32001,
        'VAULT_LOCKED' => -32002,
        _ => -32000,
      };
      return _errorResponse(id, code, e.message, data: {'code': e.code});
    } catch (e) {
      if (isNotification) return null;
      return _errorResponse(id, -32603, 'Internal error: $e');
    }
  }

  /// Serves newline-delimited JSON-RPC 2.0 over a stdio stream pair.
  Future<void> serveStdio(
    Stream<List<int>> input,
    IOSink output,
    McpAgentToken agent,
  ) async {
    await for (final line
        in input.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      final res = await handleRaw(line, agent);
      if (res != null) {
        output.writeln(jsonEncode(res));
        await output.flush();
      }
    }
  }

  static Map<String, dynamic> _okResponse(
    dynamic id,
    Map<String, dynamic> result,
  ) => {'jsonrpc': '2.0', 'id': id, 'result': result};

  static Map<String, dynamic> _errorResponse(
    dynamic id,
    int code,
    String message, {
    Map<String, dynamic>? data,
  }) => {
    'jsonrpc': '2.0',
    'id': id,
    'error': {
      'code': code,
      'message': message,
      'data': ?data,
    },
  };
}
