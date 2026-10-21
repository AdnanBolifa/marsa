import 'package:flutter/material.dart';

import '../core/vault.dart';
import '../ssh/sessions.dart';
import 'common.dart';
import 'devices.dart';
import 'hosts.dart';
import 'keychain.dart';
import 'pages.dart';
import 'settings.dart';
import 'sftp_view.dart';
import 'terminal_view.dart';
import 'theme.dart';

const _sections = {
  Section.hosts: ('Hosts', Icons.dns_outlined),
  Section.keychain: ('Keychain', Icons.key_outlined),
  Section.forwards: ('Port forwarding', Icons.swap_horiz),
  Section.snippets: ('Snippets', Icons.code),
  Section.knownHosts: ('Known hosts', Icons.verified_user_outlined),
};

class AppShell extends StatelessWidget {
  const AppShell({
    super.key,
    required this.workspace,
    required this.registry,
    required this.settings,
    required this.onLock,
  });
  final Workspace workspace;
  final VaultRegistry registry;
  final AppSettings settings;
  final Future<void> Function() onLock;

  Future<void> _lock(BuildContext context) async {
    final ws = workspace;
    final open =
        ws.tabs.length +
        ws.vault.data.forwards.all.where((f) => ws.forwards.isOn(f.id)).length;
    if (open > 0 &&
        !await confirm(
          context,
          'Lock the vault?',
          'This closes $open open session(s) and forward(s).',
          action: 'Lock',
        )) {
      return;
    }
    await onLock();
  }

