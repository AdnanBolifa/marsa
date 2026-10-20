import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'crypto.dart';
import 'models.dart';
import 'sync.dart';

class VaultInfo {
  VaultInfo(this.id, this.name, {this.remembered = false, this.joined = false});
  final String id;
  String name;

  /// This device keeps the vault's key in the OS credential store, so it
  /// opens without the master password.
  bool remembered;

  /// This device got the vault by joining it and has not yet asked to be
  /// let in to its servers. A device that had the vault before devices were
  /// tracked is trusted as it was; one that joins must be approved.
  bool joined;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'remembered': remembered,
    if (joined) 'joined': true,
  };
}

/// The operating system's credential store (Keychain, Credential Manager),
/// holding vault keys for vaults the user chose to remember on this device.
abstract class KeyStore {
  Future<Uint8List?> read(String vaultId);
  Future<void> write(String vaultId, Uint8List key);
  Future<void> delete(String vaultId);
}

/// The remote copy is encrypted with a different master password than the
/// local one: someone changed it on another device.
class RemotePasswordChanged implements Exception {
  @override
  String toString() => 'The vault password was changed on another device';
}

/// The list of vaults on this device. Names and ids are not secret; everything
/// else lives in each vault's encrypted file.
class VaultRegistry extends ChangeNotifier {
  VaultRegistry(this.dir, {this.keyStore});

  final Directory dir;
  final KeyStore? keyStore;
  final List<VaultInfo> vaults = [];

  /// The vault opened most recently, which is the one to reopen on launch.
  String? lastId;

  File get _index => File('${dir.path}/vaults.json');
  File fileOf(String id) => File('${dir.path}/$id.vault');

  Future<void> load() async {
    await dir.create(recursive: true);
    vaults.clear();
    if (await _index.exists()) {
      final j = jsonDecode(await _index.readAsString());
      // The first releases stored a bare list of vaults.
      lastId = j is Map ? j['last'] as String? : null;
      for (final v in (j is Map ? j['vaults'] : j) as List) {
        vaults.add(
          VaultInfo(
            v['id'] as String,
            v['name'] as String,
            remembered: v['remembered'] as bool? ?? false,
            joined: v['joined'] as bool? ?? false,
          ),
        );
      }
    }
    notifyListeners();
  }

  Future<void> _save() async {
    await _index.writeAsString(jsonEncode({'last': lastId, 'vaults': vaults}));
    notifyListeners();
  }

  Future<VaultSession> _opened(VaultSession s) async {
    if (lastId != s.info.id) {
      lastId = s.info.id;
      await _save();
    }
    return s;
  }

  VaultSession _open(VaultInfo info, Envelope env, Uint8List key) {
    final body = open(key, env) as Map<String, dynamic>;
    final sync = body['sync'] as Map<String, dynamic>?;
    return VaultSession._(
      this,
      info,
      env.kdf,
      key,
      VaultData()..load(body['data'] as Map<String, dynamic>),
      sync == null ? null : SyncConfig.fromJson(sync),
    );
  }

  /// Opens a remembered vault with the key from the OS credential store.
  /// Returns null when that is not possible (nothing stored, the store is
  /// unavailable, or the master password has changed since); the vault then
  /// goes back to asking for the password.
  Future<VaultSession?> unlockRemembered(VaultInfo info) async {
    if (!info.remembered || keyStore == null) return null;
    final env = Envelope.parse(await fileOf(info.id).readAsString());
    try {
      final key = await keyStore!.read(info.id);
      if (key != null) return await _opened(_open(info, env, key));
    } on WrongPassword {
      // Stale key: fall through and forget it.
    } catch (_) {
      // The store could not be read right now; keep the setting and ask for
      // the password this time.
      return null;
    }
    await forget(info);
    return null;
  }

  /// Stores the open vault's key in the OS credential store.
  Future<void> remember(VaultSession s) async {
    if (keyStore == null) {
      throw StateError('No credential store is available on this device');
    }
    await keyStore!.write(s.info.id, s._key);
    s.info.remembered = true;
    await _save();
  }

