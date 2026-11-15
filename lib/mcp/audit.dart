import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

enum McpAuditStatus { ok, denied, error }

class McpAuditEntry {
  McpAuditEntry({
    required this.timestamp,
    required this.agentId,
    required this.agentName,
    required this.toolName,
    required this.status,
    required this.durationMs,
    this.vaultId,
    this.hostId,
    this.hostLabel,
    this.argsSummary,
    this.detail,
  });

  factory McpAuditEntry.fromJson(Map<String, dynamic> j) => McpAuditEntry(
    timestamp: j['ts'] as int? ?? 0,
    agentId: j['agentId'] as String? ?? '',
    agentName: j['agentName'] as String? ?? '',
    toolName: j['toolName'] as String? ?? '',
    status: McpAuditStatus.values.firstWhere(
      (s) => s.name == j['status'],
      orElse: () => McpAuditStatus.error,
    ),
    durationMs: j['durationMs'] as int? ?? 0,
    vaultId: j['vaultId'] as String?,
    hostId: j['hostId'] as String?,
    hostLabel: j['hostLabel'] as String?,
    argsSummary: j['args'] as String?,
    detail: j['detail'] as String?,
  );

  final int timestamp;
  final String agentId;
  final String agentName;
  final String toolName;
  final McpAuditStatus status;
  final int durationMs;
  final String? vaultId;
  final String? hostId;
  final String? hostLabel;
  final String? argsSummary;
  final String? detail;

  Map<String, dynamic> toJson() => {
    'ts': timestamp,
    'agentId': agentId,
    'agentName': agentName,
    'toolName': toolName,
    'status': status.name,
    'durationMs': durationMs,
    if (vaultId != null) 'vaultId': vaultId,
    if (hostId != null) 'hostId': hostId,
    if (hostLabel != null) 'hostLabel': hostLabel,
    if (argsSummary != null) 'args': argsSummary,
    if (detail != null) 'detail': detail,
  };
}

/// Records MCP agent requests and tracks currently active requests/sessions.
class McpAuditLog extends ChangeNotifier {
  McpAuditLog({this.file, this.maxEntries = 500});

  final File? file;
  final int maxEntries;
  final List<McpAuditEntry> entries = [];
  int _activeRequests = 0;

  bool get hasActiveRequests => _activeRequests > 0;
  int get activeRequestCount => _activeRequests;

  void beginRequest() {
    _activeRequests++;
    notifyListeners();
  }

  void endRequest() {
    if (_activeRequests > 0) _activeRequests--;
    notifyListeners();
  }

  Future<void> load() async {
    entries.clear();
    final f = file;
    if (f == null || !await f.exists()) {
      notifyListeners();
      return;
    }
    try {
      final lines = await f.readAsLines();
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        final j = jsonDecode(line);
        if (j is Map<String, dynamic>) {
          entries.add(McpAuditEntry.fromJson(j));
        }
      }
      if (entries.length > maxEntries) {
        entries.removeRange(0, entries.length - maxEntries);
      }
    } on FormatException {
      // Ignore damaged lines.
    }
    notifyListeners();
  }

  Future<void> record(McpAuditEntry entry) async {
    entries.add(entry);
    if (entries.length > maxEntries) {
      entries.removeAt(0);
    }
    notifyListeners();
    final f = file;
    if (f != null) {
      await f.parent.create(recursive: true);
      await f.writeAsString(
        '${jsonEncode(entry.toJson())}\n',
        mode: FileMode.append,
        flush: true,
      );
    }
  }

  Future<void> clear() async {
    entries.clear();
    notifyListeners();
    final f = file;
    if (f != null && await f.exists()) {
      await f.writeAsString('', flush: true);
    }
  }

  String exportJson() =>
      const JsonEncoder.withIndent('  ').convert(entries.map((e) => e.toJson()).toList());
}
