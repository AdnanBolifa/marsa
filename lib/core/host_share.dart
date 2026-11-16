import 'dart:convert';

import 'crypto.dart';
import 'importers.dart';
import 'models.dart';

class HostShareError implements Exception {
  HostShareError(this.message);
  final String message;

  @override
  String toString() => message;
}

class SharedHostBundle {
  const SharedHostBundle({
    required this.hosts,
    this.keys = const [],
    this.encrypted = false,
    this.missingJumpHost = false,
  });

  final List<Host> hosts;
  final List<SshKey> keys;
  final bool encrypted;
  final bool missingJumpHost;
}

/// Formats [host] (and its jump-host alias if present) as a metadata-only
/// OpenSSH config block. Never includes passwords or private keys.
String exportOpenSshConfig(Host host, VaultData data) {
  final creds = data.credentialsFor(host);
  final alias = _sshAlias(host);
  final buf = StringBuffer()
    ..writeln('Host $alias')
    ..writeln('    HostName ${host.address}');
  if (creds.username.isNotEmpty) {
    buf.writeln('    User ${creds.username}');
  }
  if (host.port != 22) {
    buf.writeln('    Port ${host.port}');
  }
  final jump = host.jumpHostId == null ? null : data.hosts[host.jumpHostId];
  if (jump != null) {
    buf.writeln('    ProxyJump ${_sshAlias(jump)}');
  }
  return buf.toString().trimRight();
}

/// Exports [host] as a metadata-only Marsa JSON document (no secrets).
String exportMetadataJson(Host host, VaultData data) {
  final creds = data.credentialsFor(host);
  final jump = host.jumpHostId == null ? null : data.hosts[host.jumpHostId];
  return const JsonEncoder.withIndent('  ').convert({
    'marsaHostShare': 1,
    'encrypted': false,
    'hosts': [
      {
        'label': host.label,
        'address': host.address,
        'port': host.port,
        'username': creds.username,
        'group': host.group,
        'tags': host.tags,
        'useDeviceKeys': host.useDeviceKeys,
        if (jump != null) 'jumpHostLabel': jump.title,
      },
    ],
  });
}

/// Exports [host] (and optionally its credentials + jump host chain) as an
/// encrypted `marsa://host/...` share link protected by [passphrase].
Future<String> exportEncryptedBundle(
  Host host,
  VaultData data,
  String passphrase, {
  bool includeCredentials = true,
  bool includeJumpHosts = true,
  KdfParams? kdf,
}) async {
  if (passphrase.length < 4) {
    throw HostShareError('Share passphrase must be at least 4 characters.');
  }

  final hosts = <Host>[];
  final visited = <String>{};
  void collect(Host h) {
    if (!visited.add(h.id)) return;
    if (includeJumpHosts && h.jumpHostId != null) {
      final jump = data.hosts[h.jumpHostId];
      if (jump != null) collect(jump);
    }
    hosts.add(h);
  }

  collect(host);

  final keys = <Map<String, dynamic>>[];
  final seenKeys = <String>{};
  final hostPayloads = <Map<String, dynamic>>[];

  for (final h in hosts) {
    final creds = data.credentialsFor(h);
    String? keyRef;
    if (includeCredentials && creds.key != null) {
      keyRef = creds.key!.id;
      if (seenKeys.add(keyRef)) {
        keys.add({
          'ref': keyRef,
          'label': creds.key!.label,
          'type': creds.key!.type,
          'publicKey': creds.key!.publicKey,
          'privateKey': creds.key!.privateKey,
        });
      }
    }
    hostPayloads.add({
      'ref': h.id,
      'label': h.label,
      'address': h.address,
      'port': h.port,
      'username': creds.username,
      if (includeCredentials && creds.password.isNotEmpty)
        'password': creds.password,
      'keyRef': ?keyRef,
      'group': h.group,
      'tags': h.tags,
      'useDeviceKeys': h.useDeviceKeys,
      if (h.jumpHostId != null && visited.contains(h.jumpHostId))
        'jumpRef': h.jumpHostId
      else if (h.jumpHostId != null)
        'jumpHostLabel': data.hosts[h.jumpHostId]?.title ?? 'jump-host',
    });
  }

  final params = kdf ?? KdfParams.fresh();
  final key = await deriveKey(passphrase, params);
  final envelopeText = seal(key, params, {
    'marsaHostShare': 1,
    'hosts': hostPayloads,
    'keys': keys,
  });
  final encoded = base64UrlEncode(utf8.encode(envelopeText)).replaceAll('=', '');
  return 'marsa://host/$encoded';
}

