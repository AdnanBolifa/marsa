import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

int _idSeq = 0;
String _nextExecId() =>
    'exec_${DateTime.now().microsecondsSinceEpoch}_${++_idSeq}';

enum McpExecutionStatus { running, ok, error, killed, timeout }

class McpCommandExecution {
  McpCommandExecution({
    required this.id,
    required this.agentId,
    required this.agentName,
    required this.hostId,
    required this.hostLabel,
    required this.command,
    required this.startedAt,
    this.finishedAt,
    this.status = McpExecutionStatus.running,
    this.exitCode,
    this.errorMessage,
    this.truncated = false,
    String initialStdout = '',
    String initialStderr = '',
  }) {
    if (initialStdout.isNotEmpty) _stdout.write(initialStdout);
    if (initialStderr.isNotEmpty) _stderr.write(initialStderr);
  }

  factory McpCommandExecution.fromJson(Map<String, dynamic> j) {
    final statusName = j['status'] as String? ?? 'error';
    final parsedStatus = McpExecutionStatus.values.firstWhere(
      (s) => s.name == statusName,
      orElse: () => McpExecutionStatus.error,
    );
    return McpCommandExecution(
      id: j['id'] as String? ?? _nextExecId(),
      agentId: j['agentId'] as String? ?? '',
      agentName: j['agentName'] as String? ?? 'Unknown agent',
      hostId: j['hostId'] as String? ?? '',
      hostLabel: j['hostLabel'] as String? ?? 'Unknown host',
      command: j['command'] as String? ?? '',
      startedAt:
          DateTime.tryParse(j['startedAt'] as String? ?? '') ?? DateTime.now(),
      finishedAt: j['finishedAt'] != null
          ? DateTime.tryParse(j['finishedAt'] as String)
          : null,
      status: parsedStatus == McpExecutionStatus.running
          ? McpExecutionStatus.error
          : parsedStatus,
      exitCode: (j['exitCode'] as num?)?.toInt(),
      errorMessage: parsedStatus == McpExecutionStatus.running
          ? 'Interrupted before completion'
          : j['errorMessage'] as String?,
      truncated: j['truncated'] as bool? ?? false,
      initialStdout: j['stdout'] as String? ?? '',
      initialStderr: j['stderr'] as String? ?? '',
    );
  }

  final String id;
  final String agentId;
  final String agentName;
  final String hostId;
  final String hostLabel;
  final String command;
  final DateTime startedAt;
  DateTime? finishedAt;
  McpExecutionStatus status;
  int? exitCode;
  String? errorMessage;
  bool truncated;

  final StringBuffer _stdout = StringBuffer();
  final StringBuffer _stderr = StringBuffer();
  Future<void> Function()? _onKill;

  String get stdout => _stdout.toString();
  String get stderr => _stderr.toString();
  bool get isRunning => status == McpExecutionStatus.running;
  Duration get duration => (finishedAt ?? DateTime.now()).difference(startedAt);

  Map<String, dynamic> toJson() => {
    'id': id,
    'agentId': agentId,
    'agentName': agentName,
    'hostId': hostId,
    'hostLabel': hostLabel,
    'command': command,
    'startedAt': startedAt.toUtc().toIso8601String(),
    if (finishedAt != null)
      'finishedAt': finishedAt!.toUtc().toIso8601String(),
    'status': status.name,
    if (exitCode != null) 'exitCode': exitCode,
    if (errorMessage != null) 'errorMessage': errorMessage,
    'truncated': truncated,
    'stdout': stdout,
    'stderr': stderr,
  };
}

class McpExecutionTracker extends ChangeNotifier {
  McpExecutionTracker({
    this.file,
    this.maxEntries = 300,
    this.maxOutputBytes = 65536,
  });

  final File? file;
  final int maxEntries;
  final int maxOutputBytes;

  final List<McpCommandExecution> _entries = [];

  List<McpCommandExecution> get all => List.unmodifiable(_entries);
  List<McpCommandExecution> get active =>
      List.unmodifiable(_entries.where((e) => e.isRunning));
  List<McpCommandExecution> get history =>
      List.unmodifiable(_entries.where((e) => !e.isRunning));
  int get activeCount => _entries.where((e) => e.isRunning).length;

