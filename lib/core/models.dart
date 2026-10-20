import 'crypto.dart';

int nowMs() => DateTime.now().millisecondsSinceEpoch;

/// A synced vault record. [updatedAt] drives last-write-wins merging.
abstract class Rec {
  Rec(String? id, int? updatedAt)
    : id = id ?? newId(),
      updatedAt = updatedAt ?? nowMs();

  final String id;
  int updatedAt;

  Map<String, dynamic> fields();

  Map<String, dynamic> toJson() => {'id': id, 'u': updatedAt, ...fields()};
}

class Host extends Rec {
  Host({
    String? id,
    int? updatedAt,
    this.label = '',
    this.address = '',
    this.port = 22,
    this.username = '',
    this.password = '',
    this.keyId,
    this.identityId,
    this.group = '',
    this.tags = const [],
    this.jumpHostId,
    this.useDeviceKeys = false,
  }) : super(id, updatedAt);

  factory Host.fromJson(Map<String, dynamic> j) => Host(
    id: j['id'] as String,
    updatedAt: j['u'] as int,
    label: j['label'] as String? ?? '',
    address: j['address'] as String? ?? '',
    port: j['port'] as int? ?? 22,
    username: j['username'] as String? ?? '',
    password: j['password'] as String? ?? '',
    keyId: j['keyId'] as String?,
    identityId: j['identityId'] as String?,
    group: j['group'] as String? ?? '',
    tags: (j['tags'] as List? ?? const []).cast<String>(),
    jumpHostId: j['jumpHostId'] as String?,
    useDeviceKeys: j['deviceKeys'] as bool? ?? false,
  );

  String label;
  String address;
  int port;
  String username;
  String password;
  String? keyId;

  /// When set, the identity supplies username, password and key.
  String? identityId;
  String group;
  List<String> tags;
  String? jumpHostId;

  /// Sign in with whatever keys are in `~/.ssh` on the device connecting,
  /// instead of a key stored in the vault.
  bool useDeviceKeys;

  String get title => label.isEmpty ? address : label;

  @override
  Map<String, dynamic> fields() => {
    'label': label,
    'address': address,
    'port': port,
    'username': username,
    'password': password,
    'keyId': keyId,
    'identityId': identityId,
    'group': group,
    'tags': tags,
    'jumpHostId': jumpHostId,
    'deviceKeys': useDeviceKeys,
  };
}

class SshKey extends Rec {
  SshKey({
    String? id,
    int? updatedAt,
    this.label = '',
    this.privateKey = '',
    this.publicKey = '',
    this.type = '',
  }) : super(id, updatedAt);

  factory SshKey.fromJson(Map<String, dynamic> j) => SshKey(
    id: j['id'] as String,
    updatedAt: j['u'] as int,
    label: j['label'] as String? ?? '',
    privateKey: j['privateKey'] as String? ?? '',
    publicKey: j['publicKey'] as String? ?? '',
    type: j['type'] as String? ?? '',
  );

  String label;

  /// Unencrypted PEM. The vault itself is what protects it at rest.
  String privateKey;

  /// OpenSSH `authorized_keys` line.
  String publicKey;
  String type;

  @override
  Map<String, dynamic> fields() => {
    'label': label,
    'privateKey': privateKey,
    'publicKey': publicKey,
    'type': type,
  };
}

class Identity extends Rec {
  Identity({
    String? id,
    int? updatedAt,
    this.label = '',
    this.username = '',
    this.password = '',
    this.keyId,
  }) : super(id, updatedAt);

  factory Identity.fromJson(Map<String, dynamic> j) => Identity(
    id: j['id'] as String,
    updatedAt: j['u'] as int,
    label: j['label'] as String? ?? '',
    username: j['username'] as String? ?? '',
    password: j['password'] as String? ?? '',
    keyId: j['keyId'] as String?,
  );

  String label;
  String username;
  String password;
  String? keyId;

  String get title => label.isEmpty ? username : label;

  @override
  Map<String, dynamic> fields() => {
    'label': label,
    'username': username,
    'password': password,
    'keyId': keyId,
  };
}

class Snippet extends Rec {
  Snippet({String? id, int? updatedAt, this.label = '', this.command = ''})
    : super(id, updatedAt);

  factory Snippet.fromJson(Map<String, dynamic> j) => Snippet(
    id: j['id'] as String,
    updatedAt: j['u'] as int,
    label: j['label'] as String? ?? '',
    command: j['command'] as String? ?? '',
  );

