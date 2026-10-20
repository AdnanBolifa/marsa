import 'dart:io';
import 'dart:isolate';

import 'package:dartssh2/dartssh2.dart';

import 'connector.dart';

/// The SSH keys already on this computer (`~/.ssh/id_*`), used in place for
/// hosts set to "this device's SSH keys". They are read when connecting and
/// never copied into a vault, so they do not sync: each device signs in with
/// its own keys.
class DeviceKeys {
  /// Overridable so tests do not read the real `~/.ssh`.
  static Directory directory = Directory(
    '${Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? ''}'
    '${Platform.pathSeparator}.ssh',
  );

  // Servers usually allow six attempts per connection; leave room for this
  // device's Marsa key before these and a password prompt after.
  static const _maxKeys = 4;

  // Passphrase-protected keys, unlocked for as long as the app runs so the
  // passphrase is asked once rather than on every connection.
  static final _unlocked = <String, String>{};

  /// Forgets unlocked keys; called when the vault is locked.
  static void lock() => _unlocked.clear();

  static List<File> files() {
    if (!directory.existsSync()) return [];
    String name(File f) => f.uri.pathSegments.last;
    final found = directory
        .listSync()
        .whereType<File>()
        .where((f) => name(f).startsWith('id_') && !name(f).endsWith('.pub'))
        .toList();
    // Same preference order as the OpenSSH client.
    const order = ['id_ed25519', 'id_ecdsa', 'id_rsa'];
    int rank(File f) {
      final i = order.indexOf(name(f));
      return i < 0 ? order.length : i;
    }

    found.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : name(a).compareTo(name(b));
    });
    return found.take(_maxKeys).toList();
  }

  static bool get available => files().isNotEmpty;

  static Future<List<SSHKeyPair>> load(Prompter ui) async {
    final out = <SSHKeyPair>[];
    for (final f in files()) {
      final name = f.uri.pathSegments.last;
      try {
        var pem = _unlocked[f.path] ?? await f.readAsString();
        if (!pem.contains('PRIVATE KEY')) continue;
        if (SSHKeyPair.isEncryptedPem(pem)) {
          final plain = await _unlock(ui, name, pem);
          if (plain == null) continue;
          pem = _unlocked[f.path] = plain;
        }
        out.addAll(SSHKeyPair.fromPem(pem));
      } on FileSystemException {
        // Unreadable file: try the next key.
      } on SSHKeyDecodeError {
        // A key type this app cannot read (for example a hardware-backed
        // key): try the next one.
      } on FormatException {
        // Not really a key file.
      }
    }
    if (out.isEmpty) {
      throw ConnectError(
        'No usable SSH key found in ${directory.path} on this device',
      );
    }
    return out;
  }

  static Future<String?> _unlock(Prompter ui, String name, String pem) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final pass = await ui.askSecret(
        'SSH key passphrase',
        attempt == 0
            ? 'Passphrase for $name'
            : 'Wrong passphrase. Passphrase for $name',
      );
      if (pass == null) return null; // skipped: carry on with other keys
      try {
        return await Isolate.run(
          () => SSHKeyPair.fromPem(pem, pass).first.toPem(),
        );
      } catch (_) {
        // Wrong passphrase: ask again.
      }
    }
    return null;
  }
}
