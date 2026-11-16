import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marsa/core/models.dart';
import 'package:marsa/core/vault.dart';
import 'package:marsa/mcp/auth.dart';
import 'package:marsa/mcp/mcp_service.dart';
import 'package:marsa/mcp/tools.dart';
import 'package:marsa/ssh/file_sync.dart';
import 'package:marsa/ssh/files.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('marsa_sync_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('planSync & executeSync copy new/updated files, skip excluded, and delete extras', () async {
    final srcDir = Directory('${tmp.path}/src')..createSync(recursive: true);
    final dstDir = Directory('${tmp.path}/dst')..createSync(recursive: true);

    File('${srcDir.path}/keep.txt').writeAsStringSync('hello');
    Directory('${srcDir.path}/sub').createSync();
    File('${srcDir.path}/sub/app.dart').writeAsStringSync('void main() {}');
    Directory('${srcDir.path}/.git').createSync();
    File('${srcDir.path}/.git/HEAD').writeAsStringSync('ref: main');
    File('${srcDir.path}/debug.log').writeAsStringSync('ignored');

    File('${dstDir.path}/extra.txt').writeAsStringSync('stale');

    final local = LocalFiles();
    final plan1 = await planSync(
      local,
      srcDir.path,
      local,
      dstDir.path,
      options: const SyncOptions(exclude: ['.git', '*.log'], delete: false),
    );
    expect(plan1.newCount, 2);
    expect(plan1.updateCount, 0);
    expect(plan1.deleteCount, 0);

    final res1 = await executeSync(local, local, plan1);
    expect(res1.copiedCount, 2);
    expect(File('${dstDir.path}/keep.txt').readAsStringSync(), 'hello');
    expect(File('${dstDir.path}/sub/app.dart').readAsStringSync(), 'void main() {}');
    expect(Directory('${dstDir.path}/.git').existsSync(), isFalse);
    expect(File('${dstDir.path}/debug.log').existsSync(), isFalse);
    expect(File('${dstDir.path}/extra.txt').existsSync(), isTrue);

    // Modify one file in src and run with delete: true
    File('${srcDir.path}/keep.txt').writeAsStringSync('hello world!');
    final plan2 = await planSync(
      local,
      srcDir.path,
      local,
      dstDir.path,
      options: const SyncOptions(exclude: ['.git', '*.log'], delete: true),
    );
    expect(plan2.newCount, 0);
    expect(plan2.updateCount, 1);
    expect(plan2.deleteCount, 1);

    final res2 = await executeSync(local, local, plan2);
    expect(res2.copiedCount, 1);
    expect(res2.deletedCount, 1);
    expect(File('${dstDir.path}/keep.txt').readAsStringSync(), 'hello world!');
    expect(File('${dstDir.path}/extra.txt').existsSync(), isFalse);
  });

  test('sftp_sync enforces allowedLocalPaths, blocks .ssh, and checks tier', () async {
    final reg = VaultRegistry(Directory('${tmp.path}/vaults'));
    await reg.load();
    final vault = await reg.create('Sync Vault', 'pass');
    vault.data.hosts.put(
      Host(
        id: 'h1',
        label: 'Test Server',
        address: '127.0.0.1',
        username: 'user',
        password: 'secret',
      ),
    );

    final allowedDir = Directory('${tmp.path}/allowed')..createSync();
    final blockedDir = Directory('${tmp.path}/blocked')..createSync();
    final sshDir = Directory('${tmp.path}/.ssh')..createSync();

    final service = McpService(dataDir: tmp);
    await service.init();
    service.attachVault(vault);

    final (readAgent, _) = await service.tokenStore.createToken(
      name: 'Read Agent',
      tier: McpPermissionTier.sftpRead,
      allowedLocalPaths: [allowedDir.path, sshDir.path],
      requireApproval: false,
    );

    // Path allowlist checks
    expect(
      service.tokenStore.isLocalPathAllowed(readAgent, allowedDir.path),
      isTrue,
    );
    expect(
      service.tokenStore.isLocalPathAllowed(readAgent, blockedDir.path),
      isFalse,
    );
    expect(
      service.tokenStore.isLocalPathAllowed(readAgent, sshDir.path),
      isFalse,
    );

    // Push requires sftpWrite when dryRun is false
    await expectLater(
      service.registry.callTool(
        'sftp_sync',
        {
          'hostId': 'h1',
          'direction': 'push',
          'localPath': allowedDir.path,
          'remotePath': '/tmp/app',
        },
        readAgent,
      ),
      throwsA(
        isA<McpToolError>().having((e) => e.code, 'code', 'PERMISSION_DENIED'),
      ),
    );
  });
}
