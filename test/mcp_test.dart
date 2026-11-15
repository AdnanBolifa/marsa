import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marsa/core/models.dart';
import 'package:marsa/core/vault.dart';
import 'package:marsa/mcp/audit.dart';
import 'package:marsa/mcp/auth.dart';
import 'package:marsa/mcp/mcp_server.dart';
import 'package:marsa/mcp/mcp_service.dart';
import 'package:marsa/mcp/tools.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('marsa_mcp_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<VaultSession> openTestVault() async {
    final reg = VaultRegistry(Directory('${tmp.path}/vaults'));
    await reg.load();
    final session = await reg.create('Test Vault', 'test-passphrase');
    session.data.keys.put(
      SshKey(
        id: 'key-1',
        label: 'Prod Key',
        privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----\nSECRET_KEY_MATERIAL\n-----END OPENSSH PRIVATE KEY-----',
        publicKey: 'ssh-ed25519 AAAA...',
        type: 'ed25519',
      ),
    );
    session.data.identities.put(
      Identity(
        id: 'id-1',
        label: 'Deploy Identity',
        username: 'deploy',
        password: 'SUPER_SECRET_IDENTITY_PASSWORD',
        keyId: 'key-1',
      ),
    );
    session.data.hosts.put(
      Host(
        id: 'host-1',
        label: 'Prod Web',
        address: '10.0.0.10',
        port: 2222,
        username: 'ubuntu',
        password: 'SUPER_SECRET_HOST_PASSWORD',
        identityId: 'id-1',
        group: 'production',
        tags: ['web', 'linux'],
      ),
    );
    session.data.hosts.put(
      Host(
        id: 'host-2',
        label: 'Staging DB',
        address: '10.0.1.20',
        username: 'postgres',
        password: 'STAGING_SECRET_PASSWORD',
        group: 'staging',
        tags: ['db'],
      ),
    );
    session.data.snippets.put(
      Snippet(id: 'snip-1', label: 'Disk usage', command: 'df -h'),
    );
    await session.commit();
    return session;
  }

  test('token store creates, authenticates, persists, and revokes tokens', () async {
    final file = File('${tmp.path}/mcp_tokens.json');
    final store = McpTokenStore(file);
    await store.load();

    final (profile, rawToken) = await store.createToken(
      name: 'Cursor',
      tier: McpPermissionTier.sftpRead,
      allowedGroups: ['production'],
    );
    expect(rawToken, startsWith('marsa_'));
    expect(store.authenticate(rawToken)?.id, profile.id);
    expect(store.authenticate('wrong_token'), isNull);

    // Reload from disk and verify hash-only persistence works.
    final reloaded = McpTokenStore(file);
    await reloaded.load();
    expect(reloaded.authenticate(rawToken)?.name, 'Cursor');
    expect(await file.readAsString(), isNot(contains(rawToken)));

    await reloaded.revoke(profile.id);
    expect(reloaded.authenticate(rawToken), isNull);
  });

  test('discovery tools strip all secrets and respect host/group allowlists', () async {
    final vault = await openTestVault();
    final service = McpService(dataDir: tmp);
    await service.init();
    service.attachVault(vault);

    final (agent, _) = await service.tokenStore.createToken(
      name: 'Prod Reader',
      tier: McpPermissionTier.discover,
      allowedGroups: ['production'],
      requireApproval: false,
    );

    final res = await service.registry.callTool('list_hosts', const {}, agent);
    final text = (res['content'] as List).first['text'] as String;
    expect(text, contains('Prod Web'));
    expect(text, isNot(contains('Staging DB')));
    expect(text, isNot(contains('SUPER_SECRET_HOST_PASSWORD')));
    expect(text, isNot(contains('SUPER_SECRET_IDENTITY_PASSWORD')));
    expect(text, isNot(contains('SECRET_KEY_MATERIAL')));

    final idsRes = await service.registry.callTool(
      'list_identities',
      const {},
      agent,
    );
    final idsText = (idsRes['content'] as List).first['text'] as String;
    expect(idsText, contains('Deploy Identity'));
    expect(idsText, isNot(contains('SUPER_SECRET_IDENTITY_PASSWORD')));

    // Permission tier blocks ssh_exec for discover-only token.
    await expectLater(
      service.registry.callTool(
        'ssh_exec',
        {'hostId': 'host-1', 'command': 'uname -a'},
        agent,
      ),
      throwsA(
        isA<McpToolError>().having((e) => e.code, 'code', 'PERMISSION_DENIED'),
      ),
    );
  });

  test('consent flow blocks execution when denied and vault lock returns VAULT_LOCKED', () async {
    final vault = await openTestVault();
    var consentAsked = false;
    final service = McpService(
      dataDir: tmp,
      onConsent: (req) async {
        consentAsked = true;
        return false;
      },
    );
    await service.init();
    service.attachVault(vault);

    final (agent, _) = await service.tokenStore.createToken(
      name: 'Exec Agent',
      tier: McpPermissionTier.sshExec,
      requireApproval: true,
    );

    await expectLater(
      service.registry.callTool(
        'ssh_exec',
        {'hostId': 'host-1', 'command': 'ls'},
        agent,
      ),
      throwsA(
        isA<McpToolError>().having((e) => e.code, 'code', 'CONSENT_DENIED'),
      ),
    );
    expect(consentAsked, isTrue);
    expect(service.auditLog.entries.last.status, McpAuditStatus.denied);

    // Detaching (locking) the vault blocks all vault-backed calls.
    await service.detachVault(vault.info.id);
    await expectLater(
      service.registry.callTool('list_hosts', const {}, agent),
      throwsA(
        isA<McpToolError>().having((e) => e.code, 'code', 'VAULT_LOCKED'),
      ),
    );
  });

  test('HTTP transport enforces auth, Host header, and handles MCP JSON-RPC', () async {
    final vault = await openTestVault();
    final service = McpService(dataDir: tmp);
    await service.init();
    service.attachVault(vault);

    final (_, rawToken) = await service.tokenStore.createToken(
      name: 'Antigravity',
      tier: McpPermissionTier.discover,
      requireApproval: false,
    );

    await service.start(port: 0);
    final port = service.port!;
    addTearDown(service.stop);

    final client = HttpClient();
    addTearDown(client.close);

    // 1. Unauthenticated /mcp -> 401
    final unauthReq = await client.post('127.0.0.1', port, '/mcp');
    unauthReq.write(jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}));
    final unauthRes = await unauthReq.close();
    expect(unauthRes.statusCode, HttpStatus.unauthorized);
    await unauthRes.drain<void>();

    // 2. DNS-rebinding Host header -> 403
    final rebindReq = await client.get('127.0.0.1', port, '/health');
    rebindReq.headers.set(HttpHeaders.hostHeader, 'evil.example.com:$port');
    final rebindRes = await rebindReq.close();
    expect(rebindRes.statusCode, HttpStatus.forbidden);
    await rebindRes.drain<void>();

    // 3. Valid initialize + tools/list + resources/read
    Future<Map<String, dynamic>> rpc(Map<String, dynamic> payload) async {
      final req = await client.post('127.0.0.1', port, '/mcp');
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $rawToken');
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(payload));
      final res = await req.close();
      expect(res.statusCode, HttpStatus.ok);
      return jsonDecode(await utf8.decoder.bind(res).join())
          as Map<String, dynamic>;
    }

    final init = await rpc({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'});
    expect(init['result']['protocolVersion'], McpServer.protocolVersion);
    expect(init['result']['serverInfo']['name'], 'marsa-mcp');

    final tools = await rpc({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'});
    final toolNames = (tools['result']['tools'] as List)
        .map((t) => t['name'])
        .toList();
    expect(toolNames, containsAll(['list_hosts', 'get_host', 'list_snippets']));
    expect(toolNames, isNot(contains('ssh_exec')));

    final snippets = await rpc({
      'jsonrpc': '2.0',
      'id': 3,
      'method': 'resources/read',
      'params': {'uri': 'marsa://snippets'},
    });
    final snipText = snippets['result']['contents'][0]['text'] as String;
    expect(snipText, contains('df -h'));
  });
}
