import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../core/models.dart';
import '../core/vault.dart';
import '../ssh/connector.dart';
import '../ssh/file_sync.dart';
import '../ssh/files.dart';
import 'audit.dart';
import 'auth.dart';
import 'executions.dart';
import 'prompter.dart';

typedef SshConnectorFn = Future<Connection> Function(
  VaultSession vault,
  Host host,
  Prompter ui,
);

class McpToolError implements Exception {
  McpToolError(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

class _ToolSpec {
  const _ToolSpec({
    required this.name,
    required this.description,
    required this.tier,
    required this.inputSchema,
  });

  final String name;
  final String description;
  final McpPermissionTier tier;
  final Map<String, dynamic> inputSchema;

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'inputSchema': inputSchema,
  };
}

/// Brokers MCP tool & resource calls against unlocked [VaultSession]s.
class McpToolRegistry {
  McpToolRegistry({
    required this.tokenStore,
    required this.auditLog,
    required this.vaultsProvider,
    this.executions,
    this.connector = connect,
    this.onConsent,
    this.prompterFactory,
  });

  final McpTokenStore tokenStore;
  final McpAuditLog auditLog;
  final List<VaultSession> Function() vaultsProvider;
  final McpExecutionTracker? executions;
  final SshConnectorFn connector;
  McpConsentCallback? onConsent;
  Prompter Function()? prompterFactory;

  static const int defaultMaxOutputBytes = 65536;
  static const int maxAllowedOutputBytes = 262144;
  static const int defaultTimeoutSeconds = 30;
  static const int maxTimeoutSeconds = 120;