  Future<void> forget(VaultInfo info) async {
    info.remembered = false;
    await _save();
    try {
      await keyStore?.delete(info.id);
    } catch (_) {
      // Nothing more to do: the flag is off, so the key is never used again.
    }
  }

  Future<VaultSession> create(String name, String password) async {
    final kdf = KdfParams.fresh();
    final s = VaultSession._(
      this,
      VaultInfo(newId(), name),
      kdf,
      await deriveKey(password, kdf),
      VaultData(),
      null,
    );
    await s._saveLocal();
    vaults.add(s.info);
    lastId = s.info.id;
    await _save();
    return s;
  }

  Future<VaultSession> unlock(VaultInfo info, String password) async {
    final env = Envelope.parse(await fileOf(info.id).readAsString());
    return _opened(_open(info, env, await deriveKey(password, env.kdf)));
  }

  /// Adds a vault that already exists at a sync target to this device.
  Future<VaultSession> join(
    String name,
    String password,
    SyncConfig cfg,
  ) async {
    final text = await withSyncTarget(cfg, (io) => io.read());
    if (text == null) {
      throw SyncError('No vault file found at ${cfg.summary}');
    }
    final env = Envelope.parse(text);
    final key = await deriveKey(password, env.kdf);
    final body = open(key, env) as Map<String, dynamic>;
    final id = body['vault'] as String;
    if (vaults.any((v) => v.id == id)) {
      throw SyncError('This vault is already on this device');
    }
    final s = VaultSession._(
      this,
      VaultInfo(id, name, joined: true),
      env.kdf,
      key,
      VaultData()..load(body['data'] as Map<String, dynamic>),
      cfg,
    );
    await s._saveLocal();
    vaults.add(s.info);
    lastId = s.info.id;
    await _save();
    return s;
  }

  /// Records that this device has registered itself in the vault.
  Future<void> registered(VaultInfo info) async {
    if (!info.joined) return;
    info.joined = false;
    await _save();
  }

  Future<void> rename(VaultInfo info, String name) async {
    info.name = name;
    await _save();
  }

  /// Removes the vault from this device only; a synced copy is left alone.
  Future<void> remove(VaultInfo info) async {
    await forget(info);
    vaults.removeWhere((v) => v.id == info.id);
    if (lastId == info.id) lastId = null;
    final f = fileOf(info.id);
    if (await f.exists()) await f.delete();
    await _save();
  }
}

enum SyncState { off, idle, syncing, error, passwordChanged }

/// An unlocked vault.
class VaultSession extends ChangeNotifier {
  VaultSession._(
    this._registry,
    this.info,
    this._kdf,
    this._key,
    this.data,
    this._sync,
  ) {
    if (_sync != null) {
      syncState = SyncState.idle;
      _startTimer();
    }
  }

  final VaultRegistry _registry;
  final VaultInfo info;
  final VaultData data;
  KdfParams _kdf;
  Uint8List _key;
  SyncConfig? _sync;

  SyncState syncState = SyncState.off;
  String? syncError;
  DateTime? lastSynced;

  Timer? _debounce;
  Timer? _periodic;
  Future<void> _writes = Future.value();
  Future<void>? _running;
  bool _closed = false;

  SyncConfig? get sync => _sync;

  VaultRegistry get registry => _registry;

