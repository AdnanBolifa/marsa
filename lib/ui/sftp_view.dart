import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../platform/sandbox.dart';
import '../ssh/file_sync.dart';
import '../ssh/files.dart';
import '../ssh/sessions.dart';
import 'common.dart';

/// One side of the SFTP view: where it is, what is there, what is ticked.
class PaneController extends ChangeNotifier {
  PaneController(this.backend);
  final FileBackend backend;

  String path = '';
  List<FileEntry> entries = [];
  final Set<String> selected = {};
  bool loading = true;
  bool showHidden = false;
  String? error;
  bool _disposed = false;

  Iterable<FileEntry> get visible =>
      showHidden ? entries : entries.where((e) => !e.name.startsWith('.'));

  int _opening = 0;

  Future<void> open([String? target]) async {
    // Only the latest request counts: a slow listing that finishes after a
    // newer one must not take the pane back to where it was.
    final ticket = ++_opening;
    loading = true;
    error = null;
    _notify();
    try {
      final dest = target ?? (path.isEmpty ? await backend.home() : path);
      final list = await backend.list(dest);
      if (ticket != _opening) return;
      list.sort(
        (a, b) => a.isDir != b.isDir
            ? (a.isDir ? -1 : 1)
            : a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
      if (dest != path) selected.clear();
      path = dest;
      entries = list;
      selected.retainAll(list.map((e) => e.name));
    } catch (e) {
      if (ticket != _opening) return;
      // Stay where we were; only the attempted folder failed.
      error = e.toString();
    }
    loading = false;
    _notify();
  }

  String? _lastClick;
  DateTime _lastClickAt = DateTime(0);

  /// Records a click on [name] and says whether it completes a double click.
  bool doubleClick(String name) {
    final now = DateTime.now();
    final twice =
        _lastClick == name && now.difference(_lastClickAt) <= kDoubleTapTimeout;
    _lastClick = twice ? null : name;
    _lastClickAt = now;
    return twice;
  }

  void toggle(String name) {
    selected.contains(name) ? selected.remove(name) : selected.add(name);
    _notify();
  }

  void setHidden(bool v) {
    showHidden = v;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Files being dragged out of a pane.
class FileDrag {
  FileDrag(this.pane, this.items);
  final PaneController pane;
  final List<FileEntry> items;
}

class SftpTabView extends StatefulWidget {
  const SftpTabView(this.ws, this.tab, {super.key});
  final Workspace ws;
  final SftpTab tab;

  @override
  State<SftpTabView> createState() => _SftpTabViewState();
}

class _SftpTabViewState extends State<SftpTabView> {
  final List<PaneController?> _panes = [null, null];

  @override
  void initState() {
    super.initState();
    widget.tab.addListener(_onTab);
    _onTab();
  }

  // A pane that (re)connected or switched source has new files behind it.
  // Reopen the folder it was showing if it is still the same place.
  void _onTab() {
    for (var i = 0; i < 2; i++) {
      final files = widget.tab.sides[i].files;
      final previous = _panes[i];
      if (files == previous?.backend) continue;
      final same = files != null && previous?.backend.label == files.label;
      _panes[i] = files == null
          ? null
          : (PaneController(files)
              ..open(same && previous!.path.isNotEmpty ? previous.path : null));
      previous?.dispose();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.tab.removeListener(_onTab);
    for (final p in _panes) {
      p?.dispose();
    }
    super.dispose();
  }

  Future<void> _send(PaneController from, PaneController to) => _copy(
    from,
    from.entries.where((e) => from.selected.contains(e.name)).toList(),
    to,
    to.path,
  );

  Future<void> _syncAcross(PaneController from, PaneController to) async {
    final excludeCtrl = TextEditingController(
      text: '.git, node_modules, .DS_Store',
    );
    var deleteExtra = false;
    SyncPlan? plan;
    String? error;
    var scanning = true;
    var running = false;
    var progressText = '';
    double? progressValue;

    List<String> parseExclude() => excludeCtrl.text
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    Future<void> scan(void Function(void Function()) setDlg) async {
      setDlg(() {
        scanning = true;
        error = null;
      });
      try {
        final p = await planSync(
          from.backend,
          from.path,
          to.backend,
          to.path,
          options: SyncOptions(
            exclude: parseExclude(),
            delete: deleteExtra,
            dryRun: true,
          ),
        );
        setDlg(() {
          plan = p;
          scanning = false;
        });
      } catch (e) {
        setDlg(() {
          error = e.toString();
          scanning = false;
        });
      }
    }

    var started = false;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          if (!started) {
            started = true;
            Future.microtask(() => scan(setDlg));
          }
          final p = plan;
          return AlertDialog(
            title: const Text('Sync folder'),
            content: SizedBox(
              width: 480,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'From: ${from.backend.label} (${from.path})\n'
                    'To: ${to.backend.label} (${to.path})',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: excludeCtrl,
                    enabled: !running,
                    decoration: const InputDecoration(
                      labelText: 'Exclude patterns (comma-separated)',
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Delete extra files in destination'),
                    value: deleteExtra,
                    onChanged: running
                        ? null
                        : (v) {
                            deleteExtra = v;
                            scan(setDlg);
                          },
                  ),
                  const SizedBox(height: 8),
                  if (scanning)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 12),
                          Text('Comparing folders...'),
                        ],
                      ),
                    )
                  else if (error != null)
                    Text(
                      error!,
                      style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                    )
                  else if (p != null)
                    Text(
                      p.isEmpty
                          ? 'Folders are already in sync.'
                          : '+${p.newCount} new, ~${p.updateCount} updated, '
                              '-${p.deleteCount} deleted (${_size(p.totalBytes)})',
                    ),
                  if (running) ...[
                    const SizedBox(height: 12),
                    LinearProgressIndicator(value: progressValue),
                    if (progressText.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        progressText,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(ctx).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: running ? null : () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
              if (!running)
                OutlinedButton(
                  onPressed: scanning ? null : () => scan(setDlg),
                  child: const Text('Refresh preview'),
                ),
              FilledButton(
                onPressed: running || scanning || p == null || p.isEmpty
                    ? null
                    : () async {
                        setDlg(() {
                          running = true;
                          error = null;
                        });
                        try {
                          final res = await executeSync(
                            from.backend,
                            to.backend,
                            p,
                            onProgress: (done, total, rel) {
                              if (!ctx.mounted) return;
                              setDlg(() {
                                progressValue = total == 0 ? 1 : done / total;
                                progressText = rel;
                              });
                            },
                          );
                          if (ctx.mounted) Navigator.pop(ctx);
                          if (mounted) {
                            await to.open();
                            if (mounted) {
                              toast(
                                context,
                                'Synced ${res.copiedCount} file(s), '
                                'deleted ${res.deletedCount} item(s)',
                              );
                            }
                          }
                        } catch (e) {
                          if (ctx.mounted) {
                            setDlg(() {
                              running = false;
                              error = e.toString();
                            });
                          }
                        }
                      },
                child: const Text('Sync now'),
              ),
            ],
          );
        },
      ),
    );
    excludeCtrl.dispose();
  }

  /// Copies [items] from [from]'s folder into [dest] on [to]'s side.
  Future<void> _copy(
    PaneController from,
    List<FileEntry> items,
    PaneController to,
    String dest,
  ) async {
    List<FileEntry> there;
    try {
      there = dest == to.path ? to.entries : await to.backend.list(dest);
    } catch (_) {
      there = const [];
    }
    final clash = items
        .where((e) => there.any((x) => x.name == e.name))
        .map((e) => e.name)
        .toList();
    if (!mounted) return;
    if (clash.isNotEmpty &&
        !await confirm(
          context,
          'Replace existing items?',
          '${clash.take(5).join(', ')}${clash.length > 5 ? ' and ${clash.length - 5} more' : ''} '
              'already exist in $dest on ${to.backend.label}. Files '
              'with the same name are overwritten.',
          action: 'Replace',
        )) {
      return;
    }
    from.selected.removeAll(items.map((e) => e.name));
    final src = from.path;
    final jobs = [
      for (final e in items)
        widget.ws.transfers.copy(from.backend, src, e, to.backend, dest),
    ];
    setState(() {});
    await Future.wait(jobs);
    if (mounted && to.path == dest) await to.open();
  }

  /// Moves [items] into the folder [dest] on the same side.
  Future<void> _move(
    PaneController pane,
    List<FileEntry> items,
    String dest,
  ) async {
    final b = pane.backend;
    try {
      final there = await b.list(dest);
      final clash = items.where((e) => there.any((x) => x.name == e.name));
      if (clash.isNotEmpty) {
        if (mounted) toast(context, '${clash.first.name} is already in $dest');
        return;
      }
      for (final e in items) {
        await b.rename(b.join(pane.path, e.name), b.join(dest, e.name));
      }
    } catch (e) {
      if (mounted) toast(context, e.toString());
    }
    await pane.open();
  }

  /// Files dropped on [to] at the folder [dest]: copied from the other
  /// side, moved within the same one.
  Future<void> _drop(FileDrag drag, PaneController to, String dest) {
    if (drag.pane != to) return _copy(drag.pane, drag.items, to, dest);
    if (dest == to.path) return Future.value();
    return _move(to, drag.items, dest);
  }

  /// The pane header: what this side shows, and a menu to show something
  /// else. Value null is this computer; a missing entry means "no change".
  Widget _source(int i) {
    final t = Theme.of(context);
    final side = widget.tab.sides[i];
    final hosts = widget.ws.vault.data.hosts.all.toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return PopupMenuButton<String>(
      tooltip: 'Choose what this side shows',
      position: PopupMenuPosition.under,
      onSelected: (id) => widget.tab.show(
        i,
        id.isEmpty ? null : widget.ws.vault.data.hosts[id],
      ),
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: '',
          child: Row(
            children: [
              Icon(Icons.laptop_mac, size: 16),
              SizedBox(width: 10),
              Text('This computer'),
            ],
          ),
        ),
        if (hosts.isNotEmpty) const PopupMenuDivider(),
        for (final h in hosts)
          PopupMenuItem(
            value: h.id,
            child: Row(
              children: [
                const Icon(Icons.dns_outlined, size: 16),
                const SizedBox(width: 10),
                Flexible(child: Text(h.title, overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              side.host == null ? Icons.laptop_mac : Icons.dns_outlined,
              size: 16,
              color: t.colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                side.host?.title ?? side.files?.label ?? 'This computer',
                overflow: TextOverflow.ellipsis,
                style: t.textTheme.titleSmall,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.unfold_more, size: 15),
          ],
        ),
      ),
    );
  }

  // A side needs room for its header, path, toolbar and a few rows. In a
  // small tile it keeps that height and scrolls instead of being squashed.
  Widget _side(int i) => LayoutBuilder(
    builder: (context, box) => box.maxHeight >= 260
        ? _sideBody(i, box.maxWidth)
        : SingleChildScrollView(
            child: SizedBox(height: 260, child: _sideBody(i, box.maxWidth)),
          ),
  );

  Widget _sideBody(int i, double width) {
    final scheme = Theme.of(context).colorScheme;
    final side = widget.tab.sides[i];
    final pane = _panes[i];
    final other = _panes[1 - i];
    if (pane != null) {
      return _Pane(
        pane,
        _source(i),
        // Arrows point at the other pane: right from the first, left from
        // the second.
        forward: i == 0,
        onSend: other == null ? null : () => _send(pane, other),
        onSync: other == null ? null : () => _syncAcross(pane, other),
        onDrop: (drag, dest) => _drop(drag, pane, dest),
        roomy: width >= 440,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 4),
          child: Align(alignment: Alignment.centerLeft, child: _source(i)),
        ),
        Expanded(
          child: Center(
            child: side.state == TabState.connecting
                ? const CircularProgressIndicator()
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.cloud_off, size: 36, color: scheme.outline),
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 28),
                        child: Text(
                          side.error ?? 'Disconnected',
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () => widget.tab.show(i, side.host),
                        child: const Text('Reconnect'),
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.tab,
    // Sized by the space this view has, not the window: in a narrow tile
    // the two sides stack instead of sitting side by side.
    builder: (context, _) => LayoutBuilder(
      builder: (context, box) {
        final stacked = box.maxWidth < 700;
        final panes = [
          Expanded(child: _side(0)),
          stacked ? const Divider() : const VerticalDivider(width: 1),
          Expanded(child: _side(1)),
        ];
        return Column(
          children: [
            Expanded(
              child: stacked ? Column(children: panes) : Row(children: panes),
            ),
            _Transfers(widget.ws.transfers),
          ],
        );
      },
    ),
  );
}

