import 'package:flutter/material.dart';

import '../mcp/auth.dart';
import '../mcp/mcp_service.dart';
import 'common.dart';
import 'theme.dart';

/// Settings section for managing Marsa's local MCP server, agent tokens, and
/// audit log.
class McpSettingsSection extends StatelessWidget {
  const McpSettingsSection({
    super.key,
    required this.mcpService,
    required this.settings,
  });

  final McpService mcpService;
  final AppSettings settings;

  Future<void> _toggleEnabled(BuildContext context, bool enable) async {
    settings.update(() => settings.mcpEnabled = enable);
    if (enable) {
      await mcpService.start(port: settings.mcpPort);
      if (mcpService.lastError != null && context.mounted) {
        toast(context, 'Failed to start MCP service: ${mcpService.lastError}');
      }
    } else {
      await mcpService.stop();
    }
  }

  Future<void> _changePort(BuildContext context) async {
    final r = await promptFields(
      context,
      'MCP server port',
      message: 'Loopback-only (127.0.0.1). Restarted automatically if running.',
      labels: ['Port (1024-65535)'],
      initial: ['${settings.mcpPort}'],
    );
    if (r == null || !context.mounted) return;
    final parsed = int.tryParse(r.first.trim());
    if (parsed == null || parsed < 1024 || parsed > 65535) {
      toast(context, 'Enter a valid port between 1024 and 65535');
      return;
    }
    settings.update(() => settings.mcpPort = parsed);
    if (mcpService.isRunning) {
      await mcpService.stop();
      await mcpService.start(port: parsed);
    }
  }

