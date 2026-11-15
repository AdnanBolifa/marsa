import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marsa/core/vault.dart';
import 'package:marsa/mcp/executions.dart';
import 'package:marsa/mcp/mcp_service.dart';
import 'package:marsa/ssh/sessions.dart';
import 'package:marsa/ui/agent_terminals.dart';
import 'package:marsa/ui/common.dart';
import 'package:marsa/ui/shell.dart';
import 'package:marsa/ui/theme.dart';

void main() {
  test('McpExecutionTracker streams output, bounds size, and persists JSONL', () async {
    final dir = await Directory.systemTemp.createTemp('marsa_exec_test_');
    addTearDown(() => dir.delete(recursive: true));

    final file = File('${dir.path}/mcp_executions.jsonl');
    final tracker = McpExecutionTracker(file: file, maxOutputBytes: 10);

    final exec = tracker.start(
      agentId: 'a1',
      agentName: 'Claude',
      hostId: 'h1',
      hostLabel: 'prod-1',
      command: 'uname -a',
    );
    expect(tracker.activeCount, 1);
    expect(exec.isRunning, isTrue);

    tracker.appendStdout(exec.id, 'Linux 6.8.0-generic');
    tracker.appendStderr(exec.id, 'warn');
    expect(exec.stdout, 'Linux 6.8.');
    expect(exec.stderr, 'warn');
    expect(exec.truncated, isTrue);

    await tracker.finish(exec.id, status: McpExecutionStatus.ok, exitCode: 0);
    expect(tracker.activeCount, 0);
    expect(tracker.history, hasLength(1));

    final reloaded = McpExecutionTracker(file: file, maxOutputBytes: 10);
    await reloaded.load();
    expect(reloaded.history, hasLength(1));
    expect(reloaded.history.single.agentName, 'Claude');
    expect(reloaded.history.single.hostLabel, 'prod-1');
    expect(reloaded.history.single.status, McpExecutionStatus.ok);
    expect(reloaded.history.single.exitCode, 0);
    expect(reloaded.history.single.stdout, 'Linux 6.8.');
  });

  test('McpExecutionTracker.kill invokes onKill and marks execution killed', () async {
    final dir = await Directory.systemTemp.createTemp('marsa_exec_kill_');
    addTearDown(() => dir.delete(recursive: true));

    final tracker = McpExecutionTracker(
      file: File('${dir.path}/mcp_executions.jsonl'),
    );
    var killedCallback = false;
    final exec = tracker.start(
      agentId: 'a1',
      agentName: 'Codex',
      hostId: 'h1',
      hostLabel: 'db-1',
      command: 'tail -f /var/log/syslog',
      onKill: () async {
        killedCallback = true;
      },
    );

    await tracker.kill(exec.id);
    expect(killedCallback, isTrue);
    expect(exec.status, McpExecutionStatus.killed);
    expect(tracker.activeCount, 0);
  });

  testWidgets('AgentTerminalsPage and AppShell render in wide & narrow layouts', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('marsa_ui_exec_');
    addTearDown(() => dir.deleteSync(recursive: true));

    final registry = VaultRegistry(dir);
    final vault = (await tester.runAsync(() async {
      await registry.load();
      return registry.create('TestVault', 'pass1234');
    }))!;
    final ws = Workspace(vault, DialogPrompter());
    final settings = AppSettings(File('${dir.path}/settings.json'));
    final mcpService = McpService(dataDir: dir);

    final runExec = mcpService.executions.start(
      agentId: 'a1',
      agentName: 'Agent-A',
      hostId: 'h1',
      hostLabel: 'app-1',
      command: 'docker ps',
    );
    mcpService.executions.appendStdout(runExec.id, 'CONTAINER ID   IMAGE\n');

    final doneExec = mcpService.executions.start(
      agentId: 'a2',
      agentName: 'Agent-B',
      hostId: 'h2',
      hostLabel: 'db-2',
      command: 'df -h',
    );
    mcpService.executions.appendStdout(doneExec.id, '/dev/sda1  50G  12G\n');
    await tester.runAsync(() async {
      await mcpService.executions.finish(
        doneExec.id,
        status: McpExecutionStatus.ok,
        exitCode: 0,
      );
    });

    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    ws.show(Section.agentTerminals);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: AppShell(
          workspace: ws,
          registry: registry,
          settings: settings,
          onLock: () async {},
          mcpService: mcpService,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Agent Terminals'), findsWidgets);
    expect(find.text('1 active agent command running'), findsOneWidget);
    expect(find.text('docker ps'), findsWidgets);

    // Narrow light layout directly on AgentTerminalsPage
    tester.view.physicalSize = const Size(640, 720);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: AgentTerminalsPage(workspace: ws, mcpService: mcpService),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Agent Terminals'), findsOneWidget);
    expect(find.text('Copy output'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
