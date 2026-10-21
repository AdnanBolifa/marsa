import 'dart:io';

import 'package:flutter/material.dart';

import '../core/vault.dart';
import '../platform/sandbox.dart';
import '../ssh/device_keys.dart';
import '../ssh/sessions.dart';
import 'common.dart';
import 'devices.dart';
import 'sync_dialog.dart';
import 'theme.dart';

const appVersion = '0.5.0';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
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

  VaultSession get _vault => workspace.vault;

  Future<void> _configureSync(BuildContext context) async {
    final cfg = await showSyncDialog(
      context,
      vaultName: _vault.info.name,
      data: _vault.data,
      current: _vault.sync,
    );
    if (cfg == null || !context.mounted) return;
    await busy(context, () => _vault.setSync(cfg));
    if (context.mounted) {
      toast(context, _vault.syncError ?? 'Sync is on and up to date');
    }
  }

  Future<void> _stopSync(BuildContext context) async {
    if (!await confirm(
      context,
      'Stop syncing this vault?',
      'This device keeps its copy. The file at the sync location is left as it is.',
      action: 'Stop syncing',
    )) {
      return;
    }
    await _vault.setSync(null);
  }

  Future<void> _changePassword(BuildContext context) async {
    final r = await promptFields(
      context,
      'Change master password',
      message: _vault.sync == null
          ? null
          : 'Other devices will be asked for the new password the next time '
                'they sync.',
      labels: ['New master password', 'Repeat new master password'],
      obscure: [true, true],
      action: 'Change',
    );
    if (r == null || !context.mounted) return;
    if (r[0].length < 8 || r[0] != r[1]) {
      return toast(
        context,
        'Passwords must match and be at least 8 characters long',
      );
    }
    final ok = await busy(context, () async {
      await _vault.changePassword(r[0]);
      return true;
    });
    if (ok == true && context.mounted) {
      toast(context, 'Master password changed');
    }
  }

  Future<void> _setRemember(BuildContext context, bool on) async {
    try {
      on ? await registry.remember(_vault) : await registry.forget(_vault.info);
    } catch (e) {
      if (context.mounted) toast(context, 'Could not remember this vault: $e');
    }
  }

  Future<void> _allowSshFolder(BuildContext context) async {
    final r = await Sandbox.grantFolder(
      message:
          'Choose your .ssh folder so Marsa can sign in to servers with the '
          'SSH keys on this Mac',
      start: '${Sandbox.home}/.ssh',
    );
    if (r == null) return;
    DeviceKeys.directory = Directory(r.path);
    settings.update(() => settings.sshFolder = r.bookmark);
    if (context.mounted) {
      final n = DeviceKeys.files().length;
      toast(
        context,
        n == 0
            ? 'No SSH keys (id_*) in that folder'
            : 'Marsa can now use the $n SSH key(s) in ${r.path}',
      );
    }
  }

  Future<void> _rename(BuildContext context) async {
    final r = await promptFields(
      context,
      'Rename vault',
      labels: ['Name'],
      initial: [_vault.info.name],
    );
    if (r == null || r.first.trim().isEmpty) return;
    await registry.rename(_vault.info, r.first.trim());
    await _vault.commit();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    final sync = _vault.sync;
    final syncBad =
        _vault.syncState == SyncState.error ||
        _vault.syncState == SyncState.passwordChanged;

    Widget section(String title, List<Widget> rows) => Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 8),
            child: Text(
              title.toUpperCase(),
              style: t.textTheme.labelSmall?.copyWith(
                letterSpacing: .6,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0) const Divider(),
                  rows[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );

    // A setting: what it is on the left, its control on the right.
    Widget row(String title, String? detail, Widget control, {Color? color}) {
      final label = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: t.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
          if (detail != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                detail,
                style: t.textTheme.bodySmall?.copyWith(color: color),
              ),
            ),
        ],
      );
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: LayoutBuilder(
          // Side by side when there is room, stacked on a narrow window.
          builder: (context, box) => box.maxWidth < 520
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [label, const SizedBox(height: 10), control],
                )
              : Row(
                  children: [
                    Expanded(child: label),
                    const SizedBox(width: 24),
                    control,
                  ],
                ),
        ),
      );
    }

    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => ListView(
        children: [
          const PageHeader('Settings'),
          Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    section('Appearance', [
                      row(
                        'Theme',
                        null,
                        SegmentedButton<ThemeMode>(
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(
                              value: ThemeMode.system,
                              label: Text('System'),
                            ),
                            ButtonSegment(
                              value: ThemeMode.light,
                              label: Text('Light'),
                            ),
                            ButtonSegment(
                              value: ThemeMode.dark,
                              label: Text('Dark'),
                            ),
                          ],
                          selected: {settings.themeMode},
                          onSelectionChanged: (s) => settings.update(
                            () => settings.themeMode = s.first,
                          ),
                        ),
                      ),
                      row(
                        'Terminal colours',
                        null,
                        SizedBox(
                          width: 240,
                          child: DropdownButtonFormField<String>(
                            initialValue: settings.terminalTheme,
                            isExpanded: true,
                            icon: const Icon(Icons.unfold_more, size: 16),
                            style: t.textTheme.bodyLarge,
                            items: [
                              const DropdownMenuItem(
                                value: 'auto',
                                child: Text('Follow the app theme'),
                              ),
                              for (final name in terminalThemes.keys)
                                DropdownMenuItem(
                                  value: name,
                                  child: Text(name),
                                ),
                            ],
                            onChanged: (v) => settings.update(
                              () => settings.terminalTheme = v!,
                            ),
                          ),
                        ),
                      ),
                      row(
                        'Terminal font size',
                        '${settings.fontSize.round()} pt',
                        SizedBox(
                          width: 240,
                          child: Slider(
                            min: 9,
                            max: 24,
                            divisions: 15,
                            value: settings.fontSize,
                            onChanged: (v) =>
                                settings.update(() => settings.fontSize = v),
                          ),
                        ),
                      ),
                    ]),
                    section('Vault · ${_vault.info.name}', [
                      row(
                        'Sync',
                        switch (_vault.syncState) {
                          SyncState.off =>
                            'Off. This vault lives only on this device.',
                          SyncState.error => 'Failed: ${_vault.syncError}',
                          SyncState.passwordChanged =>
                            'The master password was changed on another '
                                'device. Click the cloud icon in the sidebar '
                                'to enter the new one.',
                          _ =>
                            '${sync?.summary}'
                                '${_vault.lastSynced == null ? '' : '\nLast synced at ${TimeOfDay.fromDateTime(_vault.lastSynced!).format(context)}'}',
                        },
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (sync != null) ...[
                              if (sync.link != null)
                                OutlinedButton(
                                  onPressed: () => copyText(
                                    context,
                                    sync.link!,
                                    'Sync link',
                                  ),
                                  child: const Text('Copy link'),
                                ),
                              OutlinedButton(
                                onPressed: () => busy(context, _vault.syncNow),
                                child: const Text('Sync now'),
                              ),
                              OutlinedButton(
                                onPressed: () => _stopSync(context),
                                child: const Text('Turn off'),
                              ),
                            ],
                            sync == null
                                ? FilledButton(
                                    onPressed: () => _configureSync(context),
                                    child: const Text('Set up sync'),
                                  )
                                : OutlinedButton(
                                    onPressed: () => _configureSync(context),
                                    child: const Text('Change'),
                                  ),
                          ],
                        ),
                        color: syncBad ? scheme.error : null,
                      ),
                      row(
                        'Remember on this device',
                        'Open without the master password. The key is kept '
                            'in this computer\'s credential store, so anyone '
                            'using your signed-in account can open the vault.',
                        Switch(
                          value: _vault.info.remembered,
                          onChanged: (on) => _setRemember(context, on),
                        ),
                      ),
                      row(
                        'Master password',
                        sync == null
                            ? null
                            : 'Other devices are asked for the new one on '
                                  'their next sync.',
                        OutlinedButton(
                          onPressed: () => _changePassword(context),
                          child: const Text('Change'),
                        ),
                      ),
                      row(
                        'Vault name',
                        _vault.info.name,
                        OutlinedButton(
                          onPressed: () => _rename(context),
                          child: const Text('Rename'),
                        ),
                      ),
                    ]),
                    ListenableBuilder(
                      listenable: workspace.devices,
                      builder: (context, _) => section(
                        'Devices',
                        deviceRows(context, workspace, row),
                      ),
                    ),
                    if (Sandbox.on)
                      section('This Mac', [
                        row(
                          'SSH keys on this Mac',
                          DeviceKeys.available
                              ? 'Using the keys in ${DeviceKeys.directory.path}.'
                              : 'macOS keeps App Store apps out of your '
                                    '.ssh folder until you allow it. Needed '
                                    'for hosts that sign in with this '
                                    'device\'s SSH keys.',
                          OutlinedButton(
                            onPressed: () => _allowSshFolder(context),
                            child: Text(
                              DeviceKeys.available ? 'Change' : 'Allow access',
                            ),
                          ),
                        ),
                      ]),
                    section('About', [
                      row(
                        'Marsa $appVersion',
                        'Open-source SSH and SFTP client with encrypted, '
                            'self-synced vaults. MIT License.',
                        OutlinedButton(
                          onPressed: () => showLicensePage(
                            context: context,
                            applicationName: 'Marsa',
                            applicationVersion: appVersion,
                          ),
                          child: const Text('Open-source licenses'),
                        ),
                      ),
                    ]),
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
