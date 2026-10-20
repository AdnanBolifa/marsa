// Each device signing in with its own key, against a real OpenSSH server
// started for the test (skipped where sshd is not installed). The server
// reads a temp authorized_keys file, which is also what Marsa edits, so
// nothing in ~/.ssh is touched.
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marsa/core/models.dart';
import 'package:marsa/core/sync.dart';
import 'package:marsa/core/vault.dart';
import 'package:marsa/ssh/connector.dart';
import 'package:marsa/ssh/device_access.dart';
import 'package:marsa/ssh/device_identity.dart';
import 'package:marsa/ssh/device_keys.dart';
import 'package:marsa/ssh/keys.dart';

class _Ui implements Prompter {
  @override
  Future<bool> confirmNewHost(String h, String t, String f) async => true;
  @override
  Future<bool> confirmChangedHost(
    String h,
    String t,
    String o,
    String f,
  ) async => false;
  @override
  Future<String?> askSecret(String title, String prompt) async => null;
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
  late File authorized;

  setUpAll(() async {
    if (!available) return;
    tmp = await Directory.systemTemp.createTemp('marsa_devices');
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
    authorized = File('${tmp.path}/authorized_keys')..writeAsStringSync('');
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
      'AuthorizedKeysFile=${authorized.path}',
      '-o',
      'PidFile=${tmp.path}/sshd.pid',
      '-o',
      'UsePAM=no',
      '-o',
      'StrictModes=no',
      '-o',
      'PasswordAuthentication=no',
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
  });

  tearDownAll(() async {
    if (!available) return;
    server.kill();
    await server.exitCode;
    DeviceIdentity.current = null;
    await tmp.delete(recursive: true);
  });

  test(
    'a new device is let in once approved, and out again when removed',
    () async {
      final user = Platform.environment['USER']!;
      final keys = AuthorizedKeys(authorized.path);
      final shared = SyncConfig(
        type: SyncConfig.folder,
        path: '${tmp.path}/cloud/team.marsa',
      );
      Future<VaultRegistry> registry(String name) async {
        final r = VaultRegistry(Directory('${tmp.path}/$name/vaults'));
        await r.load();
        return r;
      }

      // The Mac: it had the vault before device keys existed, and reaches
      // the server with a key from the vault.
      final macId = (await DeviceIdentity.load(
        FileSecretStore(Directory('${tmp.path}/mac')),
        name: 'MacBook',
      ))!;
      final mac = await (await registry('mac')).create('Team', 'password-1');
      final bootstrap = generateEd25519('old key');
      authorized.writeAsStringSync('${bootstrap.publicKey}\n');
      mac.data.keys.put(bootstrap);
      final host = Host(
        label: 'vps',
        address: '127.0.0.1',
        port: port,
        username: user,
        keyId: bootstrap.id,
      );
      mac.data.hosts.put(host);
      await mac.setSync(shared);
      await connect(mac, host, _Ui()).then((c) => c.close()); // pin the key

      DeviceIdentity.current = macId;
      final macAccess = DeviceAccess(mac, macId, keys: keys);
      await macAccess.register();
      expect(macAccess.trusted, isTrue);
      await macAccess.run();
      expect(
        macAccess.installedOn(macId.id),
        1,
        reason: '${macAccess.problems}',
      );
      expect(authorized.readAsStringSync(), contains(macId.blob));

      // From now on the server only knows device keys.
      mac.data.hosts.put(host..keyId = null);
      mac.data.keys.remove(bootstrap.id);
      await mac.commit();
      authorized.writeAsStringSync(
        authorized
            .readAsLinesSync()
            .where((l) => !l.contains(bootstrap.publicKey.split(' ')[1]))
            .join('\n'),
      );
      // Still in, with its own key; the file has no trailing newline now.
      await connect(mac, host, _Ui()).then((c) => c.close());
      await mac.syncNow();

      // A new PC joins the vault: it asks to be let in and cannot connect.
      final pcId = (await DeviceIdentity.load(
        FileSecretStore(Directory('${tmp.path}/pc')),
        name: 'Gaming PC',
      ))!;
      expect(pcId.id, isNot(macId.id));
      final pc = await (await registry(
        'pc',
      )).join('Team', 'password-1', shared);
      DeviceIdentity.current = pcId;
      final pcAccess = DeviceAccess(pc, pcId, keys: keys);
      await pcAccess.register();
      expect(pcAccess.trusted, isFalse);
      expect(pc.info.joined, isFalse, reason: 'registered now');
      final pcHost = pc.data.hosts[host.id]!;
      // Set to this device's keys, with nothing in ~/.ssh on the PC: it is
      // still told why it cannot get in.
      DeviceKeys.directory = Directory('${tmp.path}/pc/no-ssh');
      pcHost.useDeviceKeys = true;
      await expectLater(
        connect(pc, pcHost, _Ui()),
        throwsA(
          isA<ConnectError>().having(
            (e) => e.message,
            'message',
            contains('waiting to be approved'),
          ),
        ),
      );
      // Nothing it can do by itself without a way in.
      await pcAccess.run(force: true);
      expect(pcAccess.installedOn(pcId.id), 0);
      await pc.syncNow();

      // The Mac sees the request and approves it; the key goes on.
      await mac.syncNow();
      DeviceIdentity.current = macId;
      expect(macAccess.pending.map((d) => d.name), ['Gaming PC']);
      await macAccess.approve(macAccess.pending.single);
      expect(
        macAccess.installedOn(pcId.id),
        1,
        reason: '${macAccess.problems}',
      );
      final lines = authorized.readAsLinesSync();
      expect(lines.where((l) => l.contains(pcId.blob)), hasLength(1));
      expect(lines.where((l) => l.contains(macId.blob)), hasLength(1));
      expect(
        lines.where((l) => l.contains(macId.blob) && l.contains(pcId.blob)),
        isEmpty,
        reason: 'each key on its own line',
      );
      // Running again changes nothing.
      await macAccess.run(force: true);
      expect(
        authorized.readAsLinesSync().where((l) => l.contains(pcId.blob)),
        hasLength(1),
      );
      await mac.syncNow();

      // A connection the user opens also brings the server up to date,
      // for servers the background cannot sign in to by itself.
      mac.data.deviceInstalls.remove(DeviceInstall.idFor(pcId.id, host.id));
      final opened = await connect(mac, host, _Ui());
      await macAccess.connected(host, opened);
      opened.close();
      expect(macAccess.installedOn(pcId.id), 1);
      expect(
        authorized.readAsLinesSync().where((l) => l.contains(pcId.blob)),
        hasLength(1),
      );
      // A quick connection to an unsaved host hands it no keys.
      final adHoc = Host(
        address: '127.0.0.1',
        port: port,
        username: user,
        useDeviceKeys: true,
      );
      authorized.writeAsStringSync(
        authorized
            .readAsLinesSync()
            .where((l) => !l.contains(pcId.blob))
            .join('\n'),
      );
      final quick = await connect(mac, adHoc, _Ui());
      await macAccess.connected(adHoc, quick);
      quick.close();
      expect(authorized.readAsStringSync(), isNot(contains(pcId.blob)));
      // Put it back the normal way.
      mac.data.deviceInstalls.remove(DeviceInstall.idFor(pcId.id, host.id));
      await macAccess.run(force: true);
      expect(authorized.readAsStringSync(), contains(pcId.blob));
      await mac.syncNow();

      // The PC signs in with its own key.
      await pc.syncNow();
      DeviceIdentity.current = pcId;
      expect(pcAccess.trusted, isTrue);
      await connect(pc, pcHost, _Ui()).then((c) => c.close());

      // Lost the PC: the Mac removes it and its key comes off the server,
      // leaving the Mac's own key alone.
      DeviceIdentity.current = macId;
      await macAccess.remove(mac.data.devices[pcId.id]!);
      expect(
        macAccess.installedOn(pcId.id),
        0,
        reason: '${macAccess.problems}',
      );
      expect(authorized.readAsStringSync(), isNot(contains(pcId.blob)));
      expect(authorized.readAsStringSync(), contains(macId.blob));
      await mac.syncNow();
      await pc.syncNow();
      DeviceIdentity.current = pcId;
      await expectLater(
        connect(pc, pcHost, _Ui()),
        throwsA(
          isA<ConnectError>().having(
            (e) => e.message,
            'message',
            contains('was removed'),
          ),
        ),
      );

      // Reopening its copy does not bring it back.
      await pcAccess.register();
      expect(pcAccess.trusted, isFalse);

      macAccess.dispose();
      pcAccess.dispose();
      await mac.lock();
      await pc.lock();
    },
    skip: available ? false : 'sshd is not installed',
  );