  /// Persists edits made to [data] and schedules a sync.
  Future<void> commit() async {
    notifyListeners();
    await _saveLocal();
    if (_sync != null) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(seconds: 2), syncNow);
    }
  }

  Future<void> _saveLocal() {
    // Serialized so two saves can never interleave their temp files.
    return _writes = _writes.catchError((_) {}).then((_) async {
      final f = _registry.fileOf(info.id);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(
        seal(_key, _kdf, {'data': data.toJson(), 'sync': _sync?.toJson()}),
        flush: true,
      );
      await tmp.rename(f.path);
    });
  }

  String _remoteBody() =>
      seal(_key, _kdf, {'vault': info.id, 'data': data.toJson()});

  void _startTimer() {
    _periodic?.cancel();
    _periodic = Timer.periodic(const Duration(minutes: 3), (_) => syncNow());
  }

  /// Merges with the sync target. Failures land in [syncState]/[syncError].
  Future<void> syncNow() {
    if (_sync == null || _closed) return Future.value();
    return _running ??= _syncGuarded().whenComplete(() => _running = null);
  }

  Future<void> _syncGuarded() async {
    syncState = SyncState.syncing;
    notifyListeners();
    try {
      await _syncOnce();
      syncState = SyncState.idle;
      syncError = null;
      lastSynced = DateTime.now();
    } on RemotePasswordChanged {
      syncState = SyncState.passwordChanged;
      syncError = RemotePasswordChanged().toString();
    } catch (e) {
      syncState = SyncState.error;
      syncError = e is WrongPassword
          ? 'The synced file cannot be decrypted with this vault\'s key'
          : e.toString();
    }
    if (!_closed) notifyListeners();
  }

  Future<void> _syncOnce() async {
    await withSyncTarget(_sync!, (io) async {
      final text = await io.read();
      String? remoteJson;
      if (text != null) {
        final env = Envelope.parse(text);
        if (!env.kdf.sameAs(_kdf)) throw RemotePasswordChanged();
        final remote = _openRemote(_key, env);
        remoteJson = jsonEncode(remote.toJson());
        data.merge(remote);
      }
      if (jsonEncode(data.toJson()) != remoteJson) {
        await io.write(_remoteBody());
      }
    });
    // Keeps the merged records and a newly pinned sync host key.
    await _saveLocal();
  }

  VaultData _openRemote(Uint8List key, Envelope env) {
    final body = open(key, env) as Map<String, dynamic>;
    if (body['vault'] != info.id) {
      throw SyncError('A different vault is stored at this sync location');
    }
    return VaultData()..load(body['data'] as Map<String, dynamic>);
  }

  /// Points the vault at a sync target (or turns sync off with null). If a
  /// file is already there it must be this same vault.
  Future<void> setSync(SyncConfig? cfg) async {
    _debounce?.cancel();
    _periodic?.cancel();
    _sync = cfg;
    syncError = null;
    lastSynced = null;
    syncState = cfg == null ? SyncState.off : SyncState.idle;
    await _saveLocal();
    notifyListeners();
    if (cfg != null) {
      _startTimer();
      await syncNow();
    }
  }

  /// Re-encrypts the vault. With sync on, the target must be reachable so the
  /// other devices can learn about the change.
  Future<void> changePassword(String newPassword) async {
    if (_sync != null) await _syncOnce();
    final kdf = KdfParams.fresh();
    final key = await deriveKey(newPassword, kdf);
    _kdf = kdf;
    _key = key;
    await _saveLocal();
    await _rekeyed();
    if (_sync != null) {
      await withSyncTarget(_sync!, (io) => io.write(_remoteBody()));
    }
  }

  /// After [RemotePasswordChanged]: take over the new password and merge.
  Future<void> adoptRemotePassword(String password) async {
    final text = await withSyncTarget(_sync!, (io) => io.read());
    if (text == null) throw SyncError('The synced vault file is gone');
    final env = Envelope.parse(text);
    final key = await deriveKey(password, env.kdf);
    final remote = _openRemote(key, env);
    _kdf = env.kdf;
    _key = key;
    data.merge(remote);
    await _saveLocal();
    await _rekeyed();
    notifyListeners();
    await syncNow();
  }

  // A remembered vault must follow the key, or the next launch would find a
  // stored key that no longer opens the file.
  Future<void> _rekeyed() async {
    if (!info.remembered) return;
    try {
      await _registry.keyStore!.write(info.id, _key);
    } catch (_) {
      await _registry.forget(info);
    }
  }

  /// Forgets the key. Wait for pending writes first so nothing is lost.
  Future<void> lock() async {
    _closed = true;
    _debounce?.cancel();
    _periodic?.cancel();
    await _writes.catchError((_) {});
    _key = Uint8List(0);
  }
}
