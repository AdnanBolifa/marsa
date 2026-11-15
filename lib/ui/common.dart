import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ssh/connector.dart';

final navigatorKey = GlobalKey<NavigatorState>();

const mono = TextStyle(
  fontFamily: 'Menlo',
  fontFamilyFallback: ['Consolas', 'Monaco', 'Courier New', 'monospace'],
);

void toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

void copyText(BuildContext context, String text, String what) {
  Clipboard.setData(ClipboardData(text: text));
  toast(context, '$what copied');
}

Future<bool> confirm(
  BuildContext context,
  String title,
  String body, {
  String action = 'OK',
  bool danger = false,
}) async {
  final scheme = Theme.of(context).colorScheme;
  return await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: SizedBox(width: 420, child: Text(body)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: danger
                  ? FilledButton.styleFrom(
                      backgroundColor: scheme.error,
                      foregroundColor: scheme.onError,
                    )
                  : null,
              onPressed: () => Navigator.pop(c, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;
}

/// Asks for one or more values. Returns null when cancelled.
Future<List<String>?> promptFields(
  BuildContext context,
  String title, {
  String? message,
  required List<String> labels,
  List<bool>? obscure,
  List<String>? initial,
  String action = 'OK',
}) {
  final ctrls = [
    for (var i = 0; i < labels.length; i++)
      TextEditingController(text: initial?[i] ?? ''),
  ];
  return showDialog<List<String>>(
    context: context,
    builder: (c) {
      void submit() => Navigator.pop(c, [for (final t in ctrls) t.text]);
      return AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (message != null && message.isNotEmpty) ...[
                Text(message),
                const SizedBox(height: 12),
              ],
              for (var i = 0; i < labels.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: labeled(
                    labels[i],
                    (obscure?[i] ?? false)
                        ? SecretField(
                            controller: ctrls[i],
                            autofocus: i == 0,
                            onSubmitted: (_) => submit(),
                          )
                        : TextField(
                            controller: ctrls[i],
                            autofocus: i == 0,
                            onSubmitted: (_) => submit(),
                          ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(onPressed: submit, child: Text(action)),
        ],
      );
    },
  );
}

/// Runs [work] behind a modal spinner and reports a failure in a snackbar.
/// Returns null when it failed.
Future<T?> busy<T>(BuildContext context, Future<T> Function() work) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const PopScope(
      canPop: false,
      child: Center(child: CircularProgressIndicator()),
    ),
  );
  final nav = Navigator.of(context, rootNavigator: true);
  final messenger = ScaffoldMessenger.of(context);
  try {
    final r = await work();
    nav.pop();
    return r;
  } catch (e) {
    nav.pop();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(e.toString())));
    return null;
  }
}

class PageHeader extends StatelessWidget {
  const PageHeader(this.title, {super.key, this.actions = const []});
  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 18, 24, 14),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 10,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: actions,
        ),
      ],
    ),
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState(this.icon, this.title, this.hint, {super.key, this.action});
  final IconData icon;
  final String title;
  final String hint;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: t.colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, size: 26, color: t.colorScheme.primary),
              ),
              const SizedBox(height: 16),
              Text(title, style: t.textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(
                hint,
                textAlign: TextAlign.center,
                style: t.textTheme.bodySmall?.copyWith(fontSize: 13),
              ),
              if (action != null) ...[const SizedBox(height: 16), action!],
            ],
          ),
        ),
      ),
    );
  }
}

/// A scrollable form inside a dialog, with Cancel/Save.
class FormDialog extends StatelessWidget {
  const FormDialog({
    super.key,
    required this.title,
    required this.children,
    required this.onSave,
    this.saveLabel = 'Save',
  });
  final String title;
  final List<Widget> children;
  final VoidCallback? onSave;
  final String saveLabel;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(title),
    titlePadding: const EdgeInsets.fromLTRB(22, 20, 22, 4),
    contentPadding: const EdgeInsets.fromLTRB(22, 12, 22, 4),
    actionsPadding: const EdgeInsets.fromLTRB(22, 8, 22, 18),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final w in children)
              Padding(padding: const EdgeInsets.only(bottom: 14), child: w),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: onSave, child: Text(saveLabel)),
    ],
  );
}

