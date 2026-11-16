import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marsa/core/models.dart';
import 'package:marsa/core/vault.dart';
import 'package:marsa/ssh/connector.dart';
import 'package:marsa/ssh/sessions.dart';
import 'package:marsa/ui/common.dart';
import 'package:marsa/ui/shell.dart';
import 'package:marsa/ui/theme.dart';

class _FakeSession implements SSHSession {
  final StreamController<Uint8List> _stdout = StreamController<Uint8List>();
  final StreamController<Uint8List> _stderr = StreamController<Uint8List>();
  final Completer<void> _done = Completer<void>();
  final List<String> written = [];
  final List<List<int>> rawWritten = [];
  int _cwdState = 0;

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => _stderr.stream;

  @override
  Future<void> get done => _done.future;

  @override
  int? get exitCode => 0;

  @override
  StreamSink<Uint8List> get stdin => throw UnimplementedError();

  @override
  void write(Uint8List data) {
    rawWritten.add(data);
    final text = utf8.decode(data, allowMalformed: true);
    written.add(text);

    // Simulate an interactive PTY echoing the command and evaluating it.
    final markerMatch = RegExp(r'(__MARSA_END_\d+_\d+__):%d').firstMatch(text);
    if (markerMatch != null) {
      final marker = markerMatch.group(1)!;
      final cmdLine = text.split('\n').first.trim();
      _stdout.add(Uint8List.fromList(utf8.encode('$cmdLine\r\n')));
      if (cmdLine == 'cd /tmp') {
        _cwdState = 1;
        _stdout.add(Uint8List.fromList(utf8.encode('$marker:0\r\n')));
      } else if (cmdLine == 'pwd') {
        final out = _cwdState == 1 ? '/tmp' : '/home/user';
        _stdout.add(Uint8List.fromList(utf8.encode('$out\r\n$marker:0\r\n')));
      } else if (cmdLine == 'hang') {
        // Intentionally never emits marker to test timeout + Ctrl-C.
      } else {
        _stdout.add(Uint8List.fromList(utf8.encode('ok:$cmdLine\r\n$marker:0\r\n')));
      }
    }
  }

  void closeRemote() {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void close() {
    closeRemote();
  }

  @override
  void kill(SSHSignal signal) {}

  @override
  void resizeTerminal(int width, int height, [int? pixelWidth, int? pixelHeight]) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeClient implements SSHClient {
  _FakeClient(this.session);
  final _FakeSession session;
  int shellCalls = 0;

  @override
  Future<SSHSession> shell({
    SSHPtyConfig? pty,
    Map<String, String>? environment,
    SSHX11Config? x11,
  }) async {
    shellCalls++;
    return session;
  }

  @override
  Future<void> close() async => session.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('tryParseCommandMarker strips ANSI, command echo, and marker line', () {
    const marker = '__MARSA_END_1_123__';
    const raw =
        '\x1B[32mpwd\x1B[0m\r\n/tmp\r\nprintf "\\n$marker:%d\\n" \$?\r\n$marker:0\r\n';
    final res = tryParseCommandMarker(raw, 'pwd', marker);
    expect(res, isNotNull);
    expect(res!.exitCode, 0);
    expect(res.output, '/tmp');
  });

  test('TerminalTab.run persists shell state, queues commands, handles timeout & session loss', () async {
    final dir = Directory.systemTemp.createTempSync('marsa_shared_term_');
    addTearDown(() => dir.deleteSync(recursive: true));

    final registry = VaultRegistry(dir);
    await registry.load();
    final vault = await registry.create('Work', 'pass1234');
    final host = Host(label: 'box', address: '10.0.0.1', username: 'u');

    final fakeSession = _FakeSession();
    final fakeClient = _FakeClient(fakeSession);

    final tab = TerminalTab(
      host,
      vault,
      DialogPrompter(),
      isAgent: true,
      agentName: 'Claude',
      connector: (_, _, _) async => Connection(fakeClient, const []),
    );

    await tab.start();
    expect(fakeClient.shellCalls, 1);

    // 1. State persistence: cd /tmp then pwd
    final r1 = await tab.run('cd /tmp');
    expect(r1.exitCode, 0);
    final r2 = await tab.run('pwd');
    expect(r2.exitCode, 0);
    expect(r2.output, '/tmp');

    // 2. Sequential queueing
    final f1 = tab.run('first');
    final f2 = tab.run('second');
    final results = await Future.wait([f1, f2]);
    expect(results[0].output, 'ok:first');
    expect(results[1].output, 'ok:second');

    // 3. Timeout sends Ctrl-C and frees the queue
    await expectLater(
      tab.run('hang', timeout: const Duration(milliseconds: 50)),
      throwsA(isA<TimeoutException>()),
    );
    expect(fakeSession.rawWritten.any((b) => b.length == 1 && b[0] == 3), isTrue);

    final afterTimeout = await tab.run('pwd');
    expect(afterTimeout.output, '/tmp');

    // 4. Session loss fails without silently reconnecting
    fakeSession.closeRemote();
    await Future<void>.delayed(Duration.zero);
    await expectLater(
      tab.run('pwd'),
      throwsA(isA<StateError>()),
    );
    expect(fakeClient.shellCalls, 1);

    tab.dispose();
  });

  testWidgets('Workspace.openAgentTerminal reuses tab and shows Agent badge', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('marsa_agent_tab_ui_');
    addTearDown(() => dir.deleteSync(recursive: true));

    final registry = VaultRegistry(dir);
    final vault = (await tester.runAsync(() async {
      await registry.load();
      return registry.create('Work', 'pass1234');
    }))!;
    final host = Host(label: 'prod-1', address: '127.0.0.1', username: 'ops');
    vault.data.hosts.put(host);

    final ws = Workspace(vault, DialogPrompter());
    final settings = AppSettings(File('${dir.path}/settings.json'));

    // Pre-add an agent TerminalTab so start() doesn't try to dial real TCP.
    final t1 = TerminalTab(
      host,
      vault,
      DialogPrompter(),
      isAgent: true,
      agentName: 'Claude',
    );
    ws.add(t1);
    ws.focus(t1);

    final reused = ws.openAgentTerminal(host, agentName: 'Claude');
    expect(identical(reused, t1), isTrue);
    expect(ws.tabs, hasLength(1));

    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: AppShell(
          workspace: ws,
          registry: registry,
          settings: settings,
          onLock: () async {},
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Agent'), findsOneWidget);
    expect(find.text('prod-1'), findsWidgets);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
