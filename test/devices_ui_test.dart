import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marsa/core/models.dart';
import 'package:marsa/core/vault.dart';
import 'package:marsa/ssh/device_identity.dart';
import 'package:marsa/ssh/keys.dart';
import 'package:marsa/ssh/sessions.dart';
import 'package:marsa/ui/common.dart';
import 'package:marsa/ui/shell.dart';
import 'package:marsa/ui/theme.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('marsa_devices_ui'));
  tearDown(() => tmp.deleteSync(recursive: true));

  testWidgets('a new device is approved from the banner and listed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1300, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final registry = VaultRegistry(Directory('${tmp.path}/vaults'));
    final (vault, me) = (await tester.runAsync(() async {
      await registry.load();
      final v = await registry.create('Team', 'password-1');
      final me = await DeviceIdentity.load(
        FileSecretStore(Directory('${tmp.path}/me')),
        name: 'MacBook',
      );
      return (v, me!);
    }))!;
    // Saving the vault is real file I/O, which only moves on outside the
    // test's fake clock.
    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump();
      }
    }

    final ws = Workspace(vault, DialogPrompter(), device: me);
    await tester.runAsync(ws.devices.register);
    expect(ws.devices.trusted, isTrue);
    final pc = generateEd25519('pc');
    vault.data.devices.put(
      Device(id: 'pc', name: 'Gaming PC', publicKey: pc.publicKey),
    );

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        theme: buildTheme(Brightness.dark),
        home: AppShell(
          workspace: ws,
          registry: registry,
          settings: AppSettings(File('${tmp.path}/settings.json')),
          onLock: () async {},
        ),
      ),
    );
    expect(find.textContaining('"Gaming PC" wants to sign in'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Approve'));
    await tester.pumpAndSettle();
    expect(find.textContaining(fingerprintOf(pc.publicKey)), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Approve').last);
    await settle();
    expect(vault.data.deviceStatus['pc']?.approved, isTrue);
    expect(find.textContaining('wants to sign in'), findsNothing);

    ws.show(Section.settings);
    await tester.pumpAndSettle();
    expect(find.text('MacBook (this device)'), findsOneWidget);
    expect(find.text('Gaming PC'), findsOneWidget);
    expect(find.text('Remove'), findsOneWidget);

    ws.devices.dispose();
    await settle();
    await tester.runAsync(vault.lock);
  });
}
