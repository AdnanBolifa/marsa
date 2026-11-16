import 'package:dartssh2/dartssh2.dart';

import '../ssh/connector.dart';

/// Describes a sensitive MCP action requiring local user approval.
class McpConsentRequest {
  const McpConsentRequest({
    required this.agentName,
    required this.toolName,
    required this.hostLabel,
    required this.summary,
  });

  final String agentName;
  final String toolName;
  final String hostLabel;
  final String summary;
}

typedef McpConsentCallback = Future<bool> Function(McpConsentRequest request);

/// A [Prompter] for brokered MCP SSH connections.
///
/// Delegates host-key confirmation to an optional UI [Prompter] if one is
/// attached, or fails closed (`false` / `null`) when running unattended so
/// unknown or changed host keys are never silently trusted.
class McpPrompter implements Prompter {
  McpPrompter({this.delegate});

  final Prompter? delegate;

  @override
  Future<bool> confirmNewHost(String host, String type, String fingerprint) =>
      delegate?.confirmNewHost(host, type, fingerprint) ?? Future.value(false);

  @override
  Future<bool> confirmChangedHost(
    String host,
    String type,
    String oldFingerprint,
    String fingerprint,
  ) =>
      delegate?.confirmChangedHost(host, type, oldFingerprint, fingerprint) ??
      Future.value(false);

  @override
  Future<String?> askSecret(String title, String prompt) =>
      delegate?.askSecret(title, prompt) ?? Future.value(null);

  @override
  Future<List<String>?> askInteractive(
    String title,
    String instruction,
    List<SSHUserInfoPrompt> prompts,
  ) =>
      delegate?.askInteractive(title, instruction, prompts) ??
      Future.value(null);
}
