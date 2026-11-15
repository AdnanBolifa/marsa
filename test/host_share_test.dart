import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:marsa/core/crypto.dart';
import 'package:marsa/core/host_share.dart';
import 'package:marsa/core/models.dart';

final _fastKdf = KdfParams(
  salt: Uint8List.fromList(List.filled(16, 7)),
  memoryKib: 1024,
  iterations: 1,
);

void main() {
  VaultData sampleVault() {
    final data = VaultData();
    final key = SshKey(
      id: 'k1',
      label: 'deploy-key',
      publicKey: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyData comment',
      privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----\nSECRET\n-----END OPENSSH PRIVATE KEY-----',
    );
    data.keys.put(key);
    final jump = Host(
      id: 'h-jump',
      label: 'bastion',
      address: 'bastion.example.com',
      port: 2222,
      username: 'ops',
      password: 'jump-secret-password',
    );
    final app = Host(
      id: 'h-app',
      label: 'prod-app',
      address: '10.0.1.50',
      port: 22,
      username: 'deploy',
      password: 'app-secret-password',
      keyId: key.id,
      jumpHostId: jump.id,
      group: 'Production',
      tags: ['web', 'eu'],
    );
    data.hosts.put(jump);
    data.hosts.put(app);
    return data;
  }

  test('exportOpenSshConfig formats metadata without secrets', () {
    final data = sampleVault();
    final app = data.hosts['h-app']!;
    final cfg = exportOpenSshConfig(app, data);
    expect(cfg, contains('Host prod-app'));
    expect(cfg, contains('HostName 10.0.1.50'));
    expect(cfg, contains('User deploy'));
    expect(cfg, contains('ProxyJump bastion'));
    expect(cfg, isNot(contains('app-secret-password')));
    expect(cfg, isNot(contains('OPENSSH PRIVATE KEY')));
  });

  test('exportMetadataJson round-trips via parseSharedHost without secrets', () async {
    final data = sampleVault();
    final app = data.hosts['h-app']!;
    final raw = exportMetadataJson(app, data);
    expect(raw, isNot(contains('app-secret-password')));
    expect(raw, isNot(contains('OPENSSH PRIVATE KEY')));

    final bundle = await parseSharedHost(raw);
    expect(bundle.encrypted, isFalse);
    expect(bundle.missingJumpHost, isTrue);
    expect(bundle.hosts, hasLength(1));
    final imported = bundle.hosts.single;
    expect(imported.label, 'prod-app');
    expect(imported.address, '10.0.1.50');
    expect(imported.username, 'deploy');
    expect(imported.password, isEmpty);
    expect(imported.group, 'Production');
    expect(imported.tags, ['web', 'eu']);
  });

  test('exportEncryptedBundle round-trips credentials, keys, and jump host', () async {
    final data = sampleVault();
    final app = data.hosts['h-app']!;
    final link = await exportEncryptedBundle(
      app,
      data,
      'share-pass-123',
      includeCredentials: true,
      includeJumpHosts: true,
      kdf: _fastKdf,
    );
    expect(link, startsWith('marsa://host/'));

    final bundle = await parseSharedHost(
      link,
      askPassphrase: () async => 'share-pass-123',
    );
    expect(bundle.encrypted, isTrue);
    expect(bundle.missingJumpHost, isFalse);
    expect(bundle.hosts, hasLength(2));
    expect(bundle.keys, hasLength(1));
    expect(bundle.keys.single.label, 'deploy-key');
    expect(bundle.keys.single.privateKey, contains('SECRET'));

    final importedJump = bundle.hosts.firstWhere((h) => h.label == 'bastion');
    final importedApp = bundle.hosts.firstWhere((h) => h.label == 'prod-app');
    expect(importedApp.password, 'app-secret-password');
    expect(importedApp.keyId, bundle.keys.single.id);
    expect(importedApp.jumpHostId, importedJump.id);
  });

  test('parseSharedHost rejects wrong passphrase', () async {
    final data = sampleVault();
    final link = await exportEncryptedBundle(
      data.hosts['h-app']!,
      data,
      'correct-pass',
      kdf: _fastKdf,
    );
    await expectLater(
      parseSharedHost(link, askPassphrase: () async => 'wrong-pass'),
      throwsA(isA<HostShareError>()),
    );
  });

  test('exportEncryptedBundle without jump hosts flags missingJumpHost', () async {
    final data = sampleVault();
    final link = await exportEncryptedBundle(
      data.hosts['h-app']!,
      data,
      'share-pass-123',
      includeCredentials: false,
      includeJumpHosts: false,
      kdf: _fastKdf,
    );
    final bundle = await parseSharedHost(
      link,
      askPassphrase: () async => 'share-pass-123',
    );
    expect(bundle.missingJumpHost, isTrue);
    expect(bundle.hosts, hasLength(1));
    expect(bundle.hosts.single.password, isEmpty);
    expect(bundle.keys, isEmpty);
  });
}
