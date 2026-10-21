import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../core/vault.dart';
import 'connector.dart';
import 'device_identity.dart';

/// Edits a server's `authorized_keys` over an SSH connection.
class AuthorizedKeys {
  const AuthorizedKeys([this.path = '~/.ssh/authorized_keys']);

  /// The file on the server. Tests point it somewhere harmless.
  final String path;

  String get _file => path.startsWith('~/')
      ? '"\$HOME/${path.substring(2)}"'
      : "'${path.replaceAll("'", "'\\''")}'";

  // Key lines come from the vault, which other devices write to, and are
  // pasted into a shell command: anything but a plain key line is refused.
  static final _line = RegExp(
    r'^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) '
    r'[A-Za-z0-9+/]+={0,2}( [A-Za-z0-9._@-]+)?$',
  );

  static bool valid(String line) => _line.hasMatch(line);

  Future<void> _run(SSHClient client, String script) async {
    final r = await client.runWithResult(script);
    if (r.exitCode != 0) {
      final err = utf8.decode(r.stderr, allowMalformed: true).trim();
      throw ConnectError(
        err.isEmpty ? 'The server could not update its keys' : err,
      );
    }
  }

  /// Adds [line] unless a line with the same key is already there.
  Future<void> add(SSHClient client, String line) {
    if (!valid(line)) throw ConnectError('Not a valid public key');
    final blob = line.split(' ')[1];
    return _run(
      client,
      'f=$_file; d=\$(dirname "\$f"); '
      'mkdir -p "\$d" && chmod 700 "\$d" && touch "\$f" && chmod 600 "\$f" '
      '&& { grep -qF \'$blob\' "\$f" || { '
      // Start on a new line if the file does not end with one.
      '[ -s "\$f" ] && [ -n "\$(tail -c 1 "\$f")" ] && echo >> "\$f"; '
      'echo \'$line\' >> "\$f"; }; }',
    );
  }

  /// Removes every line holding the key [line] names.
  Future<void> remove(SSHClient client, String line) {
    if (!valid(line)) throw ConnectError('Not a valid public key');
    final blob = line.split(' ')[1];
    // grep exits 1 when nothing is left, which is fine; 2 is a real error
    // and must not empty the file.
    return _run(
      client,
      'f=$_file; [ -f "\$f" ] || exit 0; '
      'grep -vF \'$blob\' "\$f" > "\$f.marsa"; s=\$?; '
      'if [ \$s -le 1 ]; then cat "\$f.marsa" > "\$f"; fi; '
      'rm -f "\$f.marsa"; [ \$s -le 1 ]',
    );
  }
}

/// Answers nothing: background work only uses what the vault already holds
/// and never opens a dialog.
class _Silent implements Prompter {
  @override
  Future<bool> confirmNewHost(String h, String t, String f) async => false;
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

enum _Op { add, remove }

/// Each device signs in to the vault's servers with its own key. A device
/// joining the vault asks to be let in; once a device that already has
/// access approves it, that device puts the new key on every server, and
/// takes it off again when the device is removed.
class DeviceAccess extends ChangeNotifier {
  DeviceAccess(
    this.vault,
    this.me, {
    this.keys = const AuthorizedKeys(),
    this.retryAfter = const Duration(minutes: 15),
  });

  final VaultSession vault;

  /// This computer, or null when its key could not be loaded.
  final DeviceIdentity? me;
  final AuthorizedKeys keys;

  /// How long a server that failed is left alone before trying again.
  final Duration retryAfter;

  /// The latest failure for a `device:host` pair, cleared once it works.
  final Map<String, String> problems = {};
  final Map<String, DateTime> _failedAt = {};
  final Set<String> _hostsBusy = {};

  Future<void>? _running;
  bool _again = false;
  Timer? _debounce;
  Timer? _periodic;
  bool _disposed = false;

  VaultData get _data => vault.data;

  bool get running => _running != null;

  bool isApproved(String deviceId) =>
      _data.deviceStatus[deviceId]?.approved == true;

  bool isRemoved(String deviceId) =>
      _data.deviceStatus[deviceId]?.approved == false;

  /// This device may sign in to the servers and let other devices in.
  bool get trusted => me != null && isApproved(me!.id);

  /// Devices asking to be let in.
  List<Device> get pending => [
    for (final d in _data.devices.all)
      if (_data.deviceStatus[d.id] == null && d.id != me?.id) d,
  ];

  /// Servers that have [deviceId]'s key.
  int installedOn(String deviceId) => _data.deviceInstalls.all
      .where((i) => i.deviceId == deviceId && _data.hosts[i.hostId] != null)
      .length;

  /// Problems with [deviceId]'s key, by server name.
  Map<String, String> problemsOf(String deviceId) => {
    for (final e in problems.entries)
      if (e.key.startsWith('$deviceId:'))
        _data.hosts[e.key.substring(deviceId.length + 1)]?.title ?? '?':
            e.value,
  };

  /// Registers this device and starts keeping the servers up to date.
  Future<void> start() async {
    await register();
    vault.addListener(_changed);
    _periodic = Timer.periodic(retryAfter, (_) => run());
    unawaited(run());
  }