  Widget _page() => switch (workspace.section) {
    Section.hosts => HostsPage(workspace),
    Section.keychain => KeychainPage(workspace),
    Section.forwards => ForwardsPage(workspace),
    Section.snippets => SnippetsPage(workspace),
    Section.knownHosts => KnownHostsPage(workspace),
    Section.settings => SettingsPage(
      workspace: workspace,
      registry: registry,
      settings: settings,
      onLock: onLock,
    ),
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      workspace,
      workspace.vault,
      workspace.devices,
      registry,
    ]),
    builder: (context, _) {
      final ws = workspace;
      final compact = MediaQuery.sizeOf(context).width < 820;
      return Scaffold(
        body: SafeArea(
          child: Row(
            children: [
              _Sidebar(ws, compact, () => _lock(context)),
              const VerticalDivider(width: 1),
              Expanded(
                child: Column(
                  children: [
                    DeviceBanner(ws),
                    if (ws.tabs.isNotEmpty) _TabStrip(ws),
                    Expanded(
                      child: IndexedStack(
                        index: ws.active == null ? 0 : 1,
                        children: [_page(), _Tiles(ws, settings)],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// The tab views. Tabs in the entry on screen are tiled; the rest are kept
/// alive out of sight, so an SFTP tab still knows its folders when it comes
/// back. Global keys let a view move between tiles without being rebuilt.
class _Tiles extends StatelessWidget {
  const _Tiles(this.ws, this.settings);
  final Workspace ws;
  final AppSettings settings;

  Widget _view(AppTab tab) => KeyedSubtree(
    key: GlobalObjectKey(tab),
    child: tab is TerminalTab
        ? TerminalTabView(tab, settings, visible: tab == ws.active)
        : SftpTabView(ws, tab as SftpTab),
  );

  Widget _node(BuildContext context, Tile tile, bool many) {
    if (tile is TileLeaf) {
      return _TilePane(ws, tile.tab, framed: many, child: _view(tile.tab));
    }
    final split = tile as TileSplit;
    final row = split.axis == TileAxis.row;
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, box) {
        const bar = 5.0;
        final total = (row ? box.maxWidth : box.maxHeight) - bar;
        final first = total * split.ratio;
        return Flex(
          direction: row ? Axis.horizontal : Axis.vertical,
          children: [
            SizedBox(
              width: row ? first : null,
              height: row ? null : first,
              child: _node(context, split.first, true),
            ),
            MouseRegion(
              cursor: row
                  ? SystemMouseCursors.resizeColumn
                  : SystemMouseCursors.resizeRow,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (d) {
                  final moved = row ? d.delta.dx : d.delta.dy;
                  split.ratio = (split.ratio + moved / total).clamp(.15, .85);
                  ws.retile();
                },
                child: Container(
                  width: row ? bar : null,
                  height: row ? null : bar,
                  color: scheme.outlineVariant,
                ),
              ),
            ),
            Expanded(child: _node(context, split.second, true)),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final shown = ws.tiled;
    return Stack(
      children: [
        Offstage(
          child: Stack(
            children: [
              for (final tab in ws.tabs)
                if (!shown.contains(tab)) _view(tab),
            ],
          ),
        ),
        if (ws.layout != null) _node(context, ws.layout!, shown.length > 1),
      ],
    );
  }
}

/// One tile: a tab's view, a slim title bar when several tiles share the
/// screen, and the drop zones that split it when a tab is dragged over.
class _TilePane extends StatefulWidget {
  const _TilePane(
    this.ws,
    this.tab, {
    required this.framed,
    required this.child,
  });
  final Workspace ws;
  final AppTab tab;
  final bool framed;
  final Widget child;

  @override
  State<_TilePane> createState() => _TilePaneState();
}

class _TilePaneState extends State<_TilePane> {
  TileSide? _zone;

  // The edge of this tile the pointer is nearest to.
  TileSide _sideAt(Offset global) {
    final box = context.findRenderObject()! as RenderBox;
    final p = box.globalToLocal(global);
    final x = (p.dx / box.size.width).clamp(0.0, 1.0);
    final y = (p.dy / box.size.height).clamp(0.0, 1.0);
    final nearest = {
      TileSide.left: x,
      TileSide.right: 1 - x,
      TileSide.top: y,
      TileSide.bottom: 1 - y,
    }.entries.reduce((a, b) => a.value <= b.value ? a : b);
    return nearest.key;
  }

  @override
  Widget build(BuildContext context) {
    final ws = widget.ws;
    final tab = widget.tab;
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    final focused = ws.active == tab;
    return DragTarget<AppTab>(
      onWillAcceptWithDetails: (d) => d.data != tab,
      onMove: (d) {
        final zone = _sideAt(d.offset);
        if (zone != _zone) setState(() => _zone = zone);
      },
      onLeave: (_) => setState(() => _zone = null),
      onAcceptWithDetails: (d) {
        final zone = _zone ?? _sideAt(d.offset);
        setState(() => _zone = null);
        ws.split(tab, d.data, zone);
      },
      builder: (context, candidates, _) => Stack(
        children: [
          Listener(
            // Clicking anywhere in a tile gives it the keyboard.
            onPointerDown: (_) {
              if (!focused) ws.focus(tab);
            },
            child: Column(
              children: [
                if (widget.framed)
                  Draggable<AppTab>(
                    data: tab,
                    dragAnchorStrategy: pointerDragAnchorStrategy,
                    feedback: _DragChip(tab),
                    child: Container(
                      height: 26,
                      padding: const EdgeInsets.only(left: 10, right: 2),
                      decoration: BoxDecoration(
                        color: focused
                            ? scheme.surfaceContainerHigh
                            : scheme.surfaceContainerLow,
                        border: Border(
                          top: BorderSide(
                            width: 2,
                            color: focused
                                ? scheme.primary
                                : Colors.transparent,
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            tab is TerminalTab
                                ? Icons.terminal
                                : Icons.folder_copy_outlined,
                            size: 13,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              tab.host.title,
                              overflow: TextOverflow.ellipsis,
                              style: t.textTheme.labelMedium?.copyWith(
                                color: focused
                                    ? scheme.onSurface
                                    : Palette.of(context).muted,
                              ),
                            ),
                          ),
                          _MiniButton(
                            'Move back to its own tab',
                            Icons.open_in_new,
                            () => ws.untile(tab),
                          ),
                          _MiniButton(
                            'Close',
                            Icons.close,
                            () => ws.closeTab(tab),
                          ),
                        ],
                      ),
                    ),
                  ),
                Expanded(child: widget.child),
              ],
            ),
          ),
          if (candidates.isNotEmpty && _zone != null)
            Positioned.fill(
              child: IgnorePointer(
                child: FractionallySizedBox(
                  alignment: switch (_zone!) {
                    TileSide.left => Alignment.centerLeft,
                    TileSide.right => Alignment.centerRight,
                    TileSide.top => Alignment.topCenter,
                    TileSide.bottom => Alignment.bottomCenter,
                  },
                  widthFactor: _zone == TileSide.left || _zone == TileSide.right
                      ? .5
                      : 1,
                  heightFactor:
                      _zone == TileSide.top || _zone == TileSide.bottom
                      ? .5
                      : 1,
                  child: Container(
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: .18),
                      border: Border.all(color: scheme.primary, width: 2),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MiniButton extends StatelessWidget {
  const _MiniButton(this.tip, this.icon, this.onTap);
  final String tip;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tip,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(5),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(icon, size: 13),
      ),
    ),
  );
}

/// What follows the pointer while a tab is being dragged.
class _DragChip extends StatelessWidget {
  const _DragChip(this.tab);
  final AppTab tab;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Material(
      elevation: 6,
      color: t.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              tab is TerminalTab ? Icons.terminal : Icons.folder_copy_outlined,
              size: 15,
            ),
            const SizedBox(width: 8),
            Text(tab.host.title, style: t.textTheme.labelLarge),
          ],
        ),
      ),
    );
  }
}

/// Open sessions as tabs across the top, with the focused tab's actions on
/// the right. Drag a tab onto the area below to tile it beside another.
class _TabStrip extends StatelessWidget {
  const _TabStrip(this.ws);
  final Workspace ws;

  Future<void> _pick(
    BuildContext context,
    Offset at,
    List<PopupMenuEntry<VoidCallback>> items,
  ) async {
    final action = await showMenu<VoidCallback>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: items,
    );
    action?.call();
  }

  Future<void> _menu(BuildContext context, AppTab tab, Offset at) {
    final target = ws.active != null && ws.active != tab
        ? ws.active
        : ws.tiled.where((x) => x != tab).firstOrNull;
    return _pick(context, at, [
      if (target != null) ...[
        PopupMenuItem(
          value: () => ws.split(target, tab, TileSide.right),
          child: Text('Show beside ${target.host.title}'),
        ),
        PopupMenuItem(
          value: () => ws.split(target, tab, TileSide.bottom),
          child: Text('Show below ${target.host.title}'),
        ),
      ],
      PopupMenuItem(value: () => ws.closeTab(tab), child: const Text('Close')),
    ]);
  }

  Future<void> _splitMenu(BuildContext context, Tile page, Offset at) =>
      _pick(context, at, [
        PopupMenuItem(
          value: () => ws.separate(page),
          child: const Text('Separate into tabs'),
        ),
        PopupMenuItem(
          value: () => page.tabs.toList().forEach(ws.closeTab),
          child: Text('Close all ${page.tabs.length}'),
        ),
      ]);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = ws.active;
    final snippets = ws.vault.data.snippets.all.toList()
      ..sort((a, b) => a.label.compareTo(b.label));
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: Palette.of(context).sidebar,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final page in ws.pages)
                  if (page is TileLeaf)
                    ListenableBuilder(
                      listenable: page.tab,
                      builder: (context, _) => GestureDetector(
                        onSecondaryTapUp: (d) =>
                            _menu(context, page.tab, d.globalPosition),
                        child: Draggable<AppTab>(
                          data: page.tab,
                          dragAnchorStrategy: pointerDragAnchorStrategy,
                          feedback: _DragChip(page.tab),
                          child: _Tab(
                            tab: page.tab,
                            selected: page.tab == active,
                            onTap: () => ws.focus(page.tab),
                            onClose: () => ws.closeTab(page.tab),
                          ),
                        ),
                      ),
                    )
                  else
                    GestureDetector(
                      onSecondaryTapUp: (d) =>
                          _splitMenu(context, page, d.globalPosition),
                      child: _SplitTab(
                        page: page,
                        selected: active != null && ws.layout == page,
                        onTap: () => ws.open(page),
                        onSeparate: () => ws.separate(page),
                        onClose: () => page.tabs.toList().forEach(ws.closeTab),
                      ),
                    ),
                IconButton(
                  tooltip: 'New session',
                  icon: const Icon(Icons.add, size: 17),
                  onPressed: () => ws.show(Section.hosts),
                ),
              ],
            ),
          ),
          if (active is TerminalTab) ...[
            PopupMenuButton<String>(
              tooltip: 'Run a snippet',
              enabled: snippets.isNotEmpty,
              icon: const Icon(Icons.code, size: 17),
              onSelected: (cmd) {
                active.send('$cmd\r');
                active.focusNode.requestFocus();
              },
              itemBuilder: (_) => [
                for (final s in snippets)
                  PopupMenuItem(
                    value: s.command,
                    child: Text(
                      s.label.isEmpty ? s.command : s.label,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
            IconButton(
              tooltip: 'Browse this server\'s files (SFTP)',
              icon: const Icon(Icons.folder_copy_outlined, size: 17),
              onPressed: () => ws.openSftp(active.host),
            ),
          ],
          if (active is SftpTab)
            IconButton(
              tooltip: 'Open a terminal on this server',
              icon: const Icon(Icons.terminal, size: 17),
              onPressed: () => ws.openTerminal(active.host),
            ),
          const SizedBox(width: 6),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.tab,
    required this.selected,
    required this.onTap,
    required this.onClose,
  });
  final AppTab tab;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = Palette.of(context);
    final fg = selected ? scheme.onSurface : palette.muted;
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minWidth: 130, maxWidth: 220),
        padding: const EdgeInsets.only(left: 12, right: 6),
        decoration: BoxDecoration(
          color: selected ? scheme.surface : null,
          border: Border(
            top: BorderSide(
              width: 2,
              color: selected ? scheme.primary : Colors.transparent,
            ),
            right: BorderSide(color: scheme.outlineVariant),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: switch (tab.state) {
                  TabState.connected => palette.success,
                  TabState.connecting => palette.warning,
                  TabState.closed => scheme.error,
                },
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              tab is TerminalTab ? Icons.terminal : Icons.folder_copy_outlined,
              size: 15,
              color: fg,
            ),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                tab.host.title,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  color: fg,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Tooltip(
              message: 'Close',
              child: InkWell(
                onTap: onClose,
                borderRadius: BorderRadius.circular(5),
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Icon(Icons.close, size: 14, color: fg),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Several sessions tiled together, shown in the tab strip as one entry.
class _SplitTab extends StatelessWidget {
  const _SplitTab({
    required this.page,
    required this.selected,
    required this.onTap,
    required this.onSeparate,
    required this.onClose,
  });
  final Tile page;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onSeparate;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.onSurface : Palette.of(context).muted;
    final names = [for (final t in page.tabs) t.host.title];
    return Tooltip(
      message: names.join('\n'),
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minWidth: 130, maxWidth: 300),
          padding: const EdgeInsets.only(left: 12, right: 6),
          decoration: BoxDecoration(
            color: selected ? scheme.surface : null,
            border: Border(
              top: BorderSide(
                width: 2,
                color: selected ? scheme.primary : Colors.transparent,
              ),
              right: BorderSide(color: scheme.outlineVariant),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.grid_view_outlined, size: 15, color: fg),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  names.join('  ·  '),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: fg,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${names.length}',
                  style: TextStyle(fontSize: 11, color: fg),
                ),
              ),
              const SizedBox(width: 4),
              Tooltip(
                message: 'Separate into tabs',
                child: InkWell(
                  onTap: onSeparate,
                  borderRadius: BorderRadius.circular(5),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: Icon(Icons.tab_unselected, size: 14, color: fg),
                  ),
                ),
              ),
              Tooltip(
                message: 'Close all ${names.length}',
                child: InkWell(
                  onTap: onClose,
                  borderRadius: BorderRadius.circular(5),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: Icon(Icons.close, size: 14, color: fg),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar(this.ws, this.compact, this.onLock);
  final Workspace ws;
  final bool compact;
  final VoidCallback onLock;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    Widget item(Section s, String label, IconData icon) => _Item(
      icon: icon,
      label: label,
      compact: compact,
      selected: ws.active == null && ws.section == s,
      onTap: () => ws.show(s),
    );
    return Container(
      width: compact ? 56 : 212,
      color: Palette.of(context).sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 4 : 14,
              10,
              compact ? 4 : 4,
              10,
            ),
            child: Row(
              children: [
                if (!compact) ...[
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Icon(
                      Icons.anchor,
                      size: 16,
                      color: scheme.onPrimary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          ws.vault.info.name,
                          overflow: TextOverflow.ellipsis,
                          style: t.textTheme.titleSmall,
                        ),
                        Text(switch (ws.vault.syncState) {
                          SyncState.off => 'This device only',
                          SyncState.idle => 'Synced',
                          SyncState.syncing => 'Syncing…',
                          SyncState.error => 'Sync failed',
                          SyncState.passwordChanged => 'Password changed',
                        }, style: t.textTheme.labelSmall),
                      ],
                    ),
                  ),
                ],
                _SyncButton(ws.vault),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                for (final e in _sections.entries)
                  item(e.key, e.value.$1, e.value.$2),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                item(Section.settings, 'Settings', Icons.settings_outlined),
                _Item(
                  icon: Icons.lock_outline,
                  label: 'Lock vault',
                  compact: compact,
                  selected: false,
                  onTap: onLock,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Item extends StatelessWidget {
  const _Item({
    required this.icon,
    required this.label,
    required this.compact,
    required this.selected,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final bool compact;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.onSurface : Palette.of(context).muted;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Tooltip(
        message: compact ? label : '',
        child: Material(
          color: selected ? scheme.surfaceContainerHigh : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          child: InkWell(
            borderRadius: BorderRadius.circular(7),
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 0 : 10,
                vertical: 8,
              ),
              child: Row(
                mainAxisAlignment: compact
                    ? MainAxisAlignment.center
                    : MainAxisAlignment.start,
                children: [
                  Icon(icon, size: 17, color: selected ? scheme.primary : fg),
                  if (!compact) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        label,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: fg,
                          fontSize: 13,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SyncButton extends StatelessWidget {
  const _SyncButton(this.vault);
  final VaultSession vault;

  Future<void> _tap(BuildContext context) async {
    switch (vault.syncState) {
      case SyncState.off:
        toast(context, 'Sync is off. Turn it on in Settings.');
      case SyncState.passwordChanged:
        final r = await promptFields(
          context,
          'Vault password changed',
          message:
              'The master password was changed on another device. Enter '
              'the new one to keep syncing.',
          labels: ['New master password'],
          obscure: [true],
        );
        if (r == null || !context.mounted) return;
        await busy(context, () => vault.adoptRemotePassword(r.first));
      default:
        await vault.syncNow();
        if (context.mounted) {
          toast(context, vault.syncError ?? 'Vault is in sync');
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color, tip) = switch (vault.syncState) {
      SyncState.off => (Icons.cloud_off_outlined, scheme.outline, 'Not synced'),
      SyncState.idle => (
        Icons.cloud_done_outlined,
        scheme.primary,
        'Synced. Click to sync now.',
      ),
      SyncState.syncing => (Icons.sync, scheme.primary, 'Syncing…'),
      SyncState.error => (
        Icons.sync_problem,
        scheme.error,
        'Sync failed: ${vault.syncError}',
      ),
      SyncState.passwordChanged => (
        Icons.key_off_outlined,
        scheme.error,
        'Password changed on another device',
      ),
    };
    return IconButton(
      tooltip: tip,
      icon: Icon(icon, size: 17, color: color),
      onPressed: vault.syncState == SyncState.syncing
          ? null
          : () => _tap(context),
    );
  }
}