String _size(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${v.toStringAsFixed(u == 0 || v >= 100 ? 0 : 1)} ${units[u]}';
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _date(DateTime? d) {
  if (d == null) return '';
  String two(int n) => n.toString().padLeft(2, '0');
  final day = '${_months[d.month - 1]} ${d.day}';
  // Like `ls -l`: the time for recent files, the year for old ones.
  return DateTime.now().difference(d).inDays.abs() < 180
      ? '$day, ${two(d.hour)}:${two(d.minute)}'
      : '$day, ${d.year}';
}

class _Pane extends StatelessWidget {
  const _Pane(
    this.pane,
    this.source, {
    required this.forward,
    required this.onSend,
    this.onSync,
    required this.onDrop,
    required this.roomy,
  });
  final PaneController pane;

  /// The header control that names this side and lets it be switched.
  final Widget source;

  /// Whether "copy to the other side" points right (first pane) or left.
  final bool forward;

  /// Null while the other side has nothing to copy to.
  final VoidCallback? onSend;
  final VoidCallback? onSync;

  /// Files dragged here, to land in the folder given.
  final void Function(FileDrag drag, String dest) onDrop;

  /// Wide enough for the permission and date columns.
  final bool roomy;

  Future<void> _guard(BuildContext context, Future<void> Function() op) async {
    try {
      await op();
    } catch (e) {
      if (context.mounted) toast(context, e.toString());
    }
    await pane.open();
  }

  Future<void> _newFolder(BuildContext context) async {
    final r = await promptFields(
      context,
      'New folder',
      labels: ['Name'],
      action: 'Create',
    );
    final name = r?.first.trim() ?? '';
    if (name.isEmpty || !context.mounted) return;
    await _guard(
      context,
      () => pane.backend.mkdir(pane.backend.join(pane.path, name)),
    );
  }

  Future<void> _rename(BuildContext context, FileEntry e) async {
    final r = await promptFields(
      context,
      'Rename',
      labels: ['Name'],
      initial: [e.name],
      action: 'Rename',
    );
    final name = r?.first.trim() ?? '';
    if (name.isEmpty || name == e.name || !context.mounted) return;
    await _guard(
      context,
      () => pane.backend.rename(
        pane.backend.join(pane.path, e.name),
        pane.backend.join(pane.path, name),
      ),
    );
  }

  Future<void> _chmod(BuildContext context, FileEntry e) async {
    final r = await promptFields(
      context,
      'Permissions for ${e.name}',
      labels: ['Octal mode, e.g. 644'],
      initial: [e.mode!.toRadixString(8).padLeft(3, '0')],
      action: 'Apply',
    );
    final mode = int.tryParse(r?.first.trim() ?? '', radix: 8);
    if (r == null || !context.mounted) return;
    if (mode == null || mode > 0xFFF) {
      return toast(context, 'Enter an octal mode such as 644 or 755');
    }
    await _guard(
      context,
      () => pane.backend.chmod(pane.backend.join(pane.path, e.name), mode),
    );
  }

  Future<void> _delete(BuildContext context, List<FileEntry> items) async {
    if (!await confirm(
      context,
      'Delete ${items.length == 1 ? items.first.name : '${items.length} items'}?',
      'This permanently deletes ${items.any((e) => e.isDir) ? 'the selection, including everything inside folders,' : 'the selection'} '
          'from ${pane.backend.label}. It cannot be undone.',
      action: 'Delete',
      danger: true,
    )) {
      return;
    }
    if (!context.mounted) return;
    await _guard(context, () async {
      for (final e in items) {
        await pane.backend.delete(
          pane.backend.join(pane.path, e.name),
          isDir: e.isDir,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    final small = t.textTheme.bodySmall?.copyWith(fontSize: 11.5);
    final head = t.textTheme.labelSmall?.copyWith(letterSpacing: .4);
    return ListenableBuilder(
      listenable: pane,
      builder: (context, _) {
        final items = pane.visible.toList();
        final chosen = pane.entries
            .where((e) => pane.selected.contains(e.name))
            .toList();
        final one = chosen.length == 1 ? chosen.first : null;
        Widget tool(String label, VoidCallback? onTap, {bool danger = false}) =>
            TextButton(
              onPressed: onTap,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 30),
                foregroundColor: danger ? scheme.error : scheme.onSurface,
              ),
              child: Text(label),
            );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 6, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: source,
                    ),
                  ),
                  // The App Store edition only sees folders the user picks.
                  if (Sandbox.on && pane.backend is LocalFiles)
                    IconButton(
                      tooltip: 'Choose a folder…',
                      icon: const Icon(Icons.folder_open_outlined, size: 16),
                      onPressed: () async {
                        final r = await Sandbox.grantFolder(
                          message: 'Choose a folder to browse in Marsa',
                          start: pane.path,
                          button: 'Open',
                        );
                        if (r != null) pane.open(r.path);
                      },
                    ),
                  IconButton(
                    tooltip: 'Parent folder',
                    icon: const Icon(Icons.arrow_upward, size: 16),
                    onPressed: () => pane.open(pane.backend.parent(pane.path)),
                  ),
                  IconButton(
                    tooltip: 'Refresh',
                    icon: const Icon(Icons.refresh, size: 16),
                    onPressed: pane.open,
                  ),
                  IconButton(
                    tooltip: pane.showHidden
                        ? 'Hide dotfiles'
                        : 'Show hidden dotfiles',
                    icon: Icon(
                      pane.showHidden
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      size: 16,
                    ),
                    onPressed: () => pane.setHidden(!pane.showHidden),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: TextField(
                key: ValueKey(pane.path),
                controller: TextEditingController(text: pane.path),
                style: mono.copyWith(fontSize: 12),
                textDirection: TextDirection.ltr,
                decoration: const InputDecoration(
                  hintText: 'Path',
                  prefixIcon: Icon(Icons.folder_open, size: 15),
                  prefixIconConstraints: BoxConstraints(minWidth: 34),
                  contentPadding: EdgeInsets.symmetric(vertical: 9),
                ),
                onSubmitted: pane.open,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 8, 6),
              child: Row(
                children: [
                  FilledButton.tonalIcon(
                    onPressed: chosen.isEmpty ? null : onSend,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 30),
                    ),
                    icon: Icon(
                      forward ? Icons.arrow_forward : Icons.arrow_back,
                      size: 15,
                    ),
                    label: Text(
                      chosen.isEmpty
                          ? 'Copy across'
                          : 'Copy ${chosen.length} across',
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          tool('Sync', onSync),
                          tool('New folder', () => _newFolder(context)),
                          tool(
                            'Rename',
                            one == null ? null : () => _rename(context, one),
                          ),
                          tool(
                            'Permissions',
                            one?.mode == null
                                ? null
                                : () => _chmod(context, one!),
                          ),
                          tool(
                            'Delete',
                            chosen.isEmpty
                                ? null
                                : () => _delete(context, chosen),
                            danger: true,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              height: 26,
              padding: const EdgeInsets.only(right: 14),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                border: Border.symmetric(
                  horizontal: BorderSide(color: scheme.outlineVariant),
                ),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 66),
                  Expanded(child: Text('NAME', style: head)),
                  if (roomy)
                    SizedBox(width: 44, child: Text('MODE', style: head)),
                  SizedBox(
                    width: 70,
                    child: Text('SIZE', textAlign: TextAlign.end, style: head),
                  ),
                  if (roomy)
                    SizedBox(
                      width: 104,
                      child: Text(
                        'MODIFIED',
                        textAlign: TextAlign.end,
                        style: head,
                      ),
                    ),
                ],
              ),
            ),
            if (pane.loading) const LinearProgressIndicator(minHeight: 2),
            if (pane.error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
                child: Text(
                  pane.error!,
                  style: TextStyle(color: scheme.error, fontSize: 12),
                ),
              ),
            Expanded(
              // Files dragged from the other side land in this folder.
              child: DragTarget<FileDrag>(
                onWillAcceptWithDetails: (d) => d.data.pane != pane,
                onAcceptWithDetails: (d) => onDrop(d.data, pane.path),
                builder: (context, candidates, _) => Container(
                  decoration: candidates.isEmpty
                      ? null
                      : BoxDecoration(
                          color: scheme.primary.withValues(alpha: .06),
                          border: Border.all(color: scheme.primary, width: 2),
                        ),
                  child: items.isEmpty && !pane.loading
                      ? Center(child: Text('Empty folder', style: small))
                      : ListView.builder(
                          itemCount: items.length,
                          itemExtent: 32,
                          itemBuilder: (context, i) {
                            final e = items[i];
                            final on = pane.selected.contains(e.name);
                            // Dragging a ticked row takes everything ticked.
                            final dragged = on ? chosen : [e];
                            Widget row(bool target) => InkWell(
                              // One click ticks, a double click opens a folder.
                              onTap: () {
                                if (!pane.doubleClick(e.name)) {
                                  return pane.toggle(e.name);
                                }
                                if (e.isDir) {
                                  pane.open(
                                    pane.backend.join(pane.path, e.name),
                                  );
                                }
                              },
                              child: Container(
                                color: target
                                    ? scheme.primary.withValues(alpha: .24)
                                    : on
                                    ? scheme.primary.withValues(alpha: .12)
                                    : null,
                                padding: const EdgeInsets.only(right: 14),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 40,
                                      child: Transform.scale(
                                        scale: .82,
                                        child: Checkbox(
                                          value: on,
                                          onChanged: (_) => pane.toggle(e.name),
                                        ),
                                      ),
                                    ),
                                    Icon(
                                      e.isDir
                                          ? Icons.folder_rounded
                                          : Icons.insert_drive_file_outlined,
                                      size: 16,
                                      color: e.isDir
                                          ? scheme.primary
                                          : scheme.outline,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        e.name,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 13),
                                      ),
                                    ),
                                    if (roomy)
                                      SizedBox(
                                        width: 44,
                                        child: Text(
                                          e.mode == null
                                              ? ''
                                              : e.mode!
                                                    .toRadixString(8)
                                                    .padLeft(3, '0'),
                                          style: small?.merge(mono),
                                        ),
                                      ),
                                    SizedBox(
                                      width: 70,
                                      child: Text(
                                        e.isDir ? '—' : _size(e.size),
                                        textAlign: TextAlign.end,
                                        style: small,
                                      ),
                                    ),
                                    if (roomy)
                                      SizedBox(
                                        width: 104,
                                        child: Text(
                                          _date(e.modified),
                                          textAlign: TextAlign.end,
                                          style: small,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            );
                            final draggable = Draggable<FileDrag>(
                              data: FileDrag(pane, dragged),
                              dragAnchorStrategy: pointerDragAnchorStrategy,
                              feedback: _DragFiles(dragged),
                              child: e.isDir
                                  // A folder takes files dropped on it, from
                                  // either side, except itself.
                                  ? DragTarget<FileDrag>(
                                      onWillAcceptWithDetails: (d) =>
                                          d.data.pane != pane ||
                                          !d.data.items.any(
                                            (x) => x.name == e.name,
                                          ),
                                      onAcceptWithDetails: (d) => onDrop(
                                        d.data,
                                        pane.backend.join(pane.path, e.name),
                                      ),
                                      builder: (context, candidates, _) =>
                                          row(candidates.isNotEmpty),
                                    )
                                  : row(false),
                            );
                            return draggable;
                          },
                        ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// What follows the pointer while files are dragged.
class _DragFiles extends StatelessWidget {
  const _DragFiles(this.items);
  final List<FileEntry> items;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final folder = items.length == 1 && items.first.isDir;
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
              items.length > 1
                  ? Icons.file_copy_outlined
                  : folder
                  ? Icons.folder_rounded
                  : Icons.insert_drive_file_outlined,
              size: 15,
            ),
            const SizedBox(width: 8),
            Text(
              items.length == 1 ? items.first.name : '${items.length} items',
              style: t.textTheme.labelLarge,
            ),
          ],
        ),
      ),
    );
  }
}

class _Transfers extends StatelessWidget {
  const _Transfers(this.manager);
  final TransferManager manager;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        final list = manager.transfers;
        if (list.isEmpty) return const SizedBox.shrink();
        return Container(
          constraints: const BoxConstraints(maxHeight: 132),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLowest,
            border: Border(top: BorderSide(color: scheme.outlineVariant)),
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Transfers',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                  TextButton(
                    onPressed: manager.clearFinished,
                    child: const Text('Clear finished'),
                  ),
                ],
              ),
              for (final t in list)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Icon(
                        t.error != null
                            ? Icons.error_outline
                            : t.cancelled
                            ? Icons.block
                            : t.done
                            ? Icons.check_circle_outline
                            : Icons.sync,
                        size: 15,
                        color: t.error != null ? scheme.error : scheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: Text(
                          t.error == null ? t.name : '${t.name}: ${t.error}',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      Expanded(
                        child: t.done
                            ? Text(
                                t.direction,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.onSurfaceVariant,
                                ),
                              )
                            : LinearProgressIndicator(
                                value: t.total == null || t.total == 0
                                    ? null
                                    : (t.bytes / t.total!)
                                          .clamp(0, 1)
                                          .toDouble(),
                              ),
                      ),
                      SizedBox(
                        width: 78,
                        child: Text(
                          t.cancelled ? 'cancelled' : _size(t.bytes),
                          textAlign: TextAlign.end,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                      if (!t.done)
                        InkWell(
                          onTap: () => manager.cancel(t),
                          child: const Padding(
                            padding: EdgeInsets.only(left: 6),
                            child: Icon(Icons.close, size: 14),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