  // Another device may have approved someone, or a host was added: look
  // again once things settle, skipping servers that failed recently.
  void _changed() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 5), run);
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _periodic?.cancel();
    vault.removeListener(_changed);
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Adds this device to the vault the first time it opens it. A device
  /// that had the vault before devices were tracked keeps the access it
  /// had; one that joined (or was removed before) waits for approval.
  Future<void> register() async {
    final m = me;
    if (m == null) return;
    if (_data.devices[m.id] == null) {
      _data.devices.put(Device(id: m.id, name: m.name, publicKey: m.publicKey));
      if (_data.deviceStatus[m.id] == null &&
          !vault.info.joined &&
          !_data.deviceStatus.wasRemoved(m.id)) {
        _data.deviceStatus.put(DeviceStatus(id: m.id, by: m.name));
      }
      await vault.commit();
    }
    await vault.registry.registered(vault.info);
  }

  Future<void> approve(Device d) => _decide(d, true);

  /// Takes the device's key off every server, or turns a request down.
  Future<void> remove(Device d) => _decide(d, false);

  Future<void> _decide(Device d, bool approved) async {
    _data.deviceStatus.put(
      DeviceStatus(id: d.id, approved: approved, by: me?.name ?? ''),
    );
    for (final k in problems.keys.where((k) => k.startsWith('${d.id}:'))) {
      _failedAt.remove(k);
    }
    await vault.commit();
    await run(force: true);
  }

  /// Brings every server in line: approved devices' keys on, removed ones'
  /// off. Servers that failed recently are skipped unless [force].
  Future<void> run({bool force = false}) async {
    if (_running != null) {
      _again = true;
      return _running;
    }
    _running = () async {
      try {
        do {
          _again = false;
          await _pass(force);
        } while (_again && !_disposed);
      } finally {
        _running = null;
        _notify();
      }
    }();
    _notify();
    return _running;
  }

  // What has to change on [host]; empty when nothing does or this device
  // may not do it.
  List<(Device, _Op)> _work(Host host, {required bool force}) {
    final m = me;
    if (m == null) return const [];
    final out = <(Device, _Op)>[];
    for (final d in _data.devices.all) {
      final key = DeviceInstall.idFor(d.id, host.id);
      if (!force) {
        final failed = _failedAt[key];
        if (failed != null && DateTime.now().difference(failed) < retryAfter) {
          continue;
        }
      }
      final there = _data.deviceInstalls[key] != null;
      // A device not yet approved may still put its own key on servers it
      // can already reach with what the vault holds: that gives it nothing
      // it did not have. Letting others in, or out, takes approval.
      if (isApproved(d.id) && !there && (trusted || d.id == m.id)) {
        out.add((d, _Op.add));
      } else if (isRemoved(d.id) && there && trusted) {
        out.add((d, _Op.remove));
      }
    }
    return out;
  }

  Future<void> _pass(bool force) async {
    var changed = false;
    // Keys on servers that left the vault can no longer be reached.
    for (final i in _data.deviceInstalls.all.toList()) {
      if (_data.hosts[i.hostId] == null) {
        _data.deviceInstalls.remove(i.id);
        changed = true;
      }
    }
    final jobs = [
      for (final h in _data.hosts.all)
        if (_work(h, force: force).isNotEmpty) h,
    ];
    // A few servers at a time; each connection does all its changes.
    for (var i = 0; i < jobs.length; i += 4) {
      final batch = jobs.skip(i).take(4);
      final results = await Future.wait([
        for (final h in batch) _withHost(h, force: force),
      ]);
      changed |= results.any((r) => r);
    }
    if (changed && !_disposed) await vault.commit();
  }

  Future<bool> _withHost(Host host, {required bool force}) async {
    if (!_hostsBusy.add(host.id)) return false;
    try {
      final work = _work(host, force: force);
      if (work.isEmpty) return false;
      final Connection conn;
      try {
        conn = await connect(vault, host, _Silent(), announce: false);
      } catch (e) {
        for (final (d, _) in work) {
          _fail(DeviceInstall.idFor(d.id, host.id), e);
        }
        return false;
      }
      try {
        return await _apply(conn.client, host, work);
      } finally {
        conn.close();
      }
    } finally {
      _hostsBusy.remove(host.id);
    }
  }

  /// A connection the user opened: the moment to bring that server up to
  /// date, even one the background cannot sign in to by itself.
  Future<void> connected(Host host, Connection conn) async {
    // Only servers saved in the vault: a quick connection to somewhere else
    // must not hand that server the keys of every device.
    if (_disposed || _data.hosts[host.id] == null) return;
    if (!_hostsBusy.add(host.id)) return;
    try {
      final work = _work(host, force: true);
      if (work.isEmpty) return;
      if (await _apply(conn.client, host, work)) await vault.commit();
    } catch (_) {
      // The session itself goes on; the background retries later.
    } finally {
      _hostsBusy.remove(host.id);
      _notify();
    }
  }

  Future<bool> _apply(
    SSHClient client,
    Host host,
    List<(Device, _Op)> work,
  ) async {
    var changed = false;
    for (final (d, op) in work) {
      final key = DeviceInstall.idFor(d.id, host.id);
      try {
        if (op == _Op.add) {
          await keys.add(client, d.publicKey);
          _data.deviceInstalls.put(
            DeviceInstall(deviceId: d.id, hostId: host.id),
          );
        } else {
          await keys.remove(client, d.publicKey);
          _data.deviceInstalls.remove(key);
        }
        problems.remove(key);
        _failedAt.remove(key);
        changed = true;
      } catch (e) {
        _fail(key, e);
      }
    }
    return changed;
  }

  void _fail(String key, Object e) {
    problems[key] = e.toString();
    _failedAt[key] = DateTime.now();
  }
}
