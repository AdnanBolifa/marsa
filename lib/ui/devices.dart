import 'package:flutter/material.dart';

import '../core/models.dart';
import '../ssh/device_access.dart';
import '../ssh/keys.dart';
import '../ssh/sessions.dart';
import 'common.dart';

/// A strip above the tabs: another device asking to be let in, or this one
/// waiting to be.
class DeviceBanner extends StatelessWidget {
  const DeviceBanner(this.ws, {super.key});
  final Workspace ws;

  @override
  Widget build(BuildContext context) {
    final access = ws.devices;
    final me = access.me;
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    Widget bar(IconData icon, String text, List<Widget> actions) => Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: scheme.onSecondaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: t.textTheme.bodySmall?.copyWith(
                color: scheme.onSecondaryContainer,
              ),
            ),
          ),
          ...actions,
        ],
      ),
    );

    final waiting = access.pending;
    if (access.trusted && waiting.isNotEmpty) {
      final d = waiting.first;
      final more = waiting.length - 1;
      return bar(
        Icons.devices_other,
        'New device "${d.title}" wants to sign in to your servers'
        '${more > 0 ? ' (and $more more, see Settings)' : ''}. Approve it '
        'only if it is yours: its key is added to every server in this vault.',
        [
          TextButton(
            onPressed: () => access.remove(d),
            child: const Text('Deny'),
          ),
          const SizedBox(width: 4),
          FilledButton(
            onPressed: () => approve(context, access, d),
            child: const Text('Approve'),
          ),
        ],
      );
    }
    if (me != null &&
        ws.vault.data.devices[me.id] != null &&
        ws.vault.data.deviceStatus[me.id] == null) {
      return bar(
        Icons.hourglass_top,
        'This device is waiting to be approved. On a device that already '
        'has access, approve "${me.name}" when Marsa asks; this device can '
        'then sign in to your servers with its own key.',
        const [],
      );
    }
    return const SizedBox.shrink();
  }
}

Future<void> approve(
  BuildContext context,
  DeviceAccess access,
  Device d,
) async {
  if (!await confirm(
    context,
    'Approve "${d.title}"?',
    'Its key (${fingerprintOf(d.publicKey)}) will be added to every server '
        'in this vault, so it can sign in to them. Only approve a device you '
        'just set up yourself.',
    action: 'Approve',
  )) {
    return;
  }
  await access.approve(d);
  if (context.mounted) {
    final n = access.installedOn(d.id);
    toast(
      context,
      '"${d.title}" approved. Its key is on $n server(s) so far; the rest '
      'follow as they can be reached.',
    );
  }
}

/// The Settings rows listing the vault's devices.
List<Widget> deviceRows(
  BuildContext context,
  Workspace ws,
  Widget Function(String title, String? detail, Widget control, {Color? color})
  row,
) {
  final access = ws.devices;
  final data = ws.vault.data;
  final me = access.me;
  final scheme = Theme.of(context).colorScheme;
  final servers = data.hosts.all.length;
  final list = data.devices.all.toList()
    ..sort((a, b) {
      if (a.id == me?.id) return -1;
      if (b.id == me?.id) return 1;
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });

  return [
    row(
      'Device keys',
      me == null
          ? 'Not available: this computer\'s credential store could not be '
                'read, so this device has no key of its own right now.'
          : 'Each device signs in with its own key, kept on that device. '
                'Approved devices add new devices\' keys to every server and '
                'remove them when a device is removed.',
      OutlinedButton(
        onPressed: me == null || access.running
            ? null
            : () => access.run(force: true),
        child: Text(access.running ? 'Updating…' : 'Update servers now'),
      ),
    ),
    for (final d in list)
      () {
        final mine = d.id == me?.id;
        final on = access.installedOn(d.id);
        final problems = access.problemsOf(d.id);
        final status = data.deviceStatus[d.id];
        final String detail;
        if (status == null) {
          detail = mine
              ? 'Waiting to be approved on a device that already has access.'
              : 'Asking to be let in.';
        } else if (!status.approved) {
          detail = on == 0
              ? 'Removed. It cannot sign in to your servers.'
              : 'Removed. Its key is still on $on server(s) and is taken '
                    'off as soon as they can be reached.';
        } else {
          detail =
              'Key on $on of $servers server(s)'
              '${status.by.isEmpty || status.by == d.name ? '' : ' · approved by ${status.by}'}';
        }
        final issues = problems.entries
            .take(3)
            .map((e) => '${e.key}: ${e.value}')
            .join('\n');
        return row(
          mine ? '${d.title} (this device)' : d.title,
          '$detail\n${fingerprintOf(d.publicKey)}'
          '${issues.isEmpty ? '' : '\nNot yet on:\n$issues'}',
          Wrap(
            spacing: 8,
            children: [
              if (status == null && access.trusted) ...[
                OutlinedButton(
                  onPressed: () => access.remove(d),
                  child: const Text('Deny'),
                ),
                FilledButton(
                  onPressed: () => approve(context, access, d),
                  child: const Text('Approve'),
                ),
              ],
              if (status?.approved == false && !mine && access.trusted)
                OutlinedButton(
                  onPressed: () => approve(context, access, d),
                  child: const Text('Approve again'),
                ),
              if (status?.approved == true && !mine && access.trusted)
                OutlinedButton(
                  onPressed: () async {
                    if (await confirm(
                      context,
                      'Remove "${d.title}"?',
                      'Its key comes off every server in this vault, so it '
                          'can no longer sign in to them. It still has its '
                          'copy of the vault: if the device is lost, also '
                          'change the master password.',
                      action: 'Remove',
                      danger: true,
                    )) {
                      await access.remove(d);
                    }
                  },
                  child: const Text('Remove'),
                ),
            ],
          ),
          color: problems.isEmpty ? null : scheme.error,
        );
      }(),
  ];
}
