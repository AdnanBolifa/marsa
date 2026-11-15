import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/digests/sha256.dart';

import '../core/crypto.dart';
import '../core/models.dart';

/// Ordered capability tiers for MCP agent tokens.
enum McpPermissionTier {
  /// Read-only metadata discovery (hosts, identities, snippets).
  discover,

  /// Discovery + SFTP read/list/stat operations.
  sftpRead,

  /// SFTP read + write/upload operations.
  sftpWrite,

  /// Full brokered access including SSH command execution.
  sshExec,
}

extension McpPermissionTierX on McpPermissionTier {
  String get label => switch (this) {
    McpPermissionTier.discover => 'Discovery only',
    McpPermissionTier.sftpRead => 'Discovery + SFTP read',
    McpPermissionTier.sftpWrite => 'Discovery + SFTP read/write',
    McpPermissionTier.sshExec => 'Full (SSH exec + SFTP)',
  };

  bool allows(McpPermissionTier required) => index >= required.index;
}

/// A device-local AI agent token profile. Never synced inside vaults.
class McpAgentToken {
  McpAgentToken({
    required this.id,
    required this.name,
    required this.tokenHash,
    this.tier = McpPermissionTier.discover,
    this.allowedVaultIds = const [],
    this.allowedHostIds = const [],
    this.allowedGroups = const [],
    this.requireApproval = true,
    required this.createdAt,
    this.revokedAt,
  });

  factory McpAgentToken.fromJson(Map<String, dynamic> j) => McpAgentToken(
    id: j['id'] as String,
    name: j['name'] as String? ?? 'Agent',
    tokenHash: j['tokenHash'] as String,
    tier: McpPermissionTier.values.firstWhere(
      (t) => t.name == j['tier'],
      orElse: () => McpPermissionTier.discover,
    ),
    allowedVaultIds: (j['allowedVaultIds'] as List? ?? const []).cast<String>(),
    allowedHostIds: (j['allowedHostIds'] as List? ?? const []).cast<String>(),
    allowedGroups: (j['allowedGroups'] as List? ?? const []).cast<String>(),
    requireApproval: j['requireApproval'] as bool? ?? true,
    createdAt: j['createdAt'] as int? ?? 0,
    revokedAt: j['revokedAt'] as int?,
  );

  final String id;
  String name;
  final String tokenHash;
  McpPermissionTier tier;
  List<String> allowedVaultIds;
  List<String> allowedHostIds;
  List<String> allowedGroups;
  bool requireApproval;
  final int createdAt;
  int? revokedAt;

  bool get isRevoked => revokedAt != null;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'tokenHash': tokenHash,
    'tier': tier.name,
    'allowedVaultIds': allowedVaultIds,
    'allowedHostIds': allowedHostIds,
    'allowedGroups': allowedGroups,
    'requireApproval': requireApproval,
    'createdAt': createdAt,
    if (revokedAt != null) 'revokedAt': revokedAt,
  };
}

/// Manages scoped per-agent bearer tokens in a local JSON file.
class McpTokenStore extends ChangeNotifier {
  McpTokenStore(this._file);

  final File _file;
  final List<McpAgentToken> tokens = [];

  static String hashToken(String rawToken) {
    final digest = SHA256Digest().process(
      Uint8List.fromList(utf8.encode(rawToken)),
    );
    return digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static String _randomToken() {
    final rng = Random.secure();
    final bytes = Uint8List.fromList(
      List<int>.generate(32, (_) => rng.nextInt(256)),
    );
    return 'marsa_${base64UrlEncode(bytes).replaceAll('=', '')}';
  }

  Future<void> load() async {
    tokens.clear();
    if (!await _file.exists()) {
      notifyListeners();
      return;
    }
    try {
      final raw = jsonDecode(await _file.readAsString());
      if (raw is List) {
        for (final item in raw.whereType<Map<String, dynamic>>()) {
          tokens.add(McpAgentToken.fromJson(item));
        }
      }
    } on FormatException {
      // Ignore corrupted local token store; start empty.
    }
    notifyListeners();
  }

  Future<void> _save() async {
    await _file.parent.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode(tokens.map((t) => t.toJson()).toList()),
      flush: true,
    );
    await tmp.rename(_file.path);
  }

  /// Creates a new agent token and returns `(profile, rawToken)`.
  /// [rawToken] is not persisted and should be shown to the user once.
  Future<(McpAgentToken, String)> createToken({
    required String name,
    McpPermissionTier tier = McpPermissionTier.discover,
    List<String> allowedVaultIds = const [],
    List<String> allowedHostIds = const [],
    List<String> allowedGroups = const [],
    bool requireApproval = true,
  }) async {
    final raw = _randomToken();
    final profile = McpAgentToken(
      id: newId(),
      name: name.trim().isEmpty ? 'AI Agent' : name.trim(),
      tokenHash: hashToken(raw),
      tier: tier,
      allowedVaultIds: List.unmodifiable(allowedVaultIds),
      allowedHostIds: List.unmodifiable(allowedHostIds),
      allowedGroups: List.unmodifiable(allowedGroups),
      requireApproval: requireApproval,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    tokens.add(profile);
    await _save();
    notifyListeners();
    return (profile, raw);
  }

  /// Authenticates a bearer token. Returns `null` if unknown or revoked.
  McpAgentToken? authenticate(String rawToken) {
    if (rawToken.isEmpty) return null;
    final hash = hashToken(rawToken);
    for (final t in tokens) {
      if (!t.isRevoked && _constantTimeEquals(t.tokenHash, hash)) {
        return t;
      }
    }
    return null;
  }

  Future<void> revoke(String id) async {
    final idx = tokens.indexWhere((t) => t.id == id);
    if (idx < 0) return;
    tokens[idx].revokedAt = DateTime.now().millisecondsSinceEpoch;
    await _save();
    notifyListeners();
  }

  Future<void> delete(String id) async {
    tokens.removeWhere((t) => t.id == id);
    await _save();
    notifyListeners();
  }

  Future<void> updateTier(String id, McpPermissionTier tier) async {
    final idx = tokens.indexWhere((t) => t.id == id);
    if (idx < 0) return;
    tokens[idx].tier = tier;
    await _save();
    notifyListeners();
  }

  Future<void> setRequireApproval(String id, bool requireApproval) async {
    final idx = tokens.indexWhere((t) => t.id == id);
    if (idx < 0) return;
    tokens[idx].requireApproval = requireApproval;
    await _save();
    notifyListeners();
  }

  bool isVaultAllowed(McpAgentToken token, String vaultId) {
    if (token.allowedVaultIds.isEmpty) return true;
    return token.allowedVaultIds.contains(vaultId);
  }

  bool isHostAllowed(McpAgentToken token, String vaultId, Host host) {
    if (!isVaultAllowed(token, vaultId)) return false;
    if (token.allowedHostIds.isNotEmpty &&
        !token.allowedHostIds.contains(host.id)) {
      return false;
    }
    if (token.allowedGroups.isNotEmpty &&
        !token.allowedGroups.contains(host.group)) {
      return false;
    }
    return true;
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
