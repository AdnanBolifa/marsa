import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../ssh/sessions.dart';
import 'theme.dart';

class TerminalTabView extends StatefulWidget {
  const TerminalTabView(
    this.tab,
    this.settings, {
    super.key,
    required this.visible,
  });
  final TerminalTab tab;
  final AppSettings settings;
  final bool visible;

  @override
  State<TerminalTabView> createState() => _TerminalTabViewState();
}

class _TerminalTabViewState extends State<TerminalTabView> {
  TerminalTab get _tab => widget.tab;

  final _viewKey = GlobalKey<TerminalViewState>();
  final _scroll = ScrollController();
  // Dragging a selection past the top or bottom edge scrolls the view while
  // the pointer stays there. The package keeps the drag start in pixels, so
  // once the view has scrolled the selection's fixed end is held here.
  Timer? _autoScroll;
  Offset _pointer = Offset.zero;
  CellOffset? _anchor;

  @override
  void dispose() {
    _autoScroll?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (e.kind != PointerDeviceKind.mouse ||
        e.buttons != kPrimaryMouseButton ||
        _tab.controller.selection == null) {
      return;
    }
    _pointer = e.position;
    // After the package's own drag handling, which runs after this listener.
    if (_anchor != null) scheduleMicrotask(_extendSelection);
    final box = _viewKey.currentState?.renderTerminal;
    if (box == null || !box.hasSize) return;
    final y = box.globalToLocal(e.position).dy;
    final outside = y < 0 || y >= box.size.height;
    if (outside) {
      _autoScroll ??= Timer.periodic(
        const Duration(milliseconds: 50),
        (_) => _scrollStep(),
      );
    } else {
      _autoScroll?.cancel();
      _autoScroll = null;
    }
  }

  void _endDrag(PointerEvent _) {
    _autoScroll?.cancel();
    _autoScroll = null;
    _anchor = null;
  }

  void _scrollStep() {
    final box = _viewKey.currentState?.renderTerminal;
    final selection = _tab.controller.selection;
    if (box == null || selection == null || !_scroll.hasClients) return;
    final y = box.globalToLocal(_pointer).dy;
    final below = y >= box.size.height;
    // The selection's begin is where the drag started, whichever way it goes.
    _anchor ??= selection.begin;
    // Faster the further past the edge the pointer is, up to 5 lines a step.
    final past = below ? y - box.size.height : -y;
    final lines = (1 + past ~/ box.lineHeight).clamp(1, 5);
    final p = _scroll.position;
    _scroll.jumpTo(
      (p.pixels + (below ? 1 : -1) * lines * box.lineHeight).clamp(
        p.minScrollExtent,
        p.maxScrollExtent,
      ),
    );
    _extendSelection();
  }

  void _extendSelection() {
    final box = _viewKey.currentState?.renderTerminal;
    final from = _anchor;
    if (box == null || from == null) return;
    final local = box.globalToLocal(_pointer);
    var to = box.getCellOffset(
      Offset(local.dx, local.dy.clamp(0, box.size.height - 1)),
    );
    // As the package does: a forward selection includes the cell under the
    // pointer.
    if (to.x >= from.x) to = CellOffset(to.x + 1, to.y);
    final buffer = _tab.terminal.buffer;
    _tab.controller.setSelection(
      buffer.createAnchorFromOffset(from),
      buffer.createAnchorFromOffset(to),
    );
  }

  @override
  void initState() {
    super.initState();
    if (widget.visible) _tab.focusNode.requestFocus();
  }

  @override
  void didUpdateWidget(TerminalTabView old) {
    super.didUpdateWidget(old);
    // Typing should land in the terminal as soon as its tab is shown.
    if (widget.visible && !old.visible) _tab.focusNode.requestFocus();
  }

  /// Copies the selected text, if any, and clears the selection.
  bool _copy() {
    final selection = _tab.controller.selection;
    if (selection == null) return false;
    Clipboard.setData(
      ClipboardData(text: _tab.terminal.buffer.getText(selection)),
    );
    _tab.controller.clearSelection();
    return true;
  }

  Future<void> _copyOrPaste() async {
    if (_copy()) return;
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    if (clip?.text != null) _tab.terminal.paste(clip!.text!);
  }

  // Ctrl+C copies while text is selected and interrupts otherwise, like
  // Windows Terminal. Ctrl+Shift+C (and Cmd+C on a Mac) always copies.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.keyC ||
        !HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final shift = HardwareKeyboard.instance.isShiftPressed;
    return _copy() || shift ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([_tab, widget.settings]),
      builder: (context, _) {
        final theme = resolveTerminalTheme(
          widget.settings.terminalTheme,
          t.brightness,
        );
        return ColoredBox(
          color: theme.background,
          child: Column(
            children: [
              Expanded(
                child: Listener(
                  onPointerMove: _onPointerMove,
                  onPointerUp: _endDrag,
                  onPointerCancel: _endDrag,
                  child: TerminalView(
                    _tab.terminal,
                    key: _viewKey,
                    scrollController: _scroll,
                    controller: _tab.controller,
                    focusNode: _tab.focusNode,
                    // The package's text-input path is refused by Flutter on
                    // Windows (it attaches without a view), so nothing typed
                    // arrives. Reading key presses directly works everywhere
                    // except for macOS input methods, which keep the text path.
                    hardwareKeyboardOnly: !Platform.isMacOS,
                    theme: theme,
                    textStyle: TerminalStyle(
                      fontSize: widget.settings.fontSize,
                    ),
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    onSecondaryTapDown: (_, _) => _copyOrPaste(),
                    onKeyEvent: _onKey,
                  ),
                ),
              ),
              if (_tab.state == TabState.closed)
                Container(
                  padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLow,
                    border: Border(
                      top: BorderSide(color: scheme.outlineVariant),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.link_off, size: 16, color: scheme.error),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _tab.error ?? 'Session ended',
                          overflow: TextOverflow.ellipsis,
                          style: t.textTheme.bodySmall,
                        ),
                      ),
                      Text(
                        'Press Enter or',
                        style: t.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.tonalIcon(
                        onPressed: _tab.start,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('Reconnect'),
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
