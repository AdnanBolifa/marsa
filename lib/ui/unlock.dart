import 'package:flutter/material.dart';

import '../core/crypto.dart';
import '../core/vault.dart';
import 'common.dart';
import 'sync_dialog.dart';

class UnlockPage extends StatefulWidget {
  const UnlockPage({
    super.key,
    required this.registry,
    required this.onUnlocked,
    this.autoUnlock = false,
  });
  final VaultRegistry registry;

  /// Open the last used vault straight away if this device remembers it.
  final bool autoUnlock;
  final ValueChanged<VaultSession> onUnlocked;

  @override
  State<UnlockPage> createState() => _UnlockPageState();
}

class _UnlockPageState extends State<UnlockPage> {
  final _password = TextEditingController();
  final _focus = FocusNode();
  VaultInfo? _selected;
  bool _working = false;
  bool _remember = false;
  String? _error;

  VaultRegistry get _reg => widget.registry;

  @override
  void initState() {
    super.initState();
    if (_reg.vaults.isEmpty) return;
    _select(
      _reg.vaults.firstWhere(
        (v) => v.id == _reg.lastId,
        orElse: () => _reg.vaults.first,
      ),
    );
    if (widget.autoUnlock && _selected!.remembered) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
    }
  }

  void _select(VaultInfo v) {
    _selected = v;
    _remember = v.remembered;
  }

  Future<void> _run(Future<VaultSession?> Function() work) async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final v = await work();
      if (v != null) return widget.onUnlocked(v);
    } on WrongPassword {
      _error = 'Wrong master password';
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _working = false);
  }

  void _unlock() {
    final v = _selected;
    if (v == null) return;
    final password = _password.text;
    if (password.isEmpty) {
      if (!v.remembered) return;
      _run(() async {
        final s = await _reg.unlockRemembered(v);
        if (s == null) {
          _error =
              'This device could not open the vault by itself. Enter '
              'the master password.';
          _remember = true;
        }
        return s;
      });
      return;
    }
    final remember = _remember;
    _run(() async {
      final s = await _reg.unlock(v, password);
      if (remember) {
        try {
          await _reg.remember(s);
        } catch (e) {
          if (mounted) toast(context, 'Could not remember this vault: $e');
        }
      } else if (v.remembered) {
        await _reg.forget(v);
      }
      return s;
    });
  }

  Future<List<String>?> _askNewVault(String title) async {
    final r = await promptFields(
      context,
      title,
      message:
          'The master password encrypts everything in the vault. It is '
          'never stored and cannot be recovered if you forget it.',
      labels: ['Vault name', 'Master password', 'Repeat master password'],
      obscure: [false, true, true],
      initial: [_reg.vaults.isEmpty ? 'Personal' : '', '', ''],
      action: 'Create',
    );
    if (r == null || !mounted) return null;
    if (r[0].trim().isEmpty || r[1].length < 8) {
      toast(context, 'Give the vault a name and a password of 8+ characters');
      return null;
    }
    if (r[1] != r[2]) {
      toast(context, 'The two passwords do not match');
      return null;
    }
    return r;
  }

  Future<void> _create() async {
    final r = await _askNewVault('New vault');
    if (r != null) _run(() => _reg.create(r[0].trim(), r[1]));
  }

  Future<void> _join() async {
    final r = await promptFields(
      context,
      'Join a synced vault',
      message:
          'Use this on a new device, or to add a vault a teammate '
          'shared with you. You need the vault\'s master password and '
          'access to where it is synced.',
      labels: ['Name for this vault', 'Master password'],
      obscure: [false, true],
      action: 'Next',
    );
    if (r == null || !mounted || r[0].trim().isEmpty) return;
    final cfg = await showSyncDialog(
      context,
      vaultName: r[0].trim(),
      joining: true,
    );
    if (cfg != null) _run(() => _reg.join(r[0].trim(), r[1], cfg));
  }

  Future<void> _remove(VaultInfo v) async {
    final ok = await confirm(
      context,
      'Remove "${v.name}" from this device?',
      'The local copy is deleted. A synced copy and other devices are not '
          'touched. If this vault is not synced, its contents are gone for '
          'good.',
      action: 'Remove',
      danger: true,
    );
    if (!ok) return;
    await _reg.remove(v);
    setState(() {
      _selected = null;
      if (_reg.vaults.isNotEmpty) _select(_reg.vaults.first);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    final remembered = _selected?.remembered ?? false;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      Icons.anchor,
                      size: 30,
                      color: scheme.onPrimary,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'Marsa',
                  textAlign: TextAlign.center,
                  style: t.textTheme.headlineSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  _reg.vaults.isEmpty
                      ? 'Create a vault to keep your servers and keys in.'
                      : 'Unlock a vault to continue.',
                  textAlign: TextAlign.center,
                  style: t.textTheme.bodySmall?.copyWith(fontSize: 13),
                ),
                const SizedBox(height: 22),
                if (_reg.vaults.isNotEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final v in _reg.vaults)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Material(
                                color: v == _selected
                                    ? scheme.surfaceContainerHigh
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: _working
                                      ? null
                                      : () {
                                          setState(() => _select(v));
                                          _focus.requestFocus();
                                        },
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      10,
                                      6,
                                      2,
                                      6,
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          v == _selected
                                              ? Icons.radio_button_checked
                                              : Icons.radio_button_unchecked,
                                          size: 17,
                                          color: v == _selected
                                              ? scheme.primary
                                              : scheme.outline,
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                v.name,
                                                style: t.textTheme.titleSmall,
                                              ),
                                              if (v.remembered)
                                                Text(
                                                  'Remembered on this device',
                                                  style: t.textTheme.labelSmall,
                                                ),
                                            ],
                                          ),
                                        ),
                                        IconButton(
                                          tooltip: 'Remove from this device',
                                          icon: const Icon(
                                            Icons.delete_outline,
                                            size: 16,
                                          ),
                                          onPressed: _working
                                              ? null
                                              : () => _remove(v),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          const SizedBox(height: 8),
                          labeled(
                            remembered
                                ? 'Master password (not needed)'
                                : 'Master password',
                            SecretField(
                              controller: _password,
                              focusNode: _focus,
                              autofocus: true,
                              enabled: !_working,
                              onSubmitted: (_) => _unlock(),
                            ),
                          ),
                          const SizedBox(height: 10),
                          InkWell(
                            borderRadius: BorderRadius.circular(6),
                            onTap: _working
                                ? null
                                : () => setState(() => _remember = !_remember),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                children: [
                                  Checkbox(
                                    value: _remember,
                                    onChanged: _working
                                        ? null
                                        : (v) => setState(
                                            () => _remember = v ?? false,
                                          ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Tooltip(
                                      message:
                                          'Opens without the password for '
                                          'anyone signed in to this computer '
                                          'as you.',
                                      child: Text(
                                        'Remember on this device',
                                        style: t.textTheme.bodyMedium,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: _working ? null : _unlock,
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 40),
                            ),
                            child: Text(_working ? 'Unlocking…' : 'Unlock'),
                          ),
                        ],
                      ),
                    ),
                  )
                else if (_working)
                  const Center(child: CircularProgressIndicator()),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.error),
                  ),
                ],
                const SizedBox(height: 16),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _reg.vaults.isEmpty
                        ? FilledButton.icon(
                            onPressed: _working ? null : _create,
                            icon: const Icon(Icons.add, size: 17),
                            label: const Text('New vault'),
                          )
                        : TextButton.icon(
                            onPressed: _working ? null : _create,
                            icon: const Icon(Icons.add, size: 17),
                            label: const Text('New vault'),
                          ),
                    TextButton.icon(
                      onPressed: _working ? null : _join,
                      icon: const Icon(Icons.cloud_download_outlined, size: 17),
                      label: const Text('Join a synced vault'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
