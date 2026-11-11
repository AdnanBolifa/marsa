import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marsa/core/models.dart';
import 'package:marsa/core/vault.dart';
import 'package:marsa/ssh/connector.dart';
import 'package:marsa/ssh/sessions.dart';
import 'package:marsa/ui/common.dart';
import 'package:marsa/ui/shell.dart';
import 'package:marsa/ui/theme.dart';
import 'package:xterm/xterm.dart';

class _NoUi implements Prompter {
  @override
  Future<bool> confirmNewHost(String h, String t, String f) async => false;
  @override
  Future<bool> confirmChangedHost(
    String h,
    String t,
    String o,
    String f,
  ) async => false;
  @override
  Future<String?> askSecret(String title, String prompt) async => null;
  @override
  Future<List<String>?> askInteractive(
    String t,
    String i,
    List<SSHUserInfoPrompt> p,
  ) async => null;
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('marsa_term'));
  tearDown(() => tmp.deleteSync(recursive: true));

  testWidgets('terminal text is selected by dragging and copied with Ctrl+C', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final registry = VaultRegistry(tmp);
    final vault = (await tester.runAsync(() async {
      await registry.load();
      return registry.create('T', 'password-1');
    }))!;
    final host = Host(address: 'web-01');
    vault.data.hosts.put(host);
    final settings = AppSettings(File('${tmp.path}/settings.json'));
    final ws = Workspace(vault, DialogPrompter());
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        theme: buildTheme(Brightness.dark),
        home: AppShell(
          workspace: ws,
          registry: registry,
          settings: settings,
          onLock: () async {},
        ),
      ),
    );
    final term = TerminalTab(host, vault, ws.ui);
    // Programs such as tmux or vim turn on mouse reporting; selecting must
    // still work.
    term.terminal.write('\x1b[?1000h\x1b[?1006hhello world\r\nsecond line\r\n');
    ws
      ..add(term)
      ..focus(term);
    await tester.pump(const Duration(milliseconds: 100));

    final view = tester.getRect(find.byType(TerminalView));
    final from = view.topLeft + const Offset(13, 14);
    final gesture = await tester.startGesture(
      from,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 20));
    for (var i = 1; i <= 5; i++) {
      await gesture.moveTo(from + Offset(i * 12.0, 0));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await gesture.up();
    // Output arriving and the screen rebuilding keep the selection.
    term.terminal.write('more output\r\n');
    settings.update(() {});
    await tester.pump(const Duration(milliseconds: 100));
    final selection = term.controller.selection;
    expect(selection, isNotNull);
    final selected = term.terminal.buffer.getText(selection);
    expect(selected, startsWith('hello'));

    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(copied, selected);
    expect(term.controller.selection, isNull);

    ws.closeTab(term);
    await tester.pumpAndSettle();
    await tester.runAsync(vault.lock);
  });

  testWidgets('dragging a selection past the edge scrolls and extends it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final registry = VaultRegistry(tmp);
    final vault = (await tester.runAsync(() async {
      await registry.load();
      return registry.create('T', 'password-1');
    }))!;
    final host = Host(address: 'web-01');
    vault.data.hosts.put(host);
    final settings = AppSettings(File('${tmp.path}/settings.json'));
    final ws = Workspace(vault, DialogPrompter());
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        theme: buildTheme(Brightness.dark),
        home: AppShell(
          workspace: ws,
          registry: registry,
          settings: settings,
          onLock: () async {},
        ),
      ),
    );
    final term = TerminalTab(host, vault, ws.ui);
    for (var i = 0; i < 300; i++) {
      term.terminal.write('line $i\r\n');
    }
    ws
      ..add(term)
      ..focus(term);
    await tester.pump(const Duration(milliseconds: 100));

    // From the last full line, up past the top edge, then hold.
    final view = tester.getRect(find.byType(TerminalView));
    final from = view.bottomLeft + const Offset(13, -40);
    final gesture = await tester.startGesture(
      from,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.moveTo(from - const Offset(0, 30));
    await tester.pump(const Duration(milliseconds: 20));
    final start = term.controller.selection!.begin;
    for (var i = 1; i <= 10; i++) {
      await gesture.moveTo(Offset(from.dx + 30, view.top + 20 - i * 30.0));
      await tester.pump(const Duration(milliseconds: 20));
    }
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    // Moving while scrolled must keep the start where it was.
    await gesture.moveTo(Offset(from.dx + 20, view.top - 200));
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.up();
    await tester.pump();

    final selection = term.controller.selection!;
    expect(selection.begin, start);
    // Reaches well beyond what was on screen when the drag started.
    final lines = selection.begin.y - selection.end.y;
    expect(lines, greaterThan(view.height ~/ 20 + 20));

    ws.closeTab(term);
    await tester.pumpAndSettle();
    await tester.runAsync(vault.lock);
  });

  test('Enter on an ended session connects again', () async {
    final reg = VaultRegistry(tmp);
    await reg.load();
    final vault = await reg.create('T', 'password-1');
    // Nothing listens on port 1, so every attempt ends at once.
    final tab = TerminalTab(
      Host(address: '127.0.0.1', port: 1),
      vault,
      _NoUi(),
    );
    await tab.start();
    expect(tab.state, TabState.closed);

    tab.terminal.keyInput(TerminalKey.keyA);
    expect(tab.state, TabState.closed);
    tab.terminal.keyInput(TerminalKey.enter);
    expect(tab.state, TabState.connecting);
    while (tab.state == TabState.connecting) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(tab.state, TabState.closed);
    tab.dispose();
    await vault.lock();
  });
}
