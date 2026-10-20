import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'core/cloud.dart';
import 'core/vault.dart';
import 'platform/keystore.dart';
import 'platform/sandbox.dart';
import 'ssh/device_identity.dart';
import 'ssh/device_keys.dart';
import 'ssh/sessions.dart';
import 'ui/common.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';
import 'ui/unlock.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationSupportDirectory();
  final registry = VaultRegistry(
    Directory('${dir.path}/vaults'),
    keyStore: SystemKeyStore(),
  );
  await registry.load();
  DeviceIdentity.current = await DeviceIdentity.load(SystemSecretStore());
  final settings = AppSettings(File('${dir.path}/settings.json'));
  await settings.load();
  if (Sandbox.on) {
    Cloud.openBrowser = Sandbox.openUrl;
    if (settings.sshFolder.isNotEmpty) {
      final path = await Sandbox.useFolder(settings.sshFolder);
      if (path != null) DeviceKeys.directory = Directory(path);
    }
  }
  runApp(MarsaApp(registry: registry, settings: settings));
}

class MarsaApp extends StatefulWidget {
  const MarsaApp({super.key, required this.registry, required this.settings});
  final VaultRegistry registry;
  final AppSettings settings;

  @override
  State<MarsaApp> createState() => _MarsaAppState();
}

class _MarsaAppState extends State<MarsaApp> {
  Workspace? _workspace;

  // Only a fresh launch reopens a remembered vault by itself; after an
  // explicit Lock the unlock screen stays put.
  bool _launch = true;

  Future<void> _lock() async {
    final ws = _workspace;
    setState(() {
      _workspace = null;
      _launch = false;
    });
    await ws?.shutdown();
    ws?.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.settings,
    builder: (context, _) => MaterialApp(
      title: 'Marsa',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: widget.settings.themeMode,
      home: _workspace == null
          ? UnlockPage(
              registry: widget.registry,
              autoUnlock: _launch,
              onUnlocked: (vault) => setState(
                () => _workspace = Workspace(
                  vault,
                  DialogPrompter(),
                  device: DeviceIdentity.current,
                )..startDevices(),
              ),
            )
          : AppShell(
              workspace: _workspace!,
              registry: widget.registry,
              settings: widget.settings,
              onLock: _lock,
            ),
    ),
  );
}
