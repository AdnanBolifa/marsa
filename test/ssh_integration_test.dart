// End-to-end checks against a real OpenSSH server. The test starts its own
// unprivileged `sshd` on a loopback port inside a temp directory, so it needs
// no account setup and touches nothing in ~/.ssh. It is skipped where sshd is
// not installed (for example on Windows CI).
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marsa/core/models.dart';
import 'package:marsa/core/sync.dart';
import 'package:marsa/core/vault.dart';
import 'package:marsa/ssh/connector.dart';
import 'package:marsa/ssh/device_keys.dart';
import 'package:marsa/ssh/files.dart';
import 'package:marsa/ssh/forwarding.dart';
import 'package:marsa/ssh/keys.dart';
import 'package:marsa/ssh/sessions.dart';

class _Ui implements Prompter {
  int newHosts = 0;
  int changedHosts = 0;
  bool acceptChanged = false;

  @override
  Future<bool> confirmNewHost(String h, String t, String f) async {
    newHosts++;
    return true;
  }

  @override
  Future<bool> confirmChangedHost(
    String h,
    String t,
    String o,
    String f,
  ) async {
    changedHosts++;
    return acceptChanged;
  }

  @override
  Future<String?> askSecret(String title, String prompt) async {
    secretsAsked++;
    return secret;
  }

  int secretsAsked = 0;
  String? secret;

  @override
  Future<List<String>?> askInteractive(
    String t,
    String i,
    List<SSHUserInfoPrompt> p,
  ) async => null;
}

const _sshd = '/usr/sbin/sshd';

