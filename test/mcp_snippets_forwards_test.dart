import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marsa/core/models.dart';
import 'package:marsa/core/vault.dart';
import 'package:marsa/mcp/audit.dart';
import 'package:marsa/mcp/auth.dart';
import 'package:marsa/mcp/tools.dart';

void main() {
  late Directory dir;
  late VaultSession vault;
  late Host host;
  late McpTokenStore tokenStore;
  late McpAuditLog auditLog;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('marsa_mcp_sf_');
    final registry = VaultRegistry(dir);
    await registry.load();
    vault = await registry.create('Work', 'pass1234');
    host = Host(label: 'app-1', address: '10.0.0.10', username: 'deploy');
    vault.data.hosts.put(host);
    await vault.commit();

    tokenStore = McpTokenStore(File('${dir.path}/tokens.json'));
    auditLog = McpAuditLog(file: File('${dir.path}/audit.jsonl'));
  });

  tearDown(() => dir.deleteSync(recursive: true));

  Map<String, dynamic> decodeResult(Map<String, dynamic> raw) {
    final content = raw['content'] as List;
    final text = (content.first as Map)['text'] as String;
    return jsonDecode(text) as Map<String, dynamic>;
  }

  test('create_snippet persists snippet and list_snippets returns it', () async {
    final (writer, _) = await tokenStore.createToken(
      name: 'Writer',
      tier: McpPermissionTier.sftpWrite,
      requireApproval: false,
    );
    final registry = McpToolRegistry(
      tokenStore: tokenStore,
      auditLog: auditLog,
      vaultsProvider: () => [vault],
    );

    final res = await registry.callTool('create_snippet', {
      'label': 'Disk usage',
      'command': 'df -h',
    }, writer);
    expect(res['isError'], isNot(true));
    final body = decodeResult(res);
    expect(body['label'], 'Disk usage');
    expect(body['command'], 'df -h');
    expect(vault.data.snippets.all, hasLength(1));

    final listRes = await registry.callTool('list_snippets', {}, writer);
    final listBody = decodeResult(listRes);
    expect((listBody['snippets'] as List), hasLength(1));
  });

  test('create_port_forward supports local, remote, and dynamic rules', () async {
    final (writer, _) = await tokenStore.createToken(
      name: 'Writer',
      tier: McpPermissionTier.sftpWrite,
      requireApproval: false,
    );
    final registry = McpToolRegistry(
      tokenStore: tokenStore,
      auditLog: auditLog,
      vaultsProvider: () => [vault],
    );

    final localRes = await registry.callTool('create_port_forward', {
      'hostId': host.id,
      'label': 'Postgres',
      'kind': 'local',
      'bindPort': 5433,
      'destPort': 5432,
    }, writer);
    expect(localRes['isError'], isNot(true));

    final remoteRes = await registry.callTool('create_port_forward', {
      'hostId': host.id,
      'label': 'Webhook',
      'kind': 'remote',
      'bindPort': 8080,
      'destPort': 3000,
    }, writer);
    expect(remoteRes['isError'], isNot(true));

    final dynRes = await registry.callTool('create_port_forward', {
      'hostId': host.id,
      'label': 'SOCKS',
      'kind': 'dynamic',
      'bindPort': 1080,
    }, writer);
    expect(dynRes['isError'], isNot(true));
    expect(vault.data.forwards.all, hasLength(3));

    final listRes = await registry.callTool('list_port_forwards', {}, writer);
    final listBody = decodeResult(listRes);
    expect((listBody['forwards'] as List), hasLength(3));
  });

  test('validates ports, tier permissions, and consent denial', () async {
    final (readOnly, _) = await tokenStore.createToken(
      name: 'Reader',
      tier: McpPermissionTier.discover,
      requireApproval: false,
    );
    final (writer, _) = await tokenStore.createToken(
      name: 'Writer',
      tier: McpPermissionTier.sftpWrite,
      requireApproval: true,
    );

    final registry = McpToolRegistry(
      tokenStore: tokenStore,
      auditLog: auditLog,
      vaultsProvider: () => [vault],
      onConsent: (_) async => false,
    );

    await expectLater(
      registry.callTool('create_snippet', {
        'label': 'x',
        'command': 'ls',
      }, readOnly),
      throwsA(isA<McpToolError>()),
    );

    await expectLater(
      registry.callTool('create_port_forward', {
        'hostId': host.id,
        'bindPort': 70000,
        'destPort': 80,
      }, writer),
      throwsA(isA<McpToolError>()),
    );

    await expectLater(
      registry.callTool('create_snippet', {
        'label': 'x',
        'command': 'ls',
      }, writer),
      throwsA(isA<McpToolError>()),
    );
    expect(vault.data.snippets.all, isEmpty);
  });
}