/// A form control with its label above it.
Widget labeled(String label, Widget child) => Builder(
  builder: (context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 5),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelMedium
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ),
      child,
    ],
  ),
);

Widget field(
  TextEditingController c,
  String label, {
  bool obscure = false,
  String? hint,
  int lines = 1,
  bool code = false,
}) => labeled(
  label,
  obscure
      ? SecretField(controller: c, hint: hint)
      : TextField(
          controller: c,
          maxLines: lines,
          style: code ? mono.copyWith(fontSize: 12.5) : null,
          decoration: InputDecoration(hintText: hint),
        ),
);

/// A password input with buttons to show/hide the text and copy it.
class SecretField extends StatefulWidget {
  const SecretField({
    super.key,
    required this.controller,
    this.hint,
    this.focusNode,
    this.autofocus = false,
    this.enabled = true,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String? hint;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool enabled;
  final ValueChanged<String>? onSubmitted;

  @override
  State<SecretField> createState() => _SecretFieldState();
}

class _SecretFieldState extends State<SecretField> {
  bool _shown = false;

  @override
  Widget build(BuildContext context) => TextField(
    controller: widget.controller,
    focusNode: widget.focusNode,
    autofocus: widget.autofocus,
    enabled: widget.enabled,
    obscureText: !_shown,
    onSubmitted: widget.onSubmitted,
    decoration: InputDecoration(
      hintText: widget.hint,
      suffixIcon: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: _shown ? 'Hide' : 'Show',
            iconSize: 18,
            icon: Icon(_shown ? Icons.visibility_off : Icons.visibility),
            onPressed: () => setState(() => _shown = !_shown),
          ),
          IconButton(
            tooltip: 'Copy',
            iconSize: 18,
            icon: const Icon(Icons.copy),
            onPressed: () {
              if (widget.controller.text.isNotEmpty) {
                copyText(context, widget.controller.text, 'Password');
              }
            },
          ),
        ],
      ),
    ),
  );
}

/// A labelled dropdown.
Widget choice<T>(
  String label,
  T? value,
  Map<T?, String> options,
  ValueChanged<T?> onChanged,
) => labeled(
  label,
  Builder(
    builder: (context) => DropdownButtonFormField<T?>(
      style: Theme.of(context).textTheme.bodyLarge,
      initialValue: options.containsKey(value) ? value : null,
      isExpanded: true,
      icon: const Icon(Icons.unfold_more, size: 16),
      borderRadius: BorderRadius.circular(10),
      items: [
        for (final e in options.entries)
          DropdownMenuItem(
            value: e.key,
            child: Text(e.value, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: onChanged,
    ),
  ),
);

/// Answers connection prompts with dialogs on the root navigator.
class DialogPrompter implements Prompter {
  BuildContext get _context => navigatorKey.currentContext!;

  @override
  Future<bool> confirmNewHost(String host, String type, String fingerprint) =>
      confirm(
        _context,
        'Trust this server?',
        'This is the first connection to $host.\n\n'
            '$type key fingerprint:\n$fingerprint\n\n'
            'Continue only if this matches the server\'s real key.',
        action: 'Trust and connect',
      );

  @override
  Future<bool> confirmChangedHost(
    String host,
    String type,
    String oldFingerprint,
    String fingerprint,
  ) => confirm(
    _context,
    'Server key has changed',
    'The key $host presents is different from the one saved in this '
        'vault. That happens after a server reinstall, but it is also '
        'what an interception attack looks like.\n\n'
        'Saved:  $oldFingerprint\n'
        'Now ($type):  $fingerprint\n\n'
        'Replace the saved key only if you know why it changed.',
    action: 'Replace key and connect',
    danger: true,
  );

  @override
  Future<String?> askSecret(String title, String prompt) async =>
      (await promptFields(
        _context,
        title,
        labels: [prompt],
        obscure: [true],
        action: 'Continue',
      ))?.first;

  @override
  Future<List<String>?> askInteractive(
    String title,
    String instruction,
    List<SSHUserInfoPrompt> prompts,
  ) => promptFields(
    _context,
    title,
    message: instruction,
    labels: [for (final p in prompts) p.promptText.trim()],
    obscure: [for (final p in prompts) !p.echo],
    action: 'Continue',
  );
}