void main() {
  final available = File(_sshd).existsSync();
  late Directory tmp;
  late Process server;
  late int port;
  late String user;
  late VaultSession vault;
  late Host host;
  late _Ui ui;
  final authorized = <String>[];

  Future<void> authorize(SshKey key) async {
    authorized.add(key.publicKey);
    await File(
      '${tmp.path}/authorized_keys',
    ).writeAsString('${authorized.join('\n')}\n');
  }

  setUpAll(() async {
    if (!available) return;
    tmp = await Directory.systemTemp.createTemp('marsa_sshd');
    user = Platform.environment['USER']!;
    final probe = await ServerSocket.bind('127.0.0.1', 0);
    port = probe.port;
    await probe.close();
    await Process.run('ssh-keygen', [
      '-q',
      '-t',
      'ed25519',
      '-N',
      '',
      '-f',
      '${tmp.path}/hostkey',
    ]);
    await File('${tmp.path}/authorized_keys').writeAsString('');
    await Process.run('chmod', ['600', '${tmp.path}/authorized_keys']);
    server = await Process.start(_sshd, [
      '-D',
      '-e',
      '-f',
      '/dev/null',
      '-p',
      '$port',
      '-o',
      'ListenAddress=127.0.0.1',
      '-o',
      'HostKey=${tmp.path}/hostkey',
      '-o',
      'AuthorizedKeysFile=${tmp.path}/authorized_keys',
      '-o',
      'PidFile=${tmp.path}/sshd.pid',
      '-o',
      'UsePAM=no',
      '-o',
      'StrictModes=no',
      '-o',
      'PasswordAuthentication=no',
      '-o',
      'Subsystem=sftp internal-sftp',
    ]);
    server.stderr.drain<void>();
    for (var i = 0; i < 50; i++) {
      try {
        (await Socket.connect('127.0.0.1', port)).destroy();
        break;
      } on SocketException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    final reg = VaultRegistry(Directory('${tmp.path}/device-a'));
    await reg.load();
    vault = await reg.create('Test', 'password-1');
    final key = generateEd25519('laptop key');
    await authorize(key);
    vault.data.keys.put(key);
    host = Host(
      label: 'local',
      address: '127.0.0.1',
      port: port,
      username: user,
      keyId: key.id,
    );
    vault.data.hosts.put(host);
    await vault.commit();
    ui = _Ui();
  });

  tearDownAll(() async {
    if (!available) return;
    await vault.lock();
    server.kill();
    // sshd removes its pid file as it exits; deleting the folder before
    // then can trip over the file vanishing mid-delete.
    await server.exitCode;
    await tmp.delete(recursive: true);
  });

  final skip = available ? null : 'no $_sshd on this machine';

  test('connects with a generated Ed25519 key and pins the host key', () async {
    final conn = await connect(vault, host, ui);
    expect(
      utf8.decode(await conn.client.run('echo marsa-ok')).trim(),
      'marsa-ok',
    );
    conn.close();
    expect(ui.newHosts, 1);
    final pinned = vault.data.knownHosts['127.0.0.1:$port']!;
    expect(pinned.fingerprint, startsWith('SHA256:'));

    // Second connection: already trusted, nobody is asked.
    (await connect(vault, host, ui)).close();
    expect(ui.newHosts, 1);
  }, skip: skip);

  test('a changed host key is refused unless explicitly replaced', () async {
    final real = vault.data.knownHosts['127.0.0.1:$port']!.fingerprint;
    vault.data.knownHosts.put(
      KnownHost(
        id: '127.0.0.1:$port',
        type: 'ssh-ed25519',
        fingerprint: 'SHA256:old',
      ),
    );
    await expectLater(connect(vault, host, ui), throwsA(isA<ConnectError>()));
    expect(ui.changedHosts, 1);
    expect(vault.data.knownHosts['127.0.0.1:$port']!.fingerprint, 'SHA256:old');

    ui.acceptChanged = true;
    (await connect(vault, host, ui)).close();
    expect(vault.data.knownHosts['127.0.0.1:$port']!.fingerprint, real);
  }, skip: skip);

  test(
    'a wrong key fails cleanly and an identity supplies credentials',
    () async {
      final stranger = generateEd25519('stranger');
      vault.data.keys.put(stranger);
      final bad = Host(
        address: '127.0.0.1',
        port: port,
        username: user,
        keyId: stranger.id,
      );
      await expectLater(
        connect(vault, bad, ui),
        throwsA(
          isA<ConnectError>().having(
            (e) => e.message,
            'message',
            contains('Authentication failed'),
          ),
        ),
      );

      final ident = Identity(username: user, keyId: host.keyId);
      vault.data.identities.put(ident);
      final viaIdentity = Host(
        address: '127.0.0.1',
        port: port,
        username: 'ignored',
        identityId: ident.id,
      );
      (await connect(vault, viaIdentity, ui)).close();
    },
    skip: skip,
  );

  test(
    'generated RSA and imported passphrase-protected keys authenticate',
    () async {
      final rsa = await generateRsa('rsa key', bits: 2048);
      expect(rsa.type, 'ssh-rsa');
      await authorize(rsa);
      vault.data.keys.put(rsa);
      (await connect(
        vault,
        Host(address: '127.0.0.1', port: port, username: user, keyId: rsa.id),
        ui,
      )).close();

      final path = '${tmp.path}/protected';
      await Process.run('ssh-keygen', [
        '-q',
        '-t',
        'ed25519',
        '-N',
        'hunter22',
        '-a',
        '4',
        '-f',
        path,
      ]);
      final pem = await File(path).readAsString();
      expect(isEncryptedKey(pem), isTrue);
      await expectLater(importKey('p', pem, 'wrong'), throwsA(anything));
      final imported = await importKey('p', pem, 'hunter22');
      expect(isEncryptedKey(imported.privateKey), isFalse);
      expect(
        imported.publicKey.split(' ')[1],
        (await File('$path.pub').readAsString()).split(' ')[1],
      );
      // Our fingerprint must match what ssh-keygen prints for the same key.
      final fp = await Process.run('ssh-keygen', ['-lf', '$path.pub']);
      expect(fp.stdout as String, contains(fingerprintOf(imported.publicKey)));
      await authorize(imported);
      vault.data.keys.put(imported);
      (await connect(
        vault,
        Host(
          address: '127.0.0.1',
          port: port,
          username: user,
          keyId: imported.id,
        ),
        ui,
      )).close();
    },
    skip: skip,
  );

  test('signs in with the keys already on this device', () async {
    final home = Directory('${tmp.path}/dot-ssh')..createSync();
    DeviceKeys.directory = home;
    DeviceKeys.lock();
    final viaDevice = Host(
      address: '127.0.0.1',
      port: port,
      username: user,
      useDeviceKeys: true,
    );
    await expectLater(
      connect(vault, viaDevice, ui),
      throwsA(
        isA<ConnectError>().having(
          (e) => e.message,
          'message',
          contains('No usable SSH key'),
        ),
      ),
    );

    // An unrelated key first, then the authorized, passphrase-protected one.
    Future<void> keygen(String name, String type, String pass) => Process.run(
      'ssh-keygen',
      ['-q', '-t', type, '-N', pass, '-a', '4', '-f', '${home.path}/$name'],
    );
    await keygen('id_ed25519', 'ed25519', '');
    await keygen('id_rsa', 'rsa', 'open-sesame');
    File('${home.path}/known_hosts').writeAsStringSync('not a key');
    authorized.add(File('${home.path}/id_rsa.pub').readAsStringSync().trim());
    await File(
      '${tmp.path}/authorized_keys',
    ).writeAsString('${authorized.join('\n')}\n');
    expect(DeviceKeys.available, isTrue);

    // Passphrase prompt cancelled: only the unrelated key is tried.
    ui.secret = null;
    await expectLater(
      connect(vault, viaDevice, ui),
      throwsA(isA<ConnectError>()),
    );

    ui
      ..secret = 'open-sesame'
      ..secretsAsked = 0;
    (await connect(vault, viaDevice, ui)).close();
    expect(ui.secretsAsked, 1);
    // Unlocked for the session: no second prompt.
    (await connect(vault, viaDevice, ui)).close();
    expect(ui.secretsAsked, 1);
    // Nothing from ~/.ssh ends up in the vault.
    expect(
      vault.data.keys.all.any(
        (k) => k.type == 'ssh-rsa' && k.label != 'rsa key',
      ),
      isFalse,
    );

    DeviceKeys.lock();
    ui.secret = null;
  }, skip: skip);

  test('reaches a host through a jump host', () async {
    final inner = Host(
      address: '127.0.0.1',
      port: port,
      username: user,
      keyId: host.keyId,
      jumpHostId: host.id,
    );
    final conn = await connect(vault, inner, ui);
    expect(
      utf8.decode(await conn.client.run('echo via-jump')).trim(),
      'via-jump',
    );
    conn.close();

    final loop = Host(
      address: '127.0.0.1',
      port: port,
      username: user,
      keyId: host.keyId,
    );
    loop.jumpHostId = loop.id;
    vault.data.hosts.put(loop);
    await expectLater(connect(vault, loop, ui), throwsA(isA<ConnectError>()));
    vault.data.hosts.remove(loop.id);
  }, skip: skip);

  test('a terminal tab runs commands in an interactive shell', () async {
    final tab = TerminalTab(host, vault, ui);
    await tab.start();
    expect(tab.state, TabState.connected, reason: tab.error);
    tab.send('echo marsa-\$((6*7))\r');
    String screen() => [
      for (var i = 0; i < tab.terminal.buffer.lines.length; i++)
        tab.terminal.buffer.lines[i].toString(),
    ].join('\n');
    for (var i = 0; i < 100 && !screen().contains('marsa-42'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(screen(), contains('marsa-42'));
    tab.send('exit\r');
    for (var i = 0; i < 100 && tab.state != TabState.closed; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(tab.state, TabState.closed);
    tab.dispose();
  }, skip: skip);

  test('SFTP browsing, editing and two-way folder transfers', () async {
    final tab = SftpTab(host, vault, ui);
    await tab.start();
    expect(tab.state, TabState.connected, reason: tab.error);
    final remote = tab.remote!;
    final local = LocalFiles();
    expect(await remote.home(), startsWith('/'));

    final src = Directory('${tmp.path}/src')..createSync();
    Directory('${src.path}/tree/deep').createSync(recursive: true);
    File('${src.path}/tree/a.txt').writeAsStringSync('alpha');
    final big = List.generate(700000, (i) => i % 251);
    File('${src.path}/tree/deep/big.bin').writeAsBytesSync(big);
    final remoteRoot = '${tmp.path}/remote';
    await remote.mkdir(remoteRoot);

    final transfers = TransferManager();
    final tree = (await local.list(src.path)).single;
    expect(tree.isDir, isTrue);
    await transfers.copy(local, src.path, tree, remote, remoteRoot);
    expect(transfers.transfers.single.error, isNull);
    expect(transfers.transfers.single.bytes, 700005);

    final listed = await remote.list('$remoteRoot/tree');
    expect(listed.map((e) => e.name).toSet(), {'a.txt', 'deep'});
    expect(listed.firstWhere((e) => e.name == 'deep').isDir, isTrue);
    expect(File('$remoteRoot/tree/deep/big.bin').readAsBytesSync(), big);

    await remote.rename('$remoteRoot/tree/a.txt', '$remoteRoot/tree/b.txt');
    await remote.chmod('$remoteRoot/tree/b.txt', 0x180); // 600
    final b = (await remote.list(
      '$remoteRoot/tree',
    )).firstWhere((e) => e.name == 'b.txt');
    expect(b.mode, 0x180);
    expect(b.size, 5);

    final back = Directory('${tmp.path}/back')..createSync();
    await transfers.copy(
      remote,
      remoteRoot,
      (await remote.list(remoteRoot)).single,
      local,
      back.path,
    );
    expect(transfers.transfers.first.error, isNull);
    expect(File('${back.path}/tree/b.txt').readAsStringSync(), 'alpha');
    expect(File('${back.path}/tree/deep/big.bin').readAsBytesSync(), big);

    // Deleting a folder must not follow a symlink out of it.
    final outside = File('${tmp.path}/outside.txt')..writeAsStringSync('keep');
    Directory('${tmp.path}/outside-dir').createSync();
    File('${tmp.path}/outside-dir/keep.txt').writeAsStringSync('keep');
    Link('$remoteRoot/tree/link-to-dir').createSync('${tmp.path}/outside-dir');
    await remote.delete('$remoteRoot/tree', isDir: true);
    expect(Directory('$remoteRoot/tree').existsSync(), isFalse);
    expect(outside.existsSync(), isTrue);
    expect(File('${tmp.path}/outside-dir/keep.txt').existsSync(), isTrue);

    await expectLater(remote.list('$remoteRoot/nope'), throwsA(anything));

    // Server to server: point the first pane at a host too and copy across.
    expect(tab.sides[0].host, isNull);
    expect(tab.sides[0].files, isA<LocalFiles>());
    await tab.show(0, host);
    expect(tab.sides[0].state, TabState.connected, reason: tab.sides[0].error);
    final left = tab.sides[0].files!;
    expect(left, isNot(same(tab.sides[1].files)));
    Directory('${tmp.path}/srv-a/site').createSync(recursive: true);
    File('${tmp.path}/srv-a/site/index.html').writeAsStringSync('<h1>hi</h1>');
    Directory('${tmp.path}/srv-b').createSync();
    await transfers.copy(
      left,
      '${tmp.path}/srv-a',
      (await left.list('${tmp.path}/srv-a')).single,
      tab.sides[1].files!,
      '${tmp.path}/srv-b',
    );
    expect(transfers.transfers.first.error, isNull);
    expect(
      File('${tmp.path}/srv-b/site/index.html').readAsStringSync(),
      '<h1>hi</h1>',
    );

    // A pane that cannot connect fails by itself; the other keeps working.
    await tab.show(
      0,
      Host(address: '127.0.0.1', port: 1, username: user, useDeviceKeys: false),
    );
    expect(tab.sides[0].state, TabState.closed);
    expect(tab.sides[0].error, isNotNull);
    expect(tab.sides[1].state, TabState.connected);
    expect(tab.state, TabState.closed);
    await tab.show(0, null);
    expect(tab.state, TabState.connected);
    tab.dispose();
  }, skip: skip);

  test('local and dynamic port forwards carry traffic', () async {
    final echo = await ServerSocket.bind('127.0.0.1', 0);
    echo.listen((s) => s.listen((d) => s.add([...utf8.encode('echo:'), ...d])));
    final free = await ServerSocket.bind('127.0.0.1', 0);
    final listenPort = free.port;
    await free.close();

    final manager = ForwardManager(vault, ui);
    final rule = PortForward(
      kind: ForwardKind.local,
      hostId: host.id,
      bindPort: listenPort,
      destPort: echo.port,
    );
    await manager.start(rule);
    expect(manager.stateOf(rule.id)!.error, isNull);
    expect(manager.isOn(rule.id), isTrue);

    final s = await Socket.connect('127.0.0.1', listenPort);
    s.add(utf8.encode('ping'));
    final reply = await s.first.timeout(const Duration(seconds: 10));
    expect(utf8.decode(reply), 'echo:ping');
    s.destroy();

    await manager.stop(rule.id);
    await expectLater(
      Socket.connect('127.0.0.1', listenPort),
      throwsA(isA<SocketException>()),
    );

    // SOCKS5 through the dynamic forward: greet, CONNECT to the echo server.
    final socks = PortForward(
      kind: ForwardKind.dynamic,
      hostId: host.id,
      bindPort: listenPort,
    );
    await manager.start(socks);
    expect(manager.stateOf(socks.id)!.error, isNull);
    final p = await Socket.connect('127.0.0.1', listenPort);
    final replies = StreamIterator(p);
    p.add([5, 1, 0]);
    expect(await replies.moveNext(), isTrue);
    expect(replies.current, [5, 0]);
    p.add([5, 1, 0, 1, 127, 0, 0, 1, echo.port >> 8, echo.port & 0xFF]);
    expect(await replies.moveNext(), isTrue);
    expect(replies.current.sublist(0, 2), [5, 0]);
    p.add(utf8.encode('socks'));
    expect(await replies.moveNext(), isTrue);
    expect(utf8.decode(replies.current), 'echo:socks');
    p.destroy();
    await manager.stop(socks.id);

    final gone = PortForward(hostId: 'missing', bindPort: listenPort);
    await manager.start(gone);
    expect(manager.stateOf(gone.id)!.error, isNotNull);
    await manager.stopAll();
    await echo.close();
  }, skip: skip);

  test('two devices sync a vault through the server over SFTP', () async {
    SyncConfig target() => SyncConfig(
      type: SyncConfig.sftp,
      path: '${tmp.path}/synced/team/vault.marsa',
      host: '127.0.0.1',
      port: port,
      username: user,
      privateKey: vault.data.keys[host.keyId]!.privateKey,
    );
    await vault.setSync(target());
    expect(vault.syncState, SyncState.idle, reason: vault.syncError);
    expect(vault.sync!.fingerprint, startsWith('SHA256:'));
    final stored = File(
      '${tmp.path}/synced/team/vault.marsa',
    ).readAsStringSync();
    expect(stored.contains('PRIVATE KEY'), isFalse);
    expect(stored.contains(user), isFalse);

    final regB = VaultRegistry(Directory('${tmp.path}/device-b'));
    await regB.load();
    final b = await regB.join('Test', 'password-1', target());
    expect(b.data.hosts[host.id]!.address, '127.0.0.1');
    expect(
      b.data.keys[host.keyId]!.privateKey,
      vault.data.keys[host.keyId]!.privateKey,
    );

    b.data.snippets.put(Snippet(label: 'disk', command: 'df -h'));
    await b.syncNow();
    expect(b.syncState, SyncState.idle, reason: b.syncError);
    await vault.syncNow();
    expect(vault.data.snippets.all.single.command, 'df -h');

    // Logging in to the sync server with the device's own keys.
    final home = Directory('${tmp.path}/sync-dot-ssh')..createSync();
    DeviceKeys.directory = home;
    DeviceKeys.lock();
    SyncConfig viaDevice() => SyncConfig(
      type: SyncConfig.sftp,
      path: '${tmp.path}/synced/team/vault.marsa',
      host: '127.0.0.1',
      port: port,
      username: user,
      deviceKeys: true,
    );
    await vault.setSync(viaDevice());
    expect(vault.syncState, SyncState.error);
    expect(vault.syncError, contains('No usable SSH key'));
    File(
      '${home.path}/id_ed25519',
    ).writeAsStringSync(vault.data.keys[host.keyId]!.privateKey);
    await vault.setSync(viaDevice());
    expect(vault.syncState, SyncState.idle, reason: vault.syncError);
    expect(vault.sync!.privateKey, isEmpty);

    // A sync server presenting a different key stops the sync.
    b.sync!.fingerprint = 'SHA256:somebody-else';
    await b.syncNow();
    expect(b.syncState, SyncState.error);
    expect(b.syncError, contains('host key changed'));
    await b.lock();
    await vault.setSync(null);
  }, skip: skip);
}
