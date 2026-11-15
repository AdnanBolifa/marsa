import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/vault.dart';
import '../ssh/connector.dart';
import 'audit.dart';
import 'auth.dart';
import 'executions.dart';
import 'mcp_server.dart';
import 'prompter.dart';
import 'tools.dart';
import 'transport_http.dart';

/// Coordinates the Marsa MCP service lifecycle, tokens, audit log, and
/// currently unlocked vaults.
class McpService extends ChangeNotifier {
  McpService({
    required Directory dataDir,
    McpConsentCallback? onConsent,
    Prompter Function()? prompterFactory,
  }) : tokenStore = McpTokenStore(File('${dataDir.path}/mcp_tokens.json')),
       auditLog = McpAuditLog(file: File('${dataDir.path}/mcp_audit.jsonl')),
       executions = McpExecutionTracker(
         file: File('${dataDir.path}/mcp_executions.jsonl'),
       ) {
    registry = McpToolRegistry(
      tokenStore: tokenStore,
      auditLog: auditLog,
      vaultsProvider: () => List.unmodifiable(_vaults.values),
      executions: executions,
      onConsent: onConsent,
      prompterFactory: prompterFactory,
    );
    mcpServer = McpServer(registry);
    httpServer = McpHttpServer(mcpServer: mcpServer, tokenStore: tokenStore);
    tokenStore.addListener(notifyListeners);
    auditLog.addListener(notifyListeners);
    executions.addListener(notifyListeners);
  }

  final McpTokenStore tokenStore;
  final McpAuditLog auditLog;
  final McpExecutionTracker executions;
  late final McpToolRegistry registry;
  late final McpServer mcpServer;
  late final McpHttpServer httpServer;

  final Map<String, VaultSession> _vaults = {};
  String? lastError;

  bool get isRunning => httpServer.isRunning;
  int? get port => httpServer.port;
  List<VaultSession> get unlockedVaults => List.unmodifiable(_vaults.values);

  Future<void> init() async {
    await tokenStore.load();
    await auditLog.load();
    await executions.load();
  }

  void attachVault(VaultSession vault) {
    _vaults[vault.info.id] = vault;
    notifyListeners();
  }

  Future<void> detachVault(String vaultId) async {
    _vaults.remove(vaultId);
    await httpServer.disconnectAllSessions();
    notifyListeners();
  }

  Future<void> start({int port = 47832}) async {
    lastError = null;
    try {
      await httpServer.start(port: port);
    } catch (e) {
      lastError = e.toString();
    }
    notifyListeners();
  }

  Future<void> stop() async {
    lastError = null;
    await httpServer.stop();
    notifyListeners();
  }

  String clientConfigJson({int port = 47832, String? token}) {
    final activePort = this.port ?? port;
    return const JsonEncoder.withIndent('  ').convert({
      'mcpServers': {
        'marsa': {
          'url': 'http://127.0.0.1:$activePort/mcp',
          'headers': {
            'Authorization': 'Bearer ${token ?? '<YOUR_MARSA_AGENT_TOKEN>'}',
          },
        },
      },
    });
  }

  @override
  void dispose() {
    tokenStore.removeListener(notifyListeners);
    auditLog.removeListener(notifyListeners);
    httpServer.stop();
    super.dispose();
  }
}
