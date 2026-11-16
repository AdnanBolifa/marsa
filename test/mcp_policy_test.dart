import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marsa/core/vault.dart';
import 'package:marsa/mcp/audit.dart';
import 'package:marsa/mcp/auth.dart';
import 'package:marsa/mcp/tools.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('marsa_policy_');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('McpAgentToken migrates legacy requireApproval and persists policy', () {
    final legacyAsk = McpAgentToken.fromJson({
      'id': 't1',
      'name': 'OldAsk',
      'tokenHash': 'abc',
      'requireApproval': true,
      'createdAt': 1,
    });
    expect(legacyAsk.executionPolicy, McpExecutionPolicy.ask);

    final legacyAuto = McpAgentToken.fromJson({
      'id': 't2',
      'name': 'OldAuto',
      'tokenHash': 'def',
      'requireApproval': false,
      'createdAt': 2,
    });
    expect(legacyAuto.executionPolicy, McpExecutionPolicy.autoApprove);

    final explicitDeny = McpAgentToken.fromJson({
      'id': 't3',
      'name': 'Denied',
      'tokenHash': 'ghi',
      'executionPolicy': 'deny',
      'createdAt': 3,
    });
    expect(explicitDeny.executionPolicy, McpExecutionPolicy.deny);
    expect(explicitDeny.toJson()['executionPolicy'], 'deny');
  });

  test('McpTokenStore.updateToken renames token and updates policy', () async {
    final file = File('${dir.path}/tokens.json');
    final store = McpTokenStore(file);
    final (tk, _) = await store.createToken(
      name: 'Initial',
      tier: McpPermissionTier.discover,
      executionPolicy: McpExecutionPolicy.ask,
    );

    await store.updateToken(
      tk.id,
      name: 'Claude Desktop',
      tier: McpPermissionTier.sshExec,
      executionPolicy: McpExecutionPolicy.deny,
    );

    final reloaded = McpTokenStore(file);
    await reloaded.load();
    expect(reloaded.tokens, hasLength(1));
    expect(reloaded.tokens.single.name, 'Claude Desktop');
    expect(reloaded.tokens.single.tier, McpPermissionTier.sshExec);
    expect(reloaded.tokens.single.executionPolicy, McpExecutionPolicy.deny);
  });

  test('McpToolRegistry enforces deny, ask, and autoApprove policies', () async {
    final registry = VaultRegistry(dir);
    await registry.load();
    final vault = await registry.create('Work', 'pass1234');
    final tokenStore = McpTokenStore(File('${dir.path}/tokens.json'));
    final auditLog = McpAuditLog(file: File('${dir.path}/audit.jsonl'));

    final (denyTok, _) = await tokenStore.createToken(
      name: 'DenyAgent',
      tier: McpPermissionTier.sshExec,
      executionPolicy: McpExecutionPolicy.deny,
    );
    final (askTok, _) = await tokenStore.createToken(
      name: 'AskAgent',
      tier: McpPermissionTier.sshExec,
      executionPolicy: McpExecutionPolicy.ask,
    );
    final (autoTok, _) = await tokenStore.createToken(
      name: 'AutoAgent',
      tier: McpPermissionTier.sshExec,
      executionPolicy: McpExecutionPolicy.autoApprove,
    );

    var consentCalls = 0;
    final tools = McpToolRegistry(
      tokenStore: tokenStore,
      auditLog: auditLog,
      vaultsProvider: () => [vault],
      onConsent: (_) async {
        consentCalls++;
        return true;
      },
    );

    // 1. deny rejects immediately without prompting
    await expectLater(
      tools.callTool('create_snippet', {'label': 'a', 'command': 'ls'}, denyTok),
      throwsA(
        isA<McpToolError>().having((e) => e.code, 'code', 'POLICY_DENIED'),
      ),
    );
    expect(consentCalls, 0);

    // 2. ask prompts once and succeeds when approved
    final askRes = await tools.callTool(
      'create_snippet',
      {'label': 'b', 'command': 'pwd'},
      askTok,
    );
    expect(consentCalls, 1);
    expect(jsonDecode((askRes['content'] as List).first['text'])['label'], 'b');

    // 3. autoApprove succeeds without prompting
    final autoRes = await tools.callTool(
      'create_snippet',
      {'label': 'c', 'command': 'id'},
      autoTok,
    );
    expect(consentCalls, 1);
    expect(jsonDecode((autoRes['content'] as List).first['text'])['label'], 'c');
  });
}