  String label;
  String command;

  @override
  Map<String, dynamic> fields() => {'label': label, 'command': command};
}

enum ForwardKind { local, remote, dynamic }

class PortForward extends Rec {
  PortForward({
    String? id,
    int? updatedAt,
    this.label = '',
    this.kind = ForwardKind.local,
    this.hostId = '',
    this.bindHost = '127.0.0.1',
    this.bindPort = 0,
    this.destHost = '127.0.0.1',
    this.destPort = 0,
  }) : super(id, updatedAt);

  factory PortForward.fromJson(Map<String, dynamic> j) => PortForward(
    id: j['id'] as String,
    updatedAt: j['u'] as int,
    label: j['label'] as String? ?? '',
    kind: ForwardKind.values.firstWhere(
      (k) => k.name == j['kind'],
      orElse: () => ForwardKind.local,
    ),
    hostId: j['hostId'] as String? ?? '',
    bindHost: j['bindHost'] as String? ?? '127.0.0.1',
    bindPort: j['bindPort'] as int? ?? 0,
    destHost: j['destHost'] as String? ?? '127.0.0.1',
    destPort: j['destPort'] as int? ?? 0,
  );

  String label;
  ForwardKind kind;
  String hostId;

  /// Listening side: this machine for local/dynamic, the server for remote.
  String bindHost;
  int bindPort;
  String destHost;
  int destPort;

  @override
  Map<String, dynamic> fields() => {
    'label': label,
    'kind': kind.name,
    'hostId': hostId,
    'bindHost': bindHost,
    'bindPort': bindPort,
    'destHost': destHost,
    'destPort': destPort,
  };
}

/// A pinned server host key. The id is `address:port` so the same server
/// converges to one record across devices.
class KnownHost extends Rec {
  KnownHost({
    required String id,
    int? updatedAt,
    this.type = '',
    this.fingerprint = '',
  }) : super(id, updatedAt);

  factory KnownHost.fromJson(Map<String, dynamic> j) => KnownHost(
    id: j['id'] as String,
    updatedAt: j['u'] as int,
    type: j['type'] as String? ?? '',
    fingerprint: j['fingerprint'] as String? ?? '',
  );

  String type;
  String fingerprint;

  @override
  Map<String, dynamic> fields() => {'type': type, 'fingerprint': fingerprint};
}

/// A computer that uses this vault, by the public half of its own SSH key.
/// The private half never leaves that computer. Written only by the device
/// itself, when it first opens the vault.
class Device extends Rec {
  Device({
    required String id,
    int? updatedAt,
    this.name = '',
    this.publicKey = '',
  }) : super(id, updatedAt);

  factory Device.fromJson(Map<String, dynamic> j) => Device(
    id: j['id'] as String,
    updatedAt: j['u'] as int,
    name: j['name'] as String? ?? '',
    publicKey: j['publicKey'] as String? ?? '',
  );

  String name;

  /// OpenSSH `authorized_keys` line.
  String publicKey;

  String get title => name.isEmpty ? 'Unnamed device' : name;

  @override
  Map<String, dynamic> fields() => {'name': name, 'publicKey': publicKey};
}

/// Whether a [Device] may sign in to the vault's servers. No record means
/// it is waiting for approval. Kept apart from [Device] so the device and
/// the people approving it never overwrite each other's changes.
class DeviceStatus extends Rec {
  DeviceStatus({
    required String id,
    int? updatedAt,
    this.approved = true,
    this.by = '',
  }) : super(id, updatedAt);

  factory DeviceStatus.fromJson(Map<String, dynamic> j) => DeviceStatus(
    id: j['id'] as String,
    updatedAt: j['u'] as int,
    approved: j['approved'] as bool? ?? false,
    by: j['by'] as String? ?? '',
  );

  /// False once the device has been removed: its key comes off every
  /// server and stays off.
  bool approved;

  /// Name of the device that made the decision.
  String by;

  @override
  Map<String, dynamic> fields() => {'approved': approved, 'by': by};
}

/// A device's key is in a server's `authorized_keys`. One record per pair,
/// with the id `device:host`, so devices installing keys at the same time
/// cannot lose each other's progress.
class DeviceInstall extends Rec {
  DeviceInstall({required this.deviceId, required this.hostId, int? updatedAt})
    : super(idFor(deviceId, hostId), updatedAt);

  factory DeviceInstall.fromJson(Map<String, dynamic> j) => DeviceInstall(
    deviceId: j['device'] as String,
    hostId: j['host'] as String,
    updatedAt: j['u'] as int,
  );

