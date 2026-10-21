import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/vault.dart';
import '../ssh/device_identity.dart';

/// Keeps remembered vault keys in the macOS Keychain or the Windows
/// Credential Manager, where they are tied to the signed-in OS user.
class SystemKeyStore implements KeyStore {
  // The login keychain rather than the data-protection one: the latter needs
  // a Keychain Sharing entitlement and a provisioning profile, which would
  // stop self-built and unsigned copies of the app from launching.
  static const _storage = FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );

  String _name(String vaultId) => 'vault-key-$vaultId';

  @override
  Future<Uint8List?> read(String vaultId) async {
    final v = await _storage.read(key: _name(vaultId));
    return v == null ? null : base64.decode(v);
  }

  @override
  Future<void> write(String vaultId, Uint8List key) =>
      _storage.write(key: _name(vaultId), value: base64.encode(key));

  @override
  Future<void> delete(String vaultId) => _storage.delete(key: _name(vaultId));
}

/// The same OS credential store, for this device's own SSH key.
class SystemSecretStore implements SecretStore {
  @override
  Future<String?> read(String name) => SystemKeyStore._storage.read(key: name);

  @override
  Future<void> write(String name, String value) =>
      SystemKeyStore._storage.write(key: name, value: value);
}
