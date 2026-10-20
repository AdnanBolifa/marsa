import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart';

import '../core/cloud.dart';
import '../core/models.dart';
import '../core/vault.dart';
import 'connector.dart';
import 'device_access.dart';
import 'device_identity.dart';
import 'device_keys.dart';
import 'files.dart';
import 'forwarding.dart';

enum TabState { connecting, connected, closed }

abstract class AppTab extends ChangeNotifier {
  AppTab(this.host);
  final Host host;
  TabState state = TabState.connecting;
  String? error;
  bool _disposed = false;

  Future<void> start();
  void close();

  void _set(TabState s, [String? err]) {
    if (_disposed) return;
    state = s;
    error = err;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    close();
    super.dispose();
  }
}

class TerminalTab extends AppTab {
  TerminalTab(super.host, this._vault, this._ui) {
    terminal.onOutput = (data) {
      final shell = _shell;
      if (shell != null) return shell.write(utf8.encode(data));
      // Like most terminal apps: Enter on an ended session connects again.
      if (state == TabState.closed && data.contains('\r')) start();
    };
    terminal.onResize = (w, h, pw, ph) => _shell?.resizeTerminal(w, h, pw, ph);
  }

  final VaultSession _vault;
  final Prompter _ui;
  final terminal = Terminal(maxLines: 10000);
  final controller = TerminalController();

  /// Keyboard focus of this tab's terminal view.
  final focusNode = FocusNode();
  Connection? _conn;
  SSHSession? _shell;

  @override
  Future<void> start() async {
    close();
    _set(TabState.connecting);
    terminal.write('Connecting to ${host.address}:${host.port}…\r\n');
    try {
      final conn = _conn = await connect(_vault, host, _ui);
      final shell = _shell = await conn.client.shell(
        pty: SSHPtyConfig(
          width: terminal.viewWidth,
          height: terminal.viewHeight,
        ),
      );
      if (_disposed) return close();
      // Clear the "Connecting…" line so the remote banner starts clean.
      terminal.write('\x1b[2J\x1b[H');
      _set(TabState.connected);
      const decoder = Utf8Decoder(allowMalformed: true);
      shell.stdout.cast<List<int>>().transform(decoder).listen(terminal.write);
      shell.stderr.cast<List<int>>().transform(decoder).listen(terminal.write);
      unawaited(
        shell.done.catchError((_) {}).whenComplete(() {
          if (_shell != shell) return;
          close();
          terminal.write(
            '\r\n\x1b[2m[session closed, press Enter to reconnect]\x1b[0m\r\n',
          );
          _set(TabState.closed);
        }),
      );
    } catch (e) {
      close();
      terminal.write('\x1b[31m$e\x1b[0m\r\n');
      terminal.write('\x1b[2m[press Enter to reconnect]\x1b[0m\r\n');
      _set(TabState.closed, e.toString());
    }
  }

  /// Types [text] into the session, as if pasted.
  void send(String text) =>
      _shell?.write(Uint8List.fromList(utf8.encode(text)));

  @override
  void dispose() {
    focusNode.dispose();
    super.dispose();
  }

  @override
  void close() {
    _shell = null;
    _conn?.close();
    _conn = null;
  }
}

/// One pane of an SFTP tab: this computer, or a server it is connected to.
class SftpSide {
  /// Null means this computer.
  Host? host;
  FileBackend? files;
  TabState state = TabState.connecting;
  String? error;
  Connection? _conn;

  void _drop() {
    files = null;
    _conn?.close();
    _conn = null;
  }
}

/// A two-pane file view. Either pane can show this computer or any saved
/// host, so files can go computer to server or straight from one server to
/// another (relayed through this app; the servers never talk to each other).
class SftpTab extends AppTab {
  SftpTab(super.host, this._vault, this._ui, {FileBackend? local})
    : _local = local ?? LocalFiles();

  final VaultSession _vault;
  final Prompter _ui;
  final FileBackend _local;

  /// Left and right pane. Starts as this computer and the tab's host.
  final sides = [SftpSide(), SftpSide()];

  /// The second pane's files, which is the tab's own host unless changed.
  FileBackend? get remote => sides[1].files;
  set remote(FileBackend? files) => sides[1].files = files;

  @override
  Future<void> start() async {
    if (sides[1].host == null && sides[1].files == null) sides[1].host = host;
    await Future.wait([for (var i = 0; i < 2; i++) show(i, sides[i].host)]);
  }