  static String idFor(String deviceId, String hostId) => '$deviceId:$hostId';

  final String deviceId;
  final String hostId;

  @override
  Map<String, dynamic> fields() => {'device': deviceId, 'host': hostId};
}

/// One collection of records plus the tombstones of deleted ones. Deleting
/// drops the record body (so secrets do not linger) and keeps only its id and
/// deletion time, which is what lets a delete win over a stale copy elsewhere.
class Table<T extends Rec> {
  Table(this._decode);

  final T Function(Map<String, dynamic>) _decode;
  final Map<String, T> _items = {};
  final Map<String, int> _tombs = {};

  Iterable<T> get all => _items.values;
  T? operator [](String? id) => id == null ? null : _items[id];

  void put(T rec) {
    rec.updatedAt = _after(rec.id);
    _items[rec.id] = rec;
  }

  void remove(String id) {
    if (_items.remove(id) != null) _tombs[id] = _after(id);
  }

  /// Whether a record with this id existed and was deleted.
  bool wasRemoved(String id) => _tombs.containsKey(id);

  // Strictly later than anything already recorded for this id, so a change
  // made here wins even if another device's clock runs ahead.
  int _after(String id) {
    var t = nowMs();
    final prev = [
      _items[id]?.updatedAt ?? 0,
      _tombs[id] ?? 0,
    ].reduce((a, b) => a > b ? a : b);
    if (t <= prev) t = prev + 1;
    return t;
  }

  void merge(Table<T> other) {
    other._tombs.forEach((id, at) {
      if (at > (_tombs[id] ?? 0)) _tombs[id] = at;
    });
    for (final r in other._items.values) {
      final mine = _items[r.id];
      if (mine == null || r.updatedAt > mine.updatedAt) _items[r.id] = r;
    }
    _items.removeWhere((id, r) => (_tombs[id] ?? 0) >= r.updatedAt);
  }

  void load(Map<String, dynamic>? j) {
    _items.clear();
    _tombs.clear();
    if (j == null) return;
    for (final e in j['items'] as List? ?? const []) {
      final r = _decode(e as Map<String, dynamic>);
      _items[r.id] = r;
    }
    (j['tombs'] as Map<String, dynamic>? ?? const {}).forEach(
      (id, at) => _tombs[id] = at as int,
    );
  }

  Map<String, dynamic> toJson() {
    final ids = _items.keys.toList()..sort();
    final tombIds = _tombs.keys.toList()..sort();
    return {
      'items': [for (final id in ids) _items[id]!.toJson()],
      'tombs': {for (final id in tombIds) id: _tombs[id]},
    };
  }
}

class Credentials {
  Credentials(this.username, this.password, this.key);
  final String username;
  final String password;
  final SshKey? key;
}

/// Everything a vault syncs.
class VaultData {
  final hosts = Table<Host>(Host.fromJson);
  final keys = Table<SshKey>(SshKey.fromJson);
  final identities = Table<Identity>(Identity.fromJson);
  final snippets = Table<Snippet>(Snippet.fromJson);
  final forwards = Table<PortForward>(PortForward.fromJson);
  final knownHosts = Table<KnownHost>(KnownHost.fromJson);
  final devices = Table<Device>(Device.fromJson);
  final deviceStatus = Table<DeviceStatus>(DeviceStatus.fromJson);
  final deviceInstalls = Table<DeviceInstall>(DeviceInstall.fromJson);

  Map<String, Table> get _tables => {
    'hosts': hosts,
    'keys': keys,
    'identities': identities,
    'snippets': snippets,
    'forwards': forwards,
    'knownHosts': knownHosts,
    'devices': devices,
    'deviceStatus': deviceStatus,
    'deviceInstalls': deviceInstalls,
  };

  void load(Map<String, dynamic> j) =>
      _tables.forEach((name, t) => t.load(j[name] as Map<String, dynamic>?));

  Map<String, dynamic> toJson() =>
      _tables.map((name, t) => MapEntry(name, t.toJson()));

  void merge(VaultData other) {
    final theirs = other._tables;
    _tables.forEach((name, t) => t.merge(theirs[name]!));
  }

  Credentials credentialsFor(Host h) {
    final ident = h.useDeviceKeys ? null : identities[h.identityId];
    if (ident != null) {
      return Credentials(ident.username, ident.password, keys[ident.keyId]);
    }
    return Credentials(h.username, h.password, keys[h.keyId]);
  }
}