  McpCommandExecution? byId(String id) {
    for (final e in _entries) {
      if (e.id == id) return e;
    }
    return null;
  }

  Future<void> load() async {
    final f = file;
    if (f == null || !await f.exists()) return;
    final lines = await f.readAsLines();
    _entries.clear();
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic>) {
          _entries.add(McpCommandExecution.fromJson(decoded));
        }
      } catch (_) {
        // Ignore malformed lines in local history.
      }
    }
    _entries.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    if (_entries.length > maxEntries) {
      _entries.removeRange(maxEntries, _entries.length);
    }
    notifyListeners();
  }

  McpCommandExecution start({
    required String agentId,
    required String agentName,
    required String hostId,
    required String hostLabel,
    required String command,
    Future<void> Function()? onKill,
  }) {
    final exec = McpCommandExecution(
      id: _nextExecId(),
      agentId: agentId,
      agentName: agentName,
      hostId: hostId,
      hostLabel: hostLabel,
      command: command,
      startedAt: DateTime.now(),
    ).._onKill = onKill;
    _entries.insert(0, exec);
    notifyListeners();
    return exec;
  }

  void attachKillHandler(String id, Future<void> Function() onKill) {
    final exec = byId(id);
    if (exec == null) return;
    exec._onKill = onKill;
  }

  void appendStdout(String id, String text) {
    final exec = byId(id);
    if (exec == null || text.isEmpty) return;
    _appendBounded(exec._stdout, exec, text);
    notifyListeners();
  }

  void appendStderr(String id, String text) {
    final exec = byId(id);
    if (exec == null || text.isEmpty) return;
    _appendBounded(exec._stderr, exec, text);
    notifyListeners();
  }

  void _appendBounded(
    StringBuffer buf,
    McpCommandExecution exec,
    String text,
  ) {
    final remaining = maxOutputBytes - buf.length;
    if (remaining <= 0) {
      exec.truncated = true;
      return;
    }
    if (text.length > remaining) {
      buf.write(text.substring(0, remaining));
      exec.truncated = true;
    } else {
      buf.write(text);
    }
  }

  Future<void> finish(
    String id, {
    required McpExecutionStatus status,
    int? exitCode,
    String? errorMessage,
    bool truncated = false,
  }) async {
    final exec = byId(id);
    if (exec == null) return;
    // Preserve killed status if the user already cancelled it.
    if (exec.status != McpExecutionStatus.killed) {
      exec.status = status;
    }
    exec.finishedAt ??= DateTime.now();
    exec.exitCode = exitCode ?? exec.exitCode;
    exec.errorMessage = errorMessage ?? exec.errorMessage;
    exec.truncated = exec.truncated || truncated;
    exec._onKill = null;

    if (_entries.length > maxEntries) {
      _entries.removeRange(maxEntries, _entries.length);
    }
    notifyListeners();
    await _persist();
  }

  Future<void> kill(String id) async {
    final exec = byId(id);
    if (exec == null || !exec.isRunning) return;
    exec.status = McpExecutionStatus.killed;
    exec.finishedAt = DateTime.now();
    exec.errorMessage = 'Stopped by user';
    final onKill = exec._onKill;
    exec._onKill = null;
    notifyListeners();
    if (onKill != null) {
      try {
        await onKill();
      } catch (_) {}
    }
    await _persist();
  }

  Future<void> clearHistory() async {
    _entries.removeWhere((e) => !e.isRunning);
    notifyListeners();
    await _persist();
  }

  Future<void> clearHistoryForAgent(String agentId) async {
    _entries.removeWhere((e) => !e.isRunning && e.agentId == agentId);
    notifyListeners();
    await _persist();
  }

  Future<void> clearHistoryForHost(String hostId) async {
    _entries.removeWhere((e) => !e.isRunning && e.hostId == hostId);
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    final f = file;
    if (f == null) return;
    await f.parent.create(recursive: true);
    final completed = _entries.where((e) => !e.isRunning).toList();
    final content = completed.map((e) => jsonEncode(e.toJson())).join('\n');
    await f.writeAsString(content.isEmpty ? '' : '$content\n');
  }
}