  /// Points pane [index] at [target] (null for this computer) and connects.
  Future<void> show(int index, Host? target) async {
    final side = sides[index];
    side._drop();
    side
      ..host = target
      ..error = null
      ..state = TabState.connecting;
    _refresh();
    if (target == null) {
      side
        ..files = _local
        ..state = TabState.connected;
      return _refresh();
    }
    try {
      final conn = side._conn = await connect(_vault, target, _ui);
      final files = RemoteFiles(await conn.client.sftp(), target.title);
      // Closed, or switched to something else, while we were connecting.
      if (_disposed || side._conn != conn) return conn.close();
      side
        ..files = files
        ..state = TabState.connected;
      unawaited(
        conn.client.done.catchError((_) {}).whenComplete(() {
          if (side._conn != conn) return;
          side._drop();
          side
            ..state = TabState.closed
            ..error = 'Connection closed';
          _refresh();
        }),
      );
    } catch (e) {
      side._drop();
      side
        ..state = TabState.closed
        ..error = e.toString();
    }
    _refresh();
  }

  // The tab's own status is its least healthy pane.
  void _refresh() {
    final states = sides.map((s) => s.state);
    final bad = sides.where((s) => s.state == TabState.closed).firstOrNull;
    _set(
      bad != null
          ? TabState.closed
          : states.contains(TabState.connecting)
          ? TabState.connecting
          : TabState.connected,
      bad?.error,
    );
  }

  @override
  void close() {
    for (final s in sides) {
      s._drop();
    }
  }
}

enum TileAxis { row, column }

enum TileSide { left, right, top, bottom }

/// The arrangement of tabs on screen: a tab, or two arrangements side by
/// side or stacked. Immutable apart from [TileSplit.ratio].
sealed class Tile {
  Iterable<AppTab> get tabs;

  /// This arrangement with the leaf showing [tab] replaced by [by].
  Tile swap(AppTab tab, Tile by);

  /// This arrangement without [tab]; its neighbour takes the freed space.
  /// Null when nothing is left.
  Tile? without(AppTab tab);
}

class TileLeaf extends Tile {
  TileLeaf(this.tab);
  final AppTab tab;

  @override
  Iterable<AppTab> get tabs => [tab];

  @override
  Tile swap(AppTab tab, Tile by) => tab == this.tab ? by : this;

  @override
  Tile? without(AppTab tab) => tab == this.tab ? null : this;
}

class TileSplit extends Tile {
  TileSplit(this.axis, this.first, this.second, [this.ratio = .5]);
  final TileAxis axis;
  final Tile first;
  final Tile second;

  /// Share of the space given to [first]; changed by dragging the divider.
  double ratio;

  @override
  Iterable<AppTab> get tabs => [...first.tabs, ...second.tabs];

  @override
  Tile swap(AppTab tab, Tile by) =>
      TileSplit(axis, first.swap(tab, by), second.swap(tab, by), ratio);

  @override
  Tile? without(AppTab tab) {
    final a = first.without(tab);
    final b = second.without(tab);
    if (a == null) return b;
    if (b == null) return a;
    return TileSplit(axis, a, b, ratio);
  }
}

enum Section { hosts, keychain, forwards, snippets, knownHosts, settings }

/// Everything that lives while a vault is unlocked: open tabs, running
/// forwards, transfers and which view is showing.
class Workspace extends ChangeNotifier {
  Workspace(this.vault, this.ui, {DeviceIdentity? device})
    : forwards = ForwardManager(vault, ui),
      devices = DeviceAccess(vault, device);

  final VaultSession vault;
  final Prompter ui;
  final ForwardManager forwards;

  /// This device's own key and the other devices using the vault.
  final DeviceAccess devices;

  /// Registers this device and starts keeping the servers' keys up to date.
  /// Not done in the constructor so tests and previews connect nowhere.
  Future<void> startDevices() async {
    onConnected = (v, host, conn) {
      if (v == vault) devices.connected(host, conn);
    };
    await devices.start();
  }

  final transfers = TransferManager();

  /// The "this computer" side of SFTP views.
  FileBackend localFiles = LocalFiles();
  final List<AppTab> tabs = [];

  Section section = Section.hosts;

  /// The tab with keyboard focus, or null while a section page is showing.
  AppTab? active;

  /// What the tab strip lists: each entry is one tab, or a split holding
  /// several. Every open tab is in exactly one of them.
  final List<Tile> pages = [];

