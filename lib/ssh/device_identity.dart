import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:pointycastle/export.dart';

import 'keys.dart';

/// Where a device keeps its own private key: the OS credential store in the
/// app, a file where there is none (tests, unsupported platforms).
abstract class SecretStore {
  Future<String?> read(String name);
  Future<void> write(String name, String value);
}

/// Keeps the secret in a file readable only by this user.
class FileSecretStore implements SecretStore {
  FileSecretStore(this.dir);
  final Directory dir;

  File _file(String name) => File('${dir.path}${Platform.pathSeparator}$name');

  @override
  Future<String?> read(String name) async {
    final f = _file(name);
    return await f.exists() ? f.readAsString() : null;
  }

  @override
  Future<void> write(String name, String value) async {
    await dir.create(recursive: true);
    final f = _file(name);
    await f.writeAsString(value, flush: true);
    if (!Platform.isWindows) await Process.run('chmod', ['600', f.path]);
  }
}

/// This computer's own SSH key, which Marsa installs on the vault's servers
/// once the device is approved. The private key stays on this computer and
/// is never written into a vault; only [publicKey] syncs.
class DeviceIdentity {
  DeviceIdentity._(this.pair, this.name, this.publicKey)
    : id = _idOf(publicKey);

  /// The identity this app runs as, once loaded at startup.
  static DeviceIdentity? current;

  static const _secret = 'marsa-device-key';

  final SSHKeyPair pair;

  /// Stable for as long as the key is: derived from the public key.
  final String id;

  /// Shown to the user when approving, e.g. "Adnans-MacBook-Air".
  final String name;

  /// `authorized_keys` line, tagged so it is recognisable on the server.
  final String publicKey;

  static String _idOf(String publicLine) {
    final blob = base64.decode(publicLine.split(' ')[1]);
    final digest = SHA256Digest().process(blob);
    return digest
        .take(8)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// The base64 key blob, which identifies the key in `authorized_keys`
  /// whatever comment the line carries.
  String get blob => publicKey.split(' ')[1];

  static String defaultName() {
    var n = Platform.localHostname;
    if (n.endsWith('.local')) n = n.substring(0, n.length - 6);
    return n.isEmpty ? Platform.operatingSystem : n;
  }

  /// Reads this device's key, creating one on first use. Returns null when
  /// the store cannot be read right now: a new key would make this computer
  /// look like a different device, so it is better to do without for now.
  static Future<DeviceIdentity?> load(SecretStore store, {String? name}) async {
    final label = name ?? defaultName();
    String? pem;
    try {
      pem = await store.read(_secret);
    } catch (_) {
      return null;
    }
    if (pem == null) {
      final key = generateEd25519('marsa-$label');
      try {
        await store.write(_secret, key.privateKey);
      } catch (_) {
        return null;
      }
      pem = key.privateKey;
    }
    try {
      final pair = SSHKeyPair.fromPem(pem).first;
      final blob = base64.encode(pair.toPublicKey().encode());
      final comment = 'marsa-$label'.replaceAll(
        RegExp(r'[^A-Za-z0-9._@-]+'),
        '-',
      );
      return DeviceIdentity._(pair, label, '${pair.name} $blob $comment');
    } catch (_) {
      return null;
    }
  }
}