  static const List<_ToolSpec> _specs = [
    _ToolSpec(
      name: 'list_hosts',
      description:
          'List SSH/SFTP hosts from unlocked Marsa vaults (metadata only; credentials are never exposed).',
      tier: McpPermissionTier.discover,
      inputSchema: {
        'type': 'object',
        'properties': {
          'group': {'type': 'string', 'description': 'Optional group filter'},
          'tag': {'type': 'string', 'description': 'Optional tag filter'},
          'query': {
            'type': 'string',
            'description': 'Optional substring match on label or address',
          },
        },
        'additionalProperties': false,
      },
    ),
    _ToolSpec(
      name: 'get_host',
      description:
          'Get metadata for a single host by hostId (credentials are never exposed).',
      tier: McpPermissionTier.discover,
      inputSchema: {
        'type': 'object',
        'properties': {
          'hostId': {'type': 'string', 'description': 'Host UUID'},
        },
        'required': ['hostId'],
        'additionalProperties': false,
      },
    ),
    _ToolSpec(
      name: 'list_identities',
      description:
          'List saved identities from unlocked vaults (metadata only; secrets are stripped).',
      tier: McpPermissionTier.discover,
      inputSchema: {'type': 'object', 'properties': {}, 'additionalProperties': false},
    ),
    _ToolSpec(
      name: 'list_snippets',
      description: 'List saved command snippets from unlocked vaults.',
      tier: McpPermissionTier.discover,
      inputSchema: {'type': 'object', 'properties': {}, 'additionalProperties': false},
    ),
    _ToolSpec(
      name: 'create_snippet',
      description: 'Create and save a reusable command snippet in an unlocked vault.',
      tier: McpPermissionTier.sftpWrite,
      inputSchema: {
        'type': 'object',
        'properties': {
          'label': {'type': 'string', 'description': 'Snippet name/label'},
          'command': {'type': 'string', 'description': 'Shell command text'},
          'vaultId': {
            'type': 'string',
            'description': 'Target vault UUID (optional if only one allowed vault is unlocked)',
          },
        },
        'required': ['label', 'command'],
        'additionalProperties': false,
      },
    ),
    _ToolSpec(
      name: 'list_port_forwards',
      description: 'List saved SSH port-forwarding rules from unlocked vaults.',
      tier: McpPermissionTier.discover,
      inputSchema: {'type': 'object', 'properties': {}, 'additionalProperties': false},
    ),
    _ToolSpec(
      name: 'create_port_forward',
      description: 'Create and save an SSH port-forwarding rule (local, remote, or dynamic SOCKS) for a saved host.',
      tier: McpPermissionTier.sftpWrite,
      inputSchema: {
        'type': 'object',
        'properties': {
          'hostId': {'type': 'string', 'description': 'Target host UUID'},
          'label': {'type': 'string', 'description': 'Optional rule label'},
          'kind': {
            'type': 'string',
            'enum': ['local', 'remote', 'dynamic'],
            'description': 'Forwarding type (default local)',
          },
          'bindHost': {
            'type': 'string',
            'description': 'Listening bind address (default 127.0.0.1)',
          },
          'bindPort': {
            'type': 'integer',
            'description': 'Listening port (1-65535)',
          },
          'destHost': {
            'type': 'string',
            'description': 'Destination host for local/remote forwards (default 127.0.0.1)',
          },
          'destPort': {
            'type': 'integer',
            'description': 'Destination port for local/remote forwards (1-65535)',
          },
        },
        'required': ['hostId', 'bindPort'],
        'additionalProperties': false,
      },
    ),
    _ToolSpec(
      name: 'ssh_exec',
      description:
          'Execute a non-interactive command on a saved host using Marsa stored credentials.',
      tier: McpPermissionTier.sshExec,
      inputSchema: {
        'type': 'object',
        'properties': {
          'hostId': {'type': 'string', 'description': 'Target host UUID'},
          'command': {'type': 'string', 'description': 'Command to execute'},
          'timeoutSeconds': {
            'type': 'integer',
            'description': 'Timeout in seconds (1-120, default 30)',
          },
          'maxOutputBytes': {
            'type': 'integer',
            'description': 'Max stdout/stderr bytes (default 65536)',
          },
        },
        'required': ['hostId', 'command'],
        'additionalProperties': false,
      },
    ),
    _ToolSpec(
      name: 'sftp_list',
      description: 'List files and directories on a saved host via SFTP.',
      tier: McpPermissionTier.sftpRead,
      inputSchema: {
        'type': 'object',
        'properties': {
          'hostId': {'type': 'string', 'description': 'Target host UUID'},
          'path': {
            'type': 'string',
            'description': 'Remote directory path (defaults to home directory)',
          },
        },
        'required': ['hostId'],
        'additionalProperties': false,
      },
    ),
    _ToolSpec(
      name: 'sftp_stat',
      description: 'Inspect metadata for a remote file or directory via SFTP.',
      tier: McpPermissionTier.sftpRead,
      inputSchema: {
        'type': 'object',
        'properties': {
          'hostId': {'type': 'string', 'description': 'Target host UUID'},
          'path': {'type': 'string', 'description': 'Remote path'},
        },
        'required': ['hostId', 'path'],
        'additionalProperties': false,
      },
    ),
    _ToolSpec(
      name: 'sftp_read',
      description: 'Read a remote UTF-8 text file via SFTP (bounded size).',
      tier: McpPermissionTier.sftpRead,
      inputSchema: {
        'type': 'object',
        'properties': {
          'hostId': {'type': 'string', 'description': 'Target host UUID'},
          'path': {'type': 'string', 'description': 'Remote file path'},
          'maxBytes': {
            'type': 'integer',
            'description': 'Max bytes to read (default 65536, max 262144)',
          },
        },
        'required': ['hostId', 'path'],
        'additionalProperties': false,
      },
    ),
    _ToolSpec(
      name: 'sftp_write',
      description: 'Write UTF-8 text content to a remote file via SFTP.',
      tier: McpPermissionTier.sftpWrite,
      inputSchema: {
        'type': 'object',
        'properties': {
          'hostId': {'type': 'string', 'description': 'Target host UUID'},
          'path': {'type': 'string', 'description': 'Remote file path'},
          'content': {'type': 'string', 'description': 'UTF-8 content to write'},
        },
        'required': ['hostId', 'path', 'content'],
        'additionalProperties': false,
      },
    ),
    _ToolSpec(
      name: 'sftp_sync',
      description:
          'Rsync-style directory synchronization between an allowed local folder and a saved host via SFTP.',
      tier: McpPermissionTier.sftpRead,
      inputSchema: {
        'type': 'object',
        'properties': {
          'hostId': {'type': 'string', 'description': 'Target host UUID'},
          'direction': {
            'type': 'string',
            'enum': ['push', 'pull'],
            'description': 'push (local -> remote) or pull (remote -> local)',
          },
          'localPath': {'type': 'string', 'description': 'Local folder path'},
          'remotePath': {'type': 'string', 'description': 'Remote folder path'},
          'exclude': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Optional glob patterns to exclude',
          },
          'dryRun': {
            'type': 'boolean',
            'description': 'Preview diff without transferring or deleting',
          },
          'delete': {
            'type': 'boolean',
            'description': 'Delete extra files in destination',
          },
        },
        'required': ['hostId', 'direction', 'localPath', 'remotePath'],
        'additionalProperties': false,
      },
    ),
  ];

  List<Map<String, dynamic>> listTools(McpAgentToken? agent) {
    return [
      for (final s in _specs)
        if (agent == null || agent.tier.allows(s.tier)) s.toJson(),
    ];
  }

  List<Map<String, dynamic>> listResources(McpAgentToken? agent) {
    if (agent != null && !agent.tier.allows(McpPermissionTier.discover)) {
      return const [];
    }
    return const [
      {
        'uri': 'marsa://hosts',
        'name': 'Unlocked Vault Hosts',
        'description': 'Metadata of hosts in unlocked Marsa vaults.',
        'mimeType': 'application/json',
      },
      {
        'uri': 'marsa://snippets',
        'name': 'Saved Snippets',
        'description': 'Saved command snippets in unlocked Marsa vaults.',
        'mimeType': 'application/json',
      },
    ];
  }