/// Parses a shared Marsa host link (`marsa://host/...`), JSON bundle, or
/// OpenSSH config snippet.
Future<SharedHostBundle> parseSharedHost(
  String raw, {
  Future<String?> Function()? askPassphrase,
}) async {
  final text = raw.trim();
  if (text.isEmpty) {
    throw HostShareError('Nothing to import.');
  }

  // 1. marsa://host/<base64url> link
  if (text.startsWith('marsa://host/')) {
    final b64 = text.substring('marsa://host/'.length).trim();
    final padded = b64.padRight((b64.length + 3) & ~3, '=');
    final String envelopeText;
    try {
      envelopeText = utf8.decode(base64Url.decode(padded));
    } on FormatException {
      throw HostShareError('Invalid Marsa host share link.');
    }
    return _parseEnvelope(envelopeText, askPassphrase);
  }

  // 2. Raw JSON (either encrypted Envelope or metadata-only marsaHostShare)
  if (text.startsWith('{')) {
    final Object? j;
    try {
      j = jsonDecode(text);
    } on FormatException {
      throw HostShareError('Invalid JSON share data.');
    }
    if (j is Map<String, dynamic>) {
      if (j['marsa'] == 1) {
        return _parseEnvelope(text, askPassphrase);
      }
      if (j['marsaHostShare'] == 1) {
        return _bundleFromPayload(j, encrypted: false);
      }
    }
    throw HostShareError('Unrecognized Marsa host share format.');
  }

  // 3. Fallback to OpenSSH / importer formats
  try {
    final imported = parseImport(text);
    if (imported.hosts.isEmpty) {
      throw HostShareError('No hosts found in shared text.');
    }
    return SharedHostBundle(
      hosts: [
        for (final i in imported.hosts)
          Host(
            label: i.label,
            address: i.address,
            port: i.port,
            username: i.username,
            group: i.group,
            tags: i.tags,
          ),
      ],
      encrypted: false,
      missingJumpHost: imported.hosts.any((i) => (i.proxyJump ?? '').isNotEmpty),
    );
  } on ImportError catch (e) {
    throw HostShareError(e.message);
  }
}

Future<SharedHostBundle> _parseEnvelope(
  String envelopeText,
  Future<String?> Function()? askPassphrase,
) async {
  final Envelope env;
  try {
    env = Envelope.parse(envelopeText);
  } on VaultFormatError catch (e) {
    throw HostShareError(e.message);
  }

  final pass = await askPassphrase?.call();
  if (pass == null || pass.isEmpty) {
    throw HostShareError('Passphrase is required to decrypt this shared host.');
  }
  final key = await deriveKey(pass, env.kdf);
  final Object? payload;
  try {
    payload = open(key, env);
  } on WrongPassword {
    throw HostShareError('Incorrect share passphrase.');
  }
  if (payload is! Map<String, dynamic> || payload['marsaHostShare'] != 1) {
    throw HostShareError('Corrupted host share payload.');
  }
  return _bundleFromPayload(payload, encrypted: true);
}

SharedHostBundle _bundleFromPayload(
  Map<String, dynamic> payload, {
  required bool encrypted,
}) {
  final keyMap = <String, SshKey>{};
  final keys = <SshKey>[];
  for (final k in (payload['keys'] as List? ?? const []).whereType<Map<String, dynamic>>()) {
    final sshKey = SshKey(
      label: k['label'] as String? ?? 'Shared Key',
      type: k['type'] as String? ?? '',
      publicKey: k['publicKey'] as String? ?? '',
      privateKey: k['privateKey'] as String? ?? '',
    );
    final ref = k['ref'] as String?;
    if (ref != null) keyMap[ref] = sshKey;
    keys.add(sshKey);
  }

  final hostMap = <String, Host>{};
  final rawHosts =
      (payload['hosts'] as List? ?? const []).whereType<Map<String, dynamic>>().toList();
  for (final h in rawHosts) {
    final keyRef = h['keyRef'] as String?;
    final host = Host(
      label: h['label'] as String? ?? '',
      address: h['address'] as String? ?? '',
      port: (h['port'] as num?)?.toInt() ?? 22,
      username: h['username'] as String? ?? '',
      password: h['password'] as String? ?? '',
      keyId: keyRef != null ? keyMap[keyRef]?.id : null,
      group: h['group'] as String? ?? '',
      tags: (h['tags'] as List? ?? const []).cast<String>(),
      useDeviceKeys: h['useDeviceKeys'] as bool? ?? false,
    );
    final ref = h['ref'] as String?;
    if (ref != null) hostMap[ref] = host;
  }

  var missingJump = false;
  final hosts = <Host>[];
  for (final h in rawHosts) {
    final ref = h['ref'] as String?;
    final host = ref != null ? hostMap[ref]! : Host(
      label: h['label'] as String? ?? '',
      address: h['address'] as String? ?? '',
      port: (h['port'] as num?)?.toInt() ?? 22,
      username: h['username'] as String? ?? '',
      group: h['group'] as String? ?? '',
      tags: (h['tags'] as List? ?? const []).cast<String>(),
      useDeviceKeys: h['useDeviceKeys'] as bool? ?? false,
    );
    final jumpRef = h['jumpRef'] as String?;
    if (jumpRef != null && hostMap.containsKey(jumpRef)) {
      host.jumpHostId = hostMap[jumpRef]!.id;
    } else if (h['jumpHostLabel'] != null) {
      missingJump = true;
    }
    hosts.add(host);
  }

  return SharedHostBundle(
    hosts: hosts,
    keys: keys,
    encrypted: encrypted,
    missingJumpHost: missingJump,
  );
}

String _sshAlias(Host host) =>
    host.title.trim().replaceAll(RegExp(r'\s+'), '-');