  test(
    'a device key survives reloading and is refused when malformed',
    () async {
      final dir = Directory.systemTemp.createTempSync('marsa_identity');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = FileSecretStore(dir);
      final a = (await DeviceIdentity.load(store, name: 'Mac Book'))!;
      final b = (await DeviceIdentity.load(store, name: 'Mac Book'))!;
      expect(b.id, a.id);
      expect(a.publicKey, endsWith('marsa-Mac-Book'));
      expect(AuthorizedKeys.valid(a.publicKey), isTrue);
      expect(AuthorizedKeys.valid("ssh-ed25519 AAAA x'; rm -rf ~"), isFalse);
      expect(AuthorizedKeys.valid('ssh-ed25519 AAAA\nssh-rsa BBBB'), isFalse);
    },
  );

  test('device records merge without losing anyone\'s changes', () {
    final a = VaultData()
      ..devices.put(Device(id: 'pc', name: 'PC', publicKey: 'k'))
      ..deviceInstalls.put(DeviceInstall(deviceId: 'pc', hostId: 'h1'));
    final b = VaultData()
      ..load(a.toJson())
      ..deviceStatus.put(DeviceStatus(id: 'pc'))
      ..deviceInstalls.put(DeviceInstall(deviceId: 'pc', hostId: 'h2'));
    a.deviceInstalls.put(DeviceInstall(deviceId: 'pc', hostId: 'h3'));
    a.merge(b);
    expect(a.deviceStatus['pc']?.approved, isTrue);
    expect(a.deviceInstalls.all.map((i) => i.hostId).toSet(), {
      'h1',
      'h2',
      'h3',
    });
    a.devices.remove('pc');
    expect(a.devices.wasRemoved('pc'), isTrue);
  });
}
