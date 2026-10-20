import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import '../core/models.dart';
import '../core/vault.dart';
import 'device_identity.dart';
import 'device_keys.dart';

/// Questions a connection may need answered by the person at the keyboard.
abstract class Prompter {
  /// A server we have no pinned key for. Return true to trust and remember it.
  Future<bool> confirmNewHost(String host, String type, String fingerprint);

  /// The server's key differs from the pinned one. Return true only if the
  /// user explicitly chose to replace the pinned key.
  Future<bool> confirmChangedHost(
    String host,
    String type,
    String oldFingerprint,
    String fingerprint,
  );

  Future<String?> askSecret(String title, String prompt);

  Future<List<String>?> askInteractive(
    String title,
    String instruction,
    List<SSHUserInfoPrompt> prompts,
  );
}

class ConnectError implements Exception {
  ConnectError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// An authenticated client plus the jump-host clients it tunnels through.
class Connection {
  Connection(this.client, this._parents);
  final SSHClient client;
  final List<SSHClient> _parents;

  void close() {
    client.close();
    for (final p in _parents) {
      p.close();
    }
  }
}

/// Told about every connection the user opens, so the server can be
/// brought up to date with the vault's device keys while it is reachable.
void Function(VaultSession vault, Host host, Connection conn)? onConnected;

Future<Connection> connect(
  VaultSession vault,
  Host host,
  Prompter ui, {
  bool announce = true,
}) async {
  final conn = await _connect(vault, host, ui, {});
  if (announce) onConnected?.call(vault, host, conn);
  return conn;
}

// This device's own key, once it is approved or already on the server.
SSHKeyPair? _deviceKey(VaultData data, Host host) {
  final me = DeviceIdentity.current;
  if (me == null || data.devices[me.id] == null) return null;
  final approved = data.deviceStatus[me.id]?.approved;
  if (approved == false) return null;
  final there = data.deviceInstalls[DeviceInstall.idFor(me.id, host.id)];
  return approved == true || there != null ? me.pair : null;
}

/// Why this device cannot sign in yet, when the reason is that it is
/// waiting to be let in.
String? _waitingHint(VaultData data) {
  final me = DeviceIdentity.current;
  if (me == null || data.devices[me.id] == null) return null;
  return switch (data.deviceStatus[me.id]?.approved) {
    null =>
      'This device is waiting to be approved. Open Marsa on a device that '
          'already has access and approve "${me.name}"; it then adds this '
          'device\'s key to your servers.',
    false => 'This device was removed from the vault.',
    true => null,
  };
}

Future<Connection> _connect(
  VaultSession vault,
  Host host,
  Prompter ui,
  Set<String> chain,
) async {
  if (!chain.add(host.id)) {
    throw ConnectError('Jump hosts form a loop at ${host.title}');
  }
  final creds = vault.data.credentialsFor(host);
  if (creds.username.isEmpty) {
    throw ConnectError('${host.title} has no username set');
  }
  final where = '${host.address}:${host.port}';

  // Read (and if needed unlock) the keys before opening the connection, so a
  // passphrase prompt cannot run into the server's login timeout.
  final own = _deviceKey(vault.data, host);
  final identities = <SSHKeyPair>[
    ?own,
    if (creds.key != null) ...SSHKeyPair.fromPem(creds.key!.privateKey),
    // A device waiting for approval goes on without them: the server may
    // still take a password, and otherwise it is told why it is turned away.
    if (host.useDeviceKeys)
      ...await _localKeys(
        ui,
        required: own == null && _waitingHint(vault.data) == null,
      ),
  ];

  final parents = <SSHClient>[];
  final SSHSocket socket;
  try {
    final jump = vault.data.hosts[host.jumpHostId];
    if (jump != null) {
      final via = await _connect(vault, jump, ui, chain);
      parents
        ..add(via.client)
        ..addAll(via._parents);
      socket = await via.client.forwardLocal(host.address, host.port);
    } else {
      socket = await SSHSocket.connect(
        host.address,
        host.port,
        timeout: const Duration(seconds: 20),
      );
    }
  } catch (e) {
    for (final p in parents) {
      p.close();
    }
    if (e is ConnectError) rethrow;
    throw ConnectError('Cannot reach $where ($e)');
  }

  String? rejected;
  var passwordTries = 0;
  final client = SSHClient(
    socket,
    username: creds.username,
    identities: identities.isEmpty ? null : identities,
    onVerifyHostKey: (type, raw) async {
      final seen = utf8.decode(raw);
      final known = vault.data.knownHosts[where];
      if (known != null && known.fingerprint == seen) return true;
      final ok = known == null
          ? await ui.confirmNewHost(where, type, seen)
          : await ui.confirmChangedHost(where, type, known.fingerprint, seen);
      if (!ok) {
        rejected = 'Host key for $where was not accepted';
        return false;
      }
      vault.data.knownHosts.put(
        KnownHost(id: where, type: type, fingerprint: seen),
      );
      await vault.commit();
      return true;
    },
    onPasswordRequest: () {
      // Offer the saved password once; after that, ask.
      if (passwordTries++ == 0 && creds.password.isNotEmpty) {
        return creds.password;
      }
      return ui.askSecret(host.title, 'Password for ${creds.username}@$where');
    },
    onUserInfoRequest: (req) async {
      if (req.prompts.isEmpty) return [];
      // A lone hidden prompt is almost always the account password.
      if (req.prompts.length == 1 &&
          !req.prompts.first.echo &&
          passwordTries++ == 0 &&
          creds.password.isNotEmpty) {
        return [creds.password];
      }
      return ui.askInteractive(
        req.name.isEmpty ? host.title : req.name,
        req.instruction,
        req.prompts,
      );
    },
  );

  try {
    await client.authenticated;
  } catch (e) {
    client.close();
    for (final p in parents) {
      p.close();
    }
    if (rejected != null) throw ConnectError(rejected!);
    if (e is SSHAuthError) {
      final hint = _waitingHint(vault.data);
      throw ConnectError(
        'Authentication failed for ${creds.username}@$where'
        '${hint == null ? '' : '. $hint'}',
      );
    }
    throw ConnectError('Connection to $where failed ($e)');
  }
  return Connection(client, parents);
}

// The keys in ~/.ssh. Without them a host can still be reached with this
// device's Marsa key, so their absence only matters when there is none.
Future<List<SSHKeyPair>> _localKeys(
  Prompter ui, {
  required bool required,
}) async {
  try {
    return await DeviceKeys.load(ui);
  } on ConnectError {
    if (required) rethrow;
    return const [];
  }
}