  Future<Map<String, dynamic>> readResource(
    String uri,
    McpAgentToken agent,
  ) async {
    if (uri == 'marsa://hosts') {
      final hosts = _discoverHosts(agent, const {});
      return {
        'contents': [
          {
            'uri': uri,
            'mimeType': 'application/json',
            'text': jsonEncode(hosts),
          },
        ],
      };
    }
    if (uri == 'marsa://snippets') {
      final snippets = _discoverSnippets(agent);
      return {
        'contents': [
          {
            'uri': uri,
            'mimeType': 'application/json',
            'text': jsonEncode(snippets),
          },
        ],
      };
    }
    if (uri.startsWith('marsa://hosts/')) {
      final id = uri.substring('marsa://hosts/'.length);
      final (vault, host) = _resolveHost(agent, id);
      return {
        'contents': [
          {
            'uri': uri,
            'mimeType': 'application/json',
            'text': jsonEncode(_hostMetadata(vault, host)),
          },
        ],
      };
    }
    throw McpToolError('RESOURCE_NOT_FOUND', 'Unknown resource: $uri');
  }

  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> args,
    McpAgentToken agent,
  ) async {
    final spec = _specs.where((s) => s.name == name).firstOrNull;
    if (spec == null) {
      throw McpToolError('TOOL_NOT_FOUND', 'Unknown tool: $name');
    }
    if (!agent.tier.allows(spec.tier)) {
      await _audit(
        agent: agent,
        toolName: name,
        status: McpAuditStatus.denied,
        durationMs: 0,
        hostId: args['hostId'] as String?,
        detail: 'Insufficient tier (${agent.tier.name} < ${spec.tier.name})',
      );
      throw McpToolError(
        'PERMISSION_DENIED',
        'Token tier "${agent.tier.name}" does not allow "$name"',
      );
    }

    final sw = Stopwatch()..start();
    auditLog.beginRequest();
    String? vaultId;
    String? hostId = args['hostId'] as String?;
    String? hostLabel;
    try {
      final dynamic result;
      switch (name) {
        case 'list_hosts':
          result = {'hosts': _discoverHosts(agent, args)};
        case 'get_host':
          final id = _reqString(args, 'hostId');
          final (v, h) = _resolveHost(agent, id);
          vaultId = v.info.id;
          hostId = h.id;
          hostLabel = h.title;
          result = _hostMetadata(v, h);
        case 'list_identities':
          result = {'identities': _discoverIdentities(agent)};
        case 'list_snippets':
          result = {'snippets': _discoverSnippets(agent)};
        case 'create_snippet':
          final created = await _createSnippet(agent, args);
          vaultId = created['vaultId'] as String?;
          result = created;
        case 'list_port_forwards':
          result = {'forwards': _discoverPortForwards(agent)};
        case 'create_port_forward':
          final created = await _createPortForward(agent, args);
          vaultId = created['vaultId'] as String?;
          hostId = created['hostId'] as String?;
          result = created;
        case 'ssh_exec':
          final id = _reqString(args, 'hostId');
          final cmd = _reqString(args, 'command');
          final (v, h) = _resolveHost(agent, id);
          vaultId = v.info.id;
          hostId = h.id;
          hostLabel = h.title;
          await _requireConsent(agent, name, h, 'Run command: $cmd');
          result = await _sshExec(agent, v, h, cmd, args);
        case 'sftp_list':
          final id = _reqString(args, 'hostId');
          final (v, h) = _resolveHost(agent, id);
          vaultId = v.info.id;
          hostId = h.id;
          hostLabel = h.title;
          await _requireConsent(
            agent,
            name,
            h,
            'List directory: ${args['path'] ?? '~'}',
          );
          result = await _sftpList(v, h, args['path'] as String?);
        case 'sftp_stat':
          final id = _reqString(args, 'hostId');
          final path = _reqString(args, 'path');
          final (v, h) = _resolveHost(agent, id);
          vaultId = v.info.id;
          hostId = h.id;
          hostLabel = h.title;
          await _requireConsent(agent, name, h, 'Stat path: $path');
          result = await _sftpStat(v, h, path);
        case 'sftp_read':
          final id = _reqString(args, 'hostId');
          final path = _reqString(args, 'path');
          final (v, h) = _resolveHost(agent, id);
          vaultId = v.info.id;
          hostId = h.id;
          hostLabel = h.title;
          await _requireConsent(agent, name, h, 'Read file: $path');
          result = await _sftpRead(v, h, path, args);
        case 'sftp_write':
          final id = _reqString(args, 'hostId');
          final path = _reqString(args, 'path');
          final content = _reqString(args, 'content');
          final (v, h) = _resolveHost(agent, id);
          vaultId = v.info.id;
          hostId = h.id;
          hostLabel = h.title;
          await _requireConsent(
            agent,
            name,
            h,
            'Write ${utf8.encode(content).length} bytes to: $path',
          );
          result = await _sftpWrite(v, h, path, content);
        case 'sftp_sync':
          final id = _reqString(args, 'hostId');
          final direction = _reqString(args, 'direction');
          final localPath = _reqString(args, 'localPath');
          final remotePath = _reqString(args, 'remotePath');
          final (v, h) = _resolveHost(agent, id);
          vaultId = v.info.id;
          hostId = h.id;
          hostLabel = h.title;
          result = await _sftpSync(
            agent,
            v,
            h,
            direction: direction,
            localPath: localPath,
            remotePath: remotePath,
            args: args,
          );
        default:
          throw McpToolError('TOOL_NOT_FOUND', 'Unknown tool: $name');
      }

      await _audit(
        agent: agent,
        toolName: name,
        status: McpAuditStatus.ok,
        durationMs: sw.elapsedMilliseconds,
        vaultId: vaultId,
        hostId: hostId,
        hostLabel: hostLabel,
        argsSummary: _redactArgs(args),
      );
      return {
        'content': [
          {'type': 'text', 'text': jsonEncode(result)},
        ],
        'isError': false,
      };
    } on McpToolError catch (e) {
      await _audit(
        agent: agent,
        toolName: name,
        status: e.code == 'PERMISSION_DENIED' || e.code == 'CONSENT_DENIED'
            ? McpAuditStatus.denied
            : McpAuditStatus.error,
        durationMs: sw.elapsedMilliseconds,
        vaultId: vaultId,
        hostId: hostId,
        hostLabel: hostLabel,
        argsSummary: _redactArgs(args),
        detail: e.message,
      );
      rethrow;
    } catch (e) {
      await _audit(
        agent: agent,
        toolName: name,
        status: McpAuditStatus.error,
        durationMs: sw.elapsedMilliseconds,
        vaultId: vaultId,
        hostId: hostId,
        hostLabel: hostLabel,
        argsSummary: _redactArgs(args),
        detail: e.toString(),
      );
      return {
        'content': [
          {'type': 'text', 'text': 'Error: $e'},
        ],
        'isError': true,
      };
    } finally {
      auditLog.endRequest();
    }
  }

  List<VaultSession> _unlockedVaults() {
    final vaults = vaultsProvider();
    if (vaults.isEmpty) {
      throw McpToolError('VAULT_LOCKED', 'No unlocked Marsa vault is available.');
    }
    return vaults;
  }

  (VaultSession, Host) _resolveHost(McpAgentToken agent, String hostId) {
    final vaults = _unlockedVaults();
    for (final v in vaults) {
      final host = v.data.hosts[hostId];
      if (host != null) {
        if (!tokenStore.isHostAllowed(agent, v.info.id, host)) {
          throw McpToolError(
            'PERMISSION_DENIED',
            'Agent "${agent.name}" is not allowed to access host "${host.title}"',
          );
        }
        return (v, host);
      }
    }
    throw McpToolError('HOST_NOT_FOUND', 'Host "$hostId" not found in unlocked vaults.');
  }

  List<Map<String, dynamic>> _discoverHosts(
    McpAgentToken agent,
    Map<String, dynamic> args,
  ) {
    final group = (args['group'] as String?)?.trim().toLowerCase();
    final tag = (args['tag'] as String?)?.trim().toLowerCase();
    final query = (args['query'] as String?)?.trim().toLowerCase();
    final out = <Map<String, dynamic>>[];

    for (final v in _unlockedVaults()) {
      if (!tokenStore.isVaultAllowed(agent, v.info.id)) continue;
      for (final h in v.data.hosts.all) {
        if (!tokenStore.isHostAllowed(agent, v.info.id, h)) continue;
        if (group != null &&
            group.isNotEmpty &&
            h.group.toLowerCase() != group) {
          continue;
        }
        if (tag != null &&
            tag.isNotEmpty &&
            !h.tags.any((t) => t.toLowerCase() == tag)) {
          continue;
        }
        if (query != null &&
            query.isNotEmpty &&
            !h.label.toLowerCase().contains(query) &&
            !h.address.toLowerCase().contains(query)) {
          continue;
        }
        out.add(_hostMetadata(v, h));
      }
    }
    return out;
  }

  Map<String, dynamic> _hostMetadata(VaultSession vault, Host host) {
    final creds = vault.data.credentialsFor(host);
    final authType = host.useDeviceKeys
        ? 'deviceKeys'
        : creds.key != null
        ? 'key'
        : creds.password.isNotEmpty
        ? 'password'
        : host.identityId != null
        ? 'identity'
        : 'none';
    return {
      'id': host.id,
      'vaultId': vault.info.id,
      'vaultName': vault.info.name,
      'label': host.label,
      'title': host.title,
      'address': host.address,
      'port': host.port,
      'username': creds.username,
      'group': host.group,
      'tags': host.tags,
      'jumpHostId': host.jumpHostId,
      'useDeviceKeys': host.useDeviceKeys,
      'authType': authType,
    };
  }

  List<Map<String, dynamic>> _discoverIdentities(McpAgentToken agent) {
    final out = <Map<String, dynamic>>[];
    for (final v in _unlockedVaults()) {
      if (!tokenStore.isVaultAllowed(agent, v.info.id)) continue;
      for (final id in v.data.identities.all) {
        out.add({
          'id': id.id,
          'vaultId': v.info.id,
          'label': id.label,
          'username': id.username,
          'hasKey': id.keyId != null,
          'hasPassword': id.password.isNotEmpty,
        });
      }
    }
    return out;
  }

  List<Map<String, dynamic>> _discoverSnippets(McpAgentToken agent) {
    final out = <Map<String, dynamic>>[];
    for (final v in _unlockedVaults()) {
      if (!tokenStore.isVaultAllowed(agent, v.info.id)) continue;
      for (final s in v.data.snippets.all) {
        out.add({
          'id': s.id,
          'vaultId': v.info.id,
          'label': s.label,
          'command': s.command,
        });
      }
    }
    return out;
  }

  Future<void> _requireConsent(
    McpAgentToken agent,
    String toolName,
    Host host,
    String summary,
  ) => _requireConsentForTarget(agent, toolName, host.title, summary);

  Future<void> _requireConsentForTarget(
    McpAgentToken agent,
    String toolName,
    String targetLabel,
    String summary,
  ) async {
    switch (agent.executionPolicy) {
      case McpExecutionPolicy.deny:
        throw McpToolError(
          'POLICY_DENIED',
          'Execution policy for agent "${agent.name}" denies "$toolName" on "$targetLabel".',
        );
      case McpExecutionPolicy.autoApprove:
        return;
      case McpExecutionPolicy.ask:
        break;
    }
    final cb = onConsent;
    if (cb == null) {
      throw McpToolError(
        'CONSENT_DENIED',
        'Interactive approval is required for "$toolName" on "$targetLabel", but no UI prompter is available.',
      );
    }
    final approved = await cb(
      McpConsentRequest(
        agentName: agent.name,
        toolName: toolName,
        hostLabel: targetLabel,
        summary: summary,
      ),
    );
    if (!approved) {
      throw McpToolError(
        'CONSENT_DENIED',
        'User denied "$toolName" on "$targetLabel" for agent "${agent.name}".',
      );
    }
  }

  VaultSession _resolveVault(McpAgentToken agent, String? vaultId) {
    final allowed = _unlockedVaults()
        .where((v) => tokenStore.isVaultAllowed(agent, v.info.id))
        .toList();
    if (allowed.isEmpty) {
      throw McpToolError(
        'PERMISSION_DENIED',
        'Agent "${agent.name}" has no access to any unlocked vault.',
      );
    }
    final requested = vaultId?.trim();
    if (requested != null && requested.isNotEmpty) {
      for (final v in allowed) {
        if (v.info.id == requested) return v;
      }
      throw McpToolError(
        'VAULT_NOT_FOUND',
        'Vault "$requested" is not unlocked or not allowed for agent "${agent.name}".',
      );
    }
    if (allowed.length > 1) {
      throw McpToolError(
        'INVALID_ARGS',
        'Multiple vaults are unlocked; specify "vaultId".',
      );
    }
    return allowed.first;
  }

  Future<Map<String, dynamic>> _createSnippet(
    McpAgentToken agent,
    Map<String, dynamic> args,
  ) async {
    final label = _reqString(args, 'label');
    final command = _reqString(args, 'command');
    final v = _resolveVault(agent, args['vaultId'] as String?);
    await _requireConsentForTarget(
      agent,
      'create_snippet',
      v.info.name,
      'Create snippet "$label": $command',
    );
    final snippet = Snippet(label: label, command: command);
    v.data.snippets.put(snippet);
    await v.commit();
    return {
      'id': snippet.id,
      'vaultId': v.info.id,
      'label': snippet.label,
      'command': snippet.command,
    };
  }

  List<Map<String, dynamic>> _discoverPortForwards(McpAgentToken agent) {
    final out = <Map<String, dynamic>>[];
    for (final v in _unlockedVaults()) {
      if (!tokenStore.isVaultAllowed(agent, v.info.id)) continue;
      for (final f in v.data.forwards.all) {
        final host = v.data.hosts[f.hostId];
        if (host != null && !tokenStore.isHostAllowed(agent, v.info.id, host)) {
          continue;
        }
        out.add({
          'id': f.id,
          'vaultId': v.info.id,
          'label': f.label,
          'kind': f.kind.name,
          'hostId': f.hostId,
          'bindHost': f.bindHost,
          'bindPort': f.bindPort,
          'destHost': f.destHost,
          'destPort': f.destPort,
        });
      }
    }
    return out;
  }

  Future<Map<String, dynamic>> _createPortForward(
    McpAgentToken agent,
    Map<String, dynamic> args,
  ) async {
    final hostId = _reqString(args, 'hostId');
    final (v, h) = _resolveHost(agent, hostId);
    final kindRaw = (args['kind'] as String?)?.trim().toLowerCase() ?? 'local';
    final kind = switch (kindRaw) {
      'local' => ForwardKind.local,
      'remote' => ForwardKind.remote,
      'dynamic' => ForwardKind.dynamic,
      _ => throw McpToolError(
        'INVALID_ARGS',
        'Invalid forward kind "$kindRaw". Expected local, remote, or dynamic.',
      ),
    };
    final bindPort = (args['bindPort'] as num?)?.toInt();
    if (bindPort == null || bindPort < 1 || bindPort > 65535) {
      throw McpToolError(
        'INVALID_ARGS',
        'Parameter "bindPort" must be an integer between 1 and 65535.',
      );
    }
    final rawBindHost = (args['bindHost'] as String?)?.trim();
    final bindHost = (rawBindHost == null || rawBindHost.isEmpty)
        ? '127.0.0.1'
        : rawBindHost;

    final rawDestHost = (args['destHost'] as String?)?.trim();
    final destHost = (rawDestHost == null || rawDestHost.isEmpty)
        ? '127.0.0.1'
        : rawDestHost;
    final destPort = (args['destPort'] as num?)?.toInt() ?? 0;
    if (kind != ForwardKind.dynamic && (destPort < 1 || destPort > 65535)) {
      throw McpToolError(
        'INVALID_ARGS',
        'Parameter "destPort" must be an integer between 1 and 65535 for ${kind.name} forwards.',
      );
    }

    final label = (args['label'] as String?)?.trim() ?? '';
    final summary = kind == ForwardKind.dynamic
        ? 'Create dynamic SOCKS forward on $bindHost:$bindPort via ${h.title}'
        : 'Create ${kind.name} forward $bindHost:$bindPort -> $destHost:$destPort via ${h.title}';
    await _requireConsentForTarget(agent, 'create_port_forward', h.title, summary);

    final forward = PortForward(
      label: label,
      kind: kind,
      hostId: h.id,
      bindHost: bindHost,
      bindPort: bindPort,
      destHost: kind == ForwardKind.dynamic ? '' : destHost,
      destPort: kind == ForwardKind.dynamic ? 0 : destPort,
    );
    v.data.forwards.put(forward);
    await v.commit();
    return {
      'id': forward.id,
      'vaultId': v.info.id,
      'label': forward.label,
      'kind': forward.kind.name,
      'hostId': forward.hostId,
      'bindHost': forward.bindHost,
      'bindPort': forward.bindPort,
      'destHost': forward.destHost,
      'destPort': forward.destPort,
    };
  }

  Prompter _prompter() => prompterFactory?.call() ?? McpPrompter();

  Future<Map<String, dynamic>> _sshExec(
    McpAgentToken agent,
    VaultSession vault,
    Host host,
    String command,
    Map<String, dynamic> args,
  ) async {
    final timeoutSec = ((args['timeoutSeconds'] as num?)?.toInt() ??
            defaultTimeoutSeconds)
        .clamp(1, maxTimeoutSeconds);
    final maxBytes = ((args['maxOutputBytes'] as num?)?.toInt() ??
            defaultMaxOutputBytes)
        .clamp(1024, maxAllowedOutputBytes);

    final exec = executions?.start(
      agentId: agent.id,
      agentName: agent.name,
      hostId: host.id,
      hostLabel: host.title,
      command: command,
    );

    Connection? conn;
    try {
      conn = await connector(vault, host, _prompter());
      if (exec != null) {
        executions?.attachKillHandler(exec.id, () async {
          conn?.close();
        });
      }
      final session = await conn.client.execute(command);
      if (exec != null) {
        executions?.attachKillHandler(exec.id, () async {
          session.close();
          conn?.close();
        });
      }
      final stdoutBuf = BytesBuilder(copy: false);
      final stderrBuf = BytesBuilder(copy: false);
      var truncated = false;

      void collect(
        BytesBuilder buf,
        Uint8List chunk,
        void Function(String)? stream,
      ) {
        if (stream != null && chunk.isNotEmpty) {
          stream(utf8.decode(chunk, allowMalformed: true));
        }
        final remaining = maxBytes - buf.length;
        if (remaining <= 0) {
          truncated = true;
          return;
        }
        if (chunk.length > remaining) {
          buf.add(Uint8List.sublistView(chunk, 0, remaining));
          truncated = true;
        } else {
          buf.add(chunk);
        }
      }

      final outSub = session.stdout.listen(
        (c) => collect(
          stdoutBuf,
          c,
          exec == null ? null : (s) => executions?.appendStdout(exec.id, s),
        ),
      );
      final errSub = session.stderr.listen(
        (c) => collect(
          stderrBuf,
          c,
          exec == null ? null : (s) => executions?.appendStderr(exec.id, s),
        ),
      );
      try {
        await session.done.timeout(Duration(seconds: timeoutSec));
      } on TimeoutException {
        session.close();
        if (exec != null) {
          await executions?.finish(
            exec.id,
            status: McpExecutionStatus.timeout,
            errorMessage: 'Command timed out after ${timeoutSec}s',
            truncated: truncated,
          );
        }
        throw McpToolError(
          'TIMEOUT',
          'Command timed out after ${timeoutSec}s on ${host.title}',
        );
      } finally {
        await outSub.cancel();
        await errSub.cancel();
      }

      if (exec != null && exec.status == McpExecutionStatus.killed) {
        throw McpToolError('CANCELLED', 'Execution stopped by user');
      }

      final exitCode = session.exitCode;
      if (exec != null) {
        await executions?.finish(
          exec.id,
          status: (exitCode == null || exitCode == 0)
              ? McpExecutionStatus.ok
              : McpExecutionStatus.error,
          exitCode: exitCode,
          truncated: truncated,
        );
      }

      return {
        'hostId': host.id,
        'exitCode': exitCode,
        'stdout': utf8.decode(stdoutBuf.takeBytes(), allowMalformed: true),
        'stderr': utf8.decode(stderrBuf.takeBytes(), allowMalformed: true),
        'truncated': truncated,
      };
    } on McpToolError {
      rethrow;
    } catch (e) {
      if (exec != null) {
        await executions?.finish(
          exec.id,
          status: exec.status == McpExecutionStatus.killed
              ? McpExecutionStatus.killed
              : McpExecutionStatus.error,
          errorMessage: e.toString(),
        );
      }
      rethrow;
    } finally {
      conn?.close();
    }
  }

  Future<Map<String, dynamic>> _sftpList(
    VaultSession vault,
    Host host,
    String? path,
  ) async {
    final conn = await connector(vault, host, _prompter());
    try {
      final sftp = await conn.client.sftp();
      final files = RemoteFiles(sftp, host.title);
      final target = (path == null || path.trim().isEmpty)
          ? await files.home()
          : path;
      final entries = await files.list(target);
      return {
        'hostId': host.id,
        'path': target,
        'entries': [
          for (final e in entries)
            {
              'name': e.name,
              'isDir': e.isDir,
              'size': e.size,
              if (e.modified != null)
                'modified': e.modified!.toUtc().toIso8601String(),
              if (e.mode != null) 'mode': e.mode!.toRadixString(8),
            },
        ],
      };
    } finally {
      conn.close();
    }
  }

  Future<Map<String, dynamic>> _sftpStat(
    VaultSession vault,
    Host host,
    String path,
  ) async {
    final conn = await connector(vault, host, _prompter());
    try {
      final sftp = await conn.client.sftp();
      final attr = await sftp.stat(path);
      return {
        'hostId': host.id,
        'path': path,
        'isDir': attr.isDirectory,
        'size': attr.size ?? 0,
        if (attr.modifyTime != null)
          'modified': DateTime.fromMillisecondsSinceEpoch(
            attr.modifyTime! * 1000,
            isUtc: true,
          ).toIso8601String(),
        if (attr.mode != null) 'mode': (attr.mode!.value & 0xFFF).toRadixString(8),
      };
    } finally {
      conn.close();
    }
  }

  Future<Map<String, dynamic>> _sftpRead(
    VaultSession vault,
    Host host,
    String path,
    Map<String, dynamic> args,
  ) async {
    final maxBytes = ((args['maxBytes'] as num?)?.toInt() ??
            defaultMaxOutputBytes)
        .clamp(1024, maxAllowedOutputBytes);
    final conn = await connector(vault, host, _prompter());
    try {
      final sftp = await conn.client.sftp();
      final files = RemoteFiles(sftp, host.title);
      final buf = BytesBuilder(copy: false);
      var truncated = false;
      await for (final chunk in files.read(path)) {
        final remaining = maxBytes - buf.length;
        if (remaining <= 0) {
          truncated = true;
          break;
        }
        if (chunk.length > remaining) {
          buf.add(Uint8List.sublistView(chunk, 0, remaining));
          truncated = true;
          break;
        }
        buf.add(chunk);
      }
      final bytes = buf.takeBytes();
      return {
        'hostId': host.id,
        'path': path,
        'bytes': bytes.length,
        'truncated': truncated,
        'content': utf8.decode(bytes, allowMalformed: true),
      };
    } finally {
      conn.close();
    }
  }

  Future<Map<String, dynamic>> _sftpWrite(
    VaultSession vault,
    Host host,
    String path,
    String content,
  ) async {
    final bytes = Uint8List.fromList(utf8.encode(content));
    if (bytes.length > maxAllowedOutputBytes) {
      throw McpToolError(
        'PAYLOAD_TOO_LARGE',
        'Content exceeds $maxAllowedOutputBytes bytes limit.',
      );
    }
    final conn = await connector(vault, host, _prompter());
    try {
      final sftp = await conn.client.sftp();
      final files = RemoteFiles(sftp, host.title);
      await files.write(path, Stream<Uint8List>.value(bytes));
      return {
        'hostId': host.id,
        'path': path,
        'bytesWritten': bytes.length,
      };
    } finally {
      conn.close();
    }
  }

  Future<Map<String, dynamic>> _sftpSync(
    McpAgentToken agent,
    VaultSession vault,
    Host host, {
    required String direction,
    required String localPath,
    required String remotePath,
    required Map<String, dynamic> args,
  }) async {
    if (direction != 'push' && direction != 'pull') {
      throw McpToolError(
        'INVALID_PARAMS',
        'direction must be "push" or "pull"',
      );
    }
    final dryRun = args['dryRun'] as bool? ?? false;
    final delete = args['delete'] as bool? ?? false;
    if (!dryRun && (direction == 'push' || delete)) {
      if (!agent.tier.allows(McpPermissionTier.sftpWrite)) {
        throw McpToolError(
          'PERMISSION_DENIED',
          'Token tier "${agent.tier.name}" cannot perform sftp_sync push/delete',
        );
      }
    }
    if (!tokenStore.isLocalPathAllowed(agent, localPath)) {
      throw McpToolError(
        'PERMISSION_DENIED',
        'Local path "$localPath" is not in allowedLocalPaths for agent "${agent.name}".',
      );
    }

    final exclude = (args['exclude'] as List?)?.cast<String>() ??
        const ['.git', 'node_modules', '.DS_Store'];
    final options = SyncOptions(
      exclude: exclude,
      delete: delete,
      dryRun: dryRun,
    );

    final conn = await connector(vault, host, _prompter());
    try {
      final sftp = await conn.client.sftp();
      final remote = RemoteFiles(sftp, host.title);
      final local = LocalFiles();
      final src = direction == 'push' ? local : remote;
      final dst = direction == 'push' ? remote : local;
      final srcRoot = direction == 'push' ? localPath : remotePath;
      final dstRoot = direction == 'push' ? remotePath : localPath;

      final plan = await planSync(src, srcRoot, dst, dstRoot, options: options);
      if (dryRun || plan.isEmpty) {
        return SyncResult(
          plan: plan,
          dryRun: dryRun,
          copiedCount: 0,
          deletedCount: 0,
          bytesTransferred: 0,
        ).toJson();
      }

      await _requireConsent(
        agent,
        'sftp_sync',
        host,
        'Sync ($direction): $localPath <-> $remotePath '
            '(+${plan.newCount} new, ~${plan.updateCount} updated, '
            '-${plan.deleteCount} deleted, ${plan.totalBytes} bytes)',
      );

      final res = await executeSync(src, dst, plan);
      return res.toJson();
    } finally {
      conn.close();
    }
  }

  static String _reqString(Map<String, dynamic> args, String key) {
    final v = args[key];
    if (v is! String || v.isEmpty) {
      throw McpToolError('INVALID_PARAMS', 'Missing required string "$key"');
    }
    return v;
  }

  static String _redactArgs(Map<String, dynamic> args) {
    final copy = <String, dynamic>{};
    for (final e in args.entries) {
      if (e.key == 'content' && e.value is String) {
        copy[e.key] = '<${(e.value as String).length} chars>';
      } else {
        copy[e.key] = e.value;
      }
    }
    return jsonEncode(copy);
  }

  Future<void> _audit({
    required McpAgentToken agent,
    required String toolName,
    required McpAuditStatus status,
    required int durationMs,
    String? vaultId,
    String? hostId,
    String? hostLabel,
    String? argsSummary,
    String? detail,
  }) => auditLog.record(
    McpAuditEntry(
      timestamp: DateTime.now().millisecondsSinceEpoch,
      agentId: agent.id,
      agentName: agent.name,
      toolName: toolName,
      status: status,
      durationMs: durationMs,
      vaultId: vaultId,
      hostId: hostId,
      hostLabel: hostLabel,
      argsSummary: argsSummary,
      detail: detail,
    ),
  );
}