  /// The entry of [pages] on screen; null until a tab has been opened. It is
  /// kept while a section page is showing so coming back restores the split.
  Tile? layout;

  /// The tabs on screen in [layout], left to right, top to bottom.
  List<AppTab> get tiled => [...?layout?.tabs];

  Tile? _pageOf(AppTab tab) =>
      pages.where((p) => p.tabs.contains(tab)).firstOrNull;

  // Arrangements are immutable, so changing one means replacing it.
  void _swapPage(Tile old, Tile? by) {
    final i = pages.indexOf(old);
    by == null ? pages.removeAt(i) : pages[i] = by;
    if (layout == old) layout = by;
  }

  void show(Section s) {
    section = s;
    active = null;
    notifyListeners();
  }

  /// Gives [tab] focus, bringing the split it lives in on screen.
  void focus(AppTab tab) {
    final page = _pageOf(tab);
    if (page == null) return;
    layout = page;
    active = tab;
    notifyListeners();
  }

  /// Brings [page] on screen, focusing its first tab unless one of its tabs
  /// already has focus.
  void open(Tile page) {
    if (!pages.contains(page)) return;
    layout = page;
    if (!page.tabs.contains(active)) active = page.tabs.first;
    notifyListeners();
  }

  /// Places [tab] beside [target], on the given [side] of it, splitting the
  /// space [target] had. The tab leaves wherever it was before.
  void split(AppTab target, AppTab tab, TileSide side) {
    final from = _pageOf(tab);
    if (tab == target || from == null || _pageOf(target) == null) return;
    _swapPage(from, from.without(tab));
    final page = _pageOf(target)!;
    final moved = TileLeaf(tab);
    final before = side == TileSide.left || side == TileSide.top;
    final next = page.swap(
      target,
      TileSplit(
        side == TileSide.left || side == TileSide.right
            ? TileAxis.row
            : TileAxis.column,
        before ? moved : TileLeaf(target),
        before ? TileLeaf(target) : moved,
      ),
    );
    _swapPage(page, next);
    layout = next;
    active = tab;
    notifyListeners();
  }

  /// Call after changing a [TileSplit.ratio] so the screen follows.
  void retile() => notifyListeners();

  /// Takes [tab] out of its split and back into the tab strip on its own.
  void untile(AppTab tab) {
    final page = _pageOf(tab);
    if (page == null || page is TileLeaf) return;
    final rest = page.without(tab)!;
    _swapPage(page, rest);
    pages.insert(pages.indexOf(rest) + 1, TileLeaf(tab));
    if (active == tab) active = rest.tabs.first;
    notifyListeners();
  }

  /// Breaks the split [page] up into one tab strip entry per tab.
  void separate(Tile page) {
    final i = pages.indexOf(page);
    if (i < 0 || page is TileLeaf) return;
    final leaves = [for (final t in page.tabs) TileLeaf(t)];
    pages.replaceRange(i, i + 1, leaves);
    if (layout == page) {
      layout = leaves.firstWhere(
        (l) => l.tab == active,
        orElse: () => leaves.first,
      );
      if (active != null) active = (layout! as TileLeaf).tab;
    }
    notifyListeners();
  }

  /// Adds [tab] as its own entry in the tab strip.
  void add(AppTab tab) {
    tabs.add(tab);
    pages.add(TileLeaf(tab));
  }

  void _open(AppTab tab) {
    add(tab);
    focus(tab);
    tab.start();
  }

  void openTerminal(Host h) => _open(TerminalTab(h, vault, ui));
  void openSftp(Host h) => _open(SftpTab(h, vault, ui, local: localFiles));

  void closeTab(AppTab tab) {
    final page = _pageOf(tab);
    if (page == null) return;
    final i = pages.indexOf(page);
    tabs.remove(tab);
    _swapPage(page, page.without(tab));
    if (layout == null && pages.isNotEmpty) {
      // The entry on screen closed: show its neighbour instead.
      layout = pages[i.clamp(0, pages.length - 1)];
    }
    if (active == tab) active = tiled.firstOrNull;
    tab.dispose();
    notifyListeners();
  }

  Future<void> shutdown() async {
    for (final t in tabs.toList()) {
      t.dispose();
    }
    tabs.clear();
    pages.clear();
    layout = null;
    active = null;
    await forwards.stopAll();
    onConnected = null;
    devices.dispose();
    DeviceKeys.lock();
    Cloud.forgetSessions();
    await vault.lock();
  }
}