  Future<void> _createToken(BuildContext context) async {
    final nameCtrl = TextEditingController(text: 'AI Agent');
    final pathsCtrl = TextEditingController();
    var tier = McpPermissionTier.discover;
    var policy = McpExecutionPolicy.ask;

    final created = await showDialog<
        (String, McpPermissionTier, McpExecutionPolicy, List<String>)?>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('New agent token'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: nameCtrl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Token name',
                    hintText: 'e.g. Claude Desktop, Cursor, CI Bot',
                  ),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<McpPermissionTier>(
                  initialValue: tier,
                  decoration: const InputDecoration(
                    labelText: 'Permission tier',
                  ),
                  items: [
                    for (final t in McpPermissionTier.values)
                      DropdownMenuItem(value: t, child: Text(t.label)),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => tier = v);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: pathsCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Allowed local folders for sftp_sync (optional)',
                    hintText: '/Users/you/Projects, /tmp/deploy',
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Execution level',
                  style: Theme.of(ctx).textTheme.labelMedium,
                ),
                const SizedBox(height: 6),
                SegmentedButton<McpExecutionPolicy>(
                  segments: const [
                    ButtonSegment(
                      value: McpExecutionPolicy.deny,
                      label: Text('Deny'),
                    ),
                    ButtonSegment(
                      value: McpExecutionPolicy.ask,
                      label: Text('Ask'),
                    ),
                    ButtonSegment(
                      value: McpExecutionPolicy.autoApprove,
                      label: Text('Auto approve'),
                    ),
                  ],
                  selected: {policy},
                  onSelectionChanged: (s) => setState(() => policy = s.first),
                ),
                const SizedBox(height: 6),
                Text(
                  switch (policy) {
                    McpExecutionPolicy.deny =>
                      'Blocks ssh_exec, SFTP, and vault write operations.',
                    McpExecutionPolicy.ask =>
                      'Prompts you to approve each execution or write.',
                    McpExecutionPolicy.autoApprove =>
                      'Warning: runs allowed tools automatically without prompting.',
                  },
                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: policy == McpExecutionPolicy.autoApprove
                        ? Theme.of(ctx).colorScheme.error
                        : Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final paths = pathsCtrl.text
                    .split(',')
                    .map((s) => s.trim())
                    .where((s) => s.isNotEmpty)
                    .toList();
                Navigator.pop(
                  ctx,
                  (nameCtrl.text, tier, policy, paths),
                );
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
    nameCtrl.dispose();
    pathsCtrl.dispose();
    if (created == null || !context.mounted) return;

    final (profile, rawToken) = await mcpService.tokenStore.createToken(
      name: created.$1,
      tier: created.$2,
      executionPolicy: created.$3,
      allowedLocalPaths: created.$4,
    );
    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Token for ${profile.name}'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Copy this bearer token now. For security, it will not be shown again.',
              ),
              const SizedBox(height: 12),
              SelectableText(
                rawToken,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ],
          ),
        ),
        actions: [
          OutlinedButton(
            onPressed: () => copyText(ctx, rawToken, 'Agent token'),
            child: const Text('Copy token'),
          ),
          OutlinedButton(
            onPressed: () => copyText(
              ctx,
              mcpService.clientConfigJson(
                port: settings.mcpPort,
                token: rawToken,
              ),
              'MCP config',
            ),
            child: const Text('Copy MCP config'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Future<void> _editToken(BuildContext context, McpAgentToken token) async {
    final nameCtrl = TextEditingController(text: token.name);
    var tier = token.tier;
    var policy = token.executionPolicy;

    final updated =
        await showDialog<(String, McpPermissionTier, McpExecutionPolicy)?>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text('Edit "${token.name}"'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: nameCtrl,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Token name'),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<McpPermissionTier>(
                  initialValue: tier,
                  decoration: const InputDecoration(
                    labelText: 'Permission tier',
                  ),
                  items: [
                    for (final t in McpPermissionTier.values)
                      DropdownMenuItem(value: t, child: Text(t.label)),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => tier = v);
                  },
                ),
                const SizedBox(height: 16),
                Text(
                  'Execution level',
                  style: Theme.of(ctx).textTheme.labelMedium,
                ),
                const SizedBox(height: 6),
                SegmentedButton<McpExecutionPolicy>(
                  segments: const [
                    ButtonSegment(
                      value: McpExecutionPolicy.deny,
                      label: Text('Deny'),
                    ),
                    ButtonSegment(
                      value: McpExecutionPolicy.ask,
                      label: Text('Ask'),
                    ),
                    ButtonSegment(
                      value: McpExecutionPolicy.autoApprove,
                      label: Text('Auto approve'),
                    ),
                  ],
                  selected: {policy},
                  onSelectionChanged: (s) => setState(() => policy = s.first),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(ctx, (nameCtrl.text, tier, policy)),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    nameCtrl.dispose();
    if (updated == null) return;
    await mcpService.tokenStore.updateToken(
      token.id,
      name: updated.$1,
      tier: updated.$2,
      executionPolicy: updated.$3,
    );
  }

  Future<void> _showAuditLog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => ListenableBuilder(
        listenable: mcpService.auditLog,
        builder: (ctx, _) {
          final entries = mcpService.auditLog.entries.reversed.toList();
          return AlertDialog(
            title: const Text('MCP Audit Log'),
            content: SizedBox(
              width: 640,
              height: 400,
              child: entries.isEmpty
                  ? const Center(child: Text('No MCP agent activity recorded yet.'))
                  : ListView.separated(
                      itemCount: entries.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final e = entries[i];
                        final dt = DateTime.fromMillisecondsSinceEpoch(
                          e.timestamp,
                        ).toLocal();
                        final time =
                            '${dt.hour.toString().padLeft(2, '0')}:'
                            '${dt.minute.toString().padLeft(2, '0')}:'
                            '${dt.second.toString().padLeft(2, '0')}';
                        return ListTile(
                          dense: true,
                          title: Text(
                            '${e.agentName} · ${e.toolName}'
                            '${e.hostLabel == null ? '' : ' (${e.hostLabel})'}',
                          ),
                          subtitle: Text(
                            [
                              '$time · ${e.status.name} · ${e.durationMs}ms',
                              if (e.detail != null) e.detail!,
                            ].join(' — '),
                          ),
                        );
                      },
                    ),
            ),
            actions: [
              if (entries.isNotEmpty)
                OutlinedButton(
                  onPressed: () => copyText(
                    ctx,
                    mcpService.auditLog.exportJson(),
                    'Audit log JSON',
                  ),
                  child: const Text('Copy JSON'),
                ),
              if (entries.isNotEmpty)
                OutlinedButton(
                  onPressed: mcpService.auditLog.clear,
                  child: const Text('Clear'),
                ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    final muted = t.extension<Palette>()?.muted ?? scheme.onSurfaceVariant;

    Widget row(String title, String? detail, Widget control, {Color? color}) {
      final label = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
          ),
          if (detail != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                detail,
                style: t.textTheme.bodySmall?.copyWith(color: color ?? muted),
              ),
            ),
        ],
      );
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: LayoutBuilder(
          builder: (context, box) => box.maxWidth < 520
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [label, const SizedBox(height: 10), control],
                )
              : Row(
                  children: [
                    Expanded(child: label),
                    const SizedBox(width: 24),
                    control,
                  ],
                ),
        ),
      );
    }

    return ListenableBuilder(
      listenable: mcpService,
      builder: (context, _) {
        final activeTokens = mcpService.tokenStore.tokens
            .where((tk) => !tk.isRevoked)
            .toList();
        final activeReq = mcpService.auditLog.activeRequestCount;
        final statusText = mcpService.lastError != null
            ? 'Error: ${mcpService.lastError}'
            : mcpService.isRunning
            ? 'Listening on http://127.0.0.1:${mcpService.port}/mcp'
                '${activeReq > 0 ? ' ($activeReq active)' : ''}'
            : 'Off. Enable to let authorized local AI agents connect.';

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
              child: Text(
                'AI Agents (MCP)',
                style: t.textTheme.titleSmall?.copyWith(color: muted),
              ),
            ),
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  row(
                    'MCP service',
                    statusText,
                    Switch(
                      value: settings.mcpEnabled,
                      onChanged: (on) => _toggleEnabled(context, on),
                    ),
                    color: mcpService.lastError != null ? scheme.error : null,
                  ),
                  const Divider(height: 1),
                  row(
                    'Loopback port',
                    '127.0.0.1:${settings.mcpPort}',
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed: () => copyText(
                            context,
                            mcpService.clientConfigJson(port: settings.mcpPort),
                            'MCP client config',
                          ),
                          child: const Text('Copy config'),
                        ),
                        OutlinedButton(
                          onPressed: () => _changePort(context),
                          child: const Text('Change port'),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  row(
                    'Authorized agents',
                    activeTokens.isEmpty
                        ? 'No active agent tokens.'
                        : '${activeTokens.length} active token(s)',
                    FilledButton(
                      onPressed: () => _createToken(context),
                      child: const Text('New token'),
                    ),
                  ),
                  for (final tk in activeTokens) ...[
                    const Divider(height: 1),
                    row(
                      tk.name,
                      '${tk.tier.label} · ${tk.executionPolicy.label}',
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            onPressed: () => _editToken(context, tk),
                            child: const Text('Edit'),
                          ),
                          const SizedBox(width: 4),
                          OutlinedButton(
                            onPressed: () => mcpService.tokenStore.revoke(tk.id),
                            child: const Text('Revoke'),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const Divider(height: 1),
                  row(
                    'Audit log',
                    '${mcpService.auditLog.entries.length} recorded event(s)',
                    OutlinedButton(
                      onPressed: () => _showAuditLog(context),
                      child: const Text('View log'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
