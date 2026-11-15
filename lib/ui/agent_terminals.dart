import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../mcp/executions.dart';
import '../mcp/mcp_service.dart';
import '../ssh/sessions.dart';
import 'common.dart';

class AgentTerminalsPage extends StatefulWidget {
  const AgentTerminalsPage({
    required this.workspace,
    required this.mcpService,
    super.key,
  });

  final Workspace workspace;
  final McpService? mcpService;

  @override
  State<AgentTerminalsPage> createState() => _AgentTerminalsPageState();
}

class _AgentTerminalsPageState extends State<AgentTerminalsPage> {
  String _query = '';
  McpExecutionStatus? _statusFilter;
  String? _selectedId;
  Timer? _ticker;

  McpExecutionTracker? get _tracker => widget.mcpService?.executions;

  @override
  void initState() {
    super.initState();
    _tracker?.addListener(_onTrackerChanged);
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant AgentTerminalsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mcpService != widget.mcpService) {
      oldWidget.mcpService?.executions.removeListener(_onTrackerChanged);
      _tracker?.addListener(_onTrackerChanged);
      _syncTicker();
    }
  }

  @override
  void dispose() {
    _tracker?.removeListener(_onTrackerChanged);
    _ticker?.cancel();
    super.dispose();
  }

  void _onTrackerChanged() {
    _syncTicker();
    if (mounted) setState(() {});
  }

  void _syncTicker() {
    final hasRunning = (_tracker?.activeCount ?? 0) > 0;
    if (hasRunning && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!hasRunning && _ticker != null) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  List<McpCommandExecution> _filtered(List<McpCommandExecution> entries) {
    final q = _query.trim().toLowerCase();
    return entries.where((e) {
      if (_statusFilter != null && e.status != _statusFilter) return false;
      if (q.isEmpty) return true;
      return e.command.toLowerCase().contains(q) ||
          e.hostLabel.toLowerCase().contains(q) ||
          e.agentName.toLowerCase().contains(q) ||
          e.stdout.toLowerCase().contains(q) ||
          e.stderr.toLowerCase().contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final tracker = _tracker;
    if (tracker == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader('Agent Terminals'),
          const Expanded(
            child: EmptyState(
              Icons.smart_toy_outlined,
              'Agent service unavailable',
              'Start the MCP server in Settings to see live agent commands '
                  'and execution history.',
            ),
          ),
        ],
      );
    }

    final entries = _filtered(tracker.all);
    final active = tracker.active;
    final selected = (_selectedId != null ? tracker.byId(_selectedId!) : null) ??
        (entries.isNotEmpty ? entries.first : null);
    final compact = MediaQuery.sizeOf(context).width < 880;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          'Agent Terminals',
          actions: [
            SizedBox(
              width: 240,
              child: TextField(
                decoration: const InputDecoration(
                  hintText: 'Filter by command, host, agent…',
                  prefixIcon: Icon(Icons.search, size: 17),
                  prefixIconConstraints: BoxConstraints(minWidth: 36),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            const SizedBox(width: 8),
            DropdownButton<McpExecutionStatus?>(
              value: _statusFilter,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: null, child: Text('All statuses')),
                DropdownMenuItem(
                  value: McpExecutionStatus.running,
                  child: Text('Running'),
                ),
                DropdownMenuItem(
                  value: McpExecutionStatus.ok,
                  child: Text('Succeeded'),
                ),
                DropdownMenuItem(
                  value: McpExecutionStatus.error,
                  child: Text('Failed'),
                ),
                DropdownMenuItem(
                  value: McpExecutionStatus.killed,
                  child: Text('Stopped'),
                ),
                DropdownMenuItem(
                  value: McpExecutionStatus.timeout,
                  child: Text('Timed out'),
                ),
              ],
              onChanged: (v) => setState(() => _statusFilter = v),
            ),
            if (tracker.history.isNotEmpty) ...[
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => tracker.clearHistory(),
                icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                label: const Text('Clear history'),
              ),
            ],
          ],
        ),
        if (active.isNotEmpty) _ActiveBanner(active: active, tracker: tracker),
        Expanded(
          child: entries.isEmpty
              ? EmptyState(
                  Icons.terminal,
                  tracker.all.isEmpty
                      ? 'No agent commands yet'
                      : 'No matching executions',
                  tracker.all.isEmpty
                      ? 'Commands executed by connected AI agents via ssh_exec '
                            'will stream here in real time.'
                      : 'Try clearing your search or status filter.',
                )
              : compact
              ? Column(
                  children: [
                    Expanded(
                      flex: 2,
                      child: _ExecutionList(
                        entries: entries,
                        selectedId: selected?.id,
                        onSelect: (id) => setState(() => _selectedId = id),
                        onKill: tracker.kill,
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      flex: 3,
                      child: selected == null
                          ? const SizedBox.shrink()
                          : _OutputInspector(
                              execution: selected,
                              workspace: widget.workspace,
                              onKill: () => tracker.kill(selected.id),
                            ),
                    ),
                  ],
                )
              : Row(
                  children: [
                    SizedBox(
                      width: 360,
                      child: _ExecutionList(
                        entries: entries,
                        selectedId: selected?.id,
                        onSelect: (id) => setState(() => _selectedId = id),
                        onKill: tracker.kill,
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: selected == null
                          ? const SizedBox.shrink()
                          : _OutputInspector(
                              execution: selected,
                              workspace: widget.workspace,
                              onKill: () => tracker.kill(selected.id),
                            ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _ActiveBanner extends StatelessWidget {
  const _ActiveBanner({required this.active, required this.tracker});
  final List<McpCommandExecution> active;
  final McpExecutionTracker tracker;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(24, 0, 24, 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: .35),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.primary.withValues(alpha: .35)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${active.length} active agent command${active.length == 1 ? '' : 's'} running',
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          if (active.length == 1)
            TextButton.icon(
              onPressed: () => tracker.kill(active.first.id),
              icon: Icon(Icons.stop_circle_outlined, size: 16, color: scheme.error),
              label: Text('Stop', style: TextStyle(color: scheme.error)),
            ),
        ],
      ),
    );
  }
}

class _ExecutionList extends StatelessWidget {
  const _ExecutionList({
    required this.entries,
    required this.selectedId,
    required this.onSelect,
    required this.onKill,
  });

  final List<McpCommandExecution> entries;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final Future<void> Function(String id) onKill;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, i) {
        final e = entries[i];
        final selected = e.id == selectedId;
        final color = _statusColor(e.status, scheme);
        return Material(
          color: selected
              ? scheme.surfaceContainerHigh
              : scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => onSelect(e.id),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${e.agentName} · ${e.hostLabel}',
                          overflow: TextOverflow.ellipsis,
                          style: t.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Text(
                        _formatDuration(e.duration),
                        style: mono.copyWith(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      if (e.isRunning) ...[
                        const SizedBox(width: 6),
                        InkWell(
                          onTap: () => onKill(e.id),
                          borderRadius: BorderRadius.circular(4),
                          child: Tooltip(
                            message: 'Stop execution',
                            child: Icon(
                              Icons.stop_circle_outlined,
                              size: 16,
                              color: scheme.error,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    e.command,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: mono.copyWith(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _OutputInspector extends StatelessWidget {
  const _OutputInspector({
    required this.execution,
    required this.workspace,
    required this.onKill,
  });

  final McpCommandExecution execution;
  final Workspace workspace;
  final VoidCallback onKill;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    final statusColor = _statusColor(execution.status, scheme);
    final combinedOutput = [
      if (execution.stdout.isNotEmpty) execution.stdout,
      if (execution.stderr.isNotEmpty) '[stderr]\n${execution.stderr}',
    ].join('\n');

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: .15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  _statusLabel(execution),
                  style: t.textTheme.labelSmall?.copyWith(
                    color: statusColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${execution.agentName} on ${execution.hostLabel} · '
                  '${_formatDuration(execution.duration)}',
                  overflow: TextOverflow.ellipsis,
                  style: t.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (execution.isRunning)
                FilledButton.tonalIcon(
                  onPressed: onKill,
                  icon: Icon(
                    Icons.stop_circle_outlined,
                    size: 16,
                    color: scheme.error,
                  ),
                  label: Text(
                    'Stop / Kill',
                    style: TextStyle(color: scheme.error),
                  ),
                ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: combinedOutput.isEmpty
                    ? null
                    : () async {
                        await Clipboard.setData(
                          ClipboardData(text: combinedOutput),
                        );
                        if (context.mounted) {
                          toast(context, 'Output copied to clipboard');
                        }
                      },
                icon: const Icon(Icons.copy, size: 15),
                label: const Text('Copy output'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () async {
                  final host = workspace.vault.data.hosts[execution.hostId];
                  if (host == null) {
                    toast(context, 'Host is no longer in this vault');
                    return;
                  }
                  await Clipboard.setData(
                    ClipboardData(text: execution.command),
                  );
                  workspace.openTerminal(host);
                  if (context.mounted) {
                    toast(
                      context,
                      'Opened ${host.title} terminal (command copied)',
                    );
                  }
                },
                icon: const Icon(Icons.terminal, size: 15),
                label: const Text('Open in terminal'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              '\$ ${execution.command}',
              style: mono.copyWith(fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
          ),
          if (execution.errorMessage != null &&
              execution.errorMessage!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              execution.errorMessage!,
              style: TextStyle(color: scheme.error, fontSize: 12.5),
            ),
          ],
          if (execution.truncated) ...[
            const SizedBox(height: 6),
            Text(
              'Output truncated at capture limit.',
              style: t.textTheme.labelSmall?.copyWith(
                color: scheme.tertiary,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (execution.stdout.isEmpty && execution.stderr.isEmpty)
                      Text(
                        execution.isRunning
                            ? 'Waiting for output…'
                            : '(no output)',
                        style: mono.copyWith(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    if (execution.stdout.isNotEmpty)
                      SelectableText(
                        execution.stdout,
                        style: mono.copyWith(fontSize: 12),
                      ),
                    if (execution.stderr.isNotEmpty) ...[
                      if (execution.stdout.isNotEmpty) const SizedBox(height: 10),
                      Text(
                        'STDERR',
                        style: t.textTheme.labelSmall?.copyWith(
                          color: scheme.error,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        execution.stderr,
                        style: mono.copyWith(
                          fontSize: 12,
                          color: scheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Color _statusColor(McpExecutionStatus status, ColorScheme scheme) =>
    switch (status) {
      McpExecutionStatus.running => scheme.primary,
      McpExecutionStatus.ok => Colors.green,
      McpExecutionStatus.error => scheme.error,
      McpExecutionStatus.killed => Colors.orange,
      McpExecutionStatus.timeout => Colors.amber,
    };

String _statusLabel(McpCommandExecution e) => switch (e.status) {
  McpExecutionStatus.running => 'RUNNING',
  McpExecutionStatus.ok =>
    e.exitCode == null ? 'OK' : 'EXIT ${e.exitCode}',
  McpExecutionStatus.error =>
    e.exitCode == null ? 'ERROR' : 'EXIT ${e.exitCode}',
  McpExecutionStatus.killed => 'STOPPED',
  McpExecutionStatus.timeout => 'TIMEOUT',
};

String _formatDuration(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds}s';
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  return '${m}m ${s.toString().padLeft(2, '0')}s';
}
