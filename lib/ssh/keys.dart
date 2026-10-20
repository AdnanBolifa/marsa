import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:pinenacl/ed25519.dart' as nacl;
import 'package:pointycastle/export.dart';

import '../core/crypto.dart';
import '../core/models.dart';

String _publicLine(SSHKeyPair kp, String comment) {
  final blob = base64.encode(kp.toPublicKey().encode());
  // The line is later pasted into a shell command when a key is deployed, so
  // the comment is reduced to characters that need no quoting.
  final safe = comment.replaceAll(RegExp(r'[^A-Za-z0-9._@-]+'), '-');
  return '${kp.name} $blob $safe'.trim();
}

/// OpenSSH-style `SHA256:…` fingerprint of an `authorized_keys` line.
String fingerprintOf(String publicLine) {
  final parts = publicLine.split(' ');
  if (parts.length < 2) return '';
  try {
    final digest = SHA256Digest().process(base64.decode(parts[1]));
    return 'SHA256:${base64.encode(digest).replaceAll('=', '')}';
  } on FormatException {
    return '';
  }
}

SshKey _record(String label, SSHKeyPair kp) => SshKey(
  label: label,
  privateKey: kp.toPem(),
  publicKey: _publicLine(kp, label),
  type: kp.name,
);

SshKey generateEd25519(String label) {
  final sk = nacl.SigningKey.generate();
  return _record(
    label,
    OpenSSHEd25519KeyPair(
      Uint8List.fromList(sk.verifyKey.asTypedList),
      Uint8List.fromList(sk.asTypedList),
      label,
    ),
  );
}

/// RSA generation is slow in pure Dart, so it runs on another isolate.
Future<SshKey> generateRsa(String label, {int bits = 3072}) async {
  final pem = await Isolate.run(() {
    final random = FortunaRandom()..seed(KeyParameter(randomBytes(32)));
    final gen = RSAKeyGenerator()
      ..init(
        ParametersWithRandom(
          RSAKeyGeneratorParameters(BigInt.from(65537), bits, 64),
          random,
        ),
      );
    final priv = gen.generateKeyPair().privateKey;
    return OpenSSHRsaKeyPair(
      priv.n!,
      priv.publicExponent!,
      priv.privateExponent!,
      priv.q!.modInverse(priv.p!),
      priv.p!,
      priv.q!,
      label,
    ).toPem();
  });
  return _record(label, SSHKeyPair.fromPem(pem).first);
}

bool isEncryptedKey(String pem) {
  try {
    return SSHKeyPair.isEncryptedPem(pem);
  } catch (_) {
    return false;
  }
}

/// Parses a private key file. A passphrase-protected key is decrypted once
/// here and stored unencrypted inside the (encrypted) vault, so connecting
/// does not pay the key's own KDF every time.
Future<SshKey> importKey(String label, String pem, [String? passphrase]) async {
  final plain = await Isolate.run(() {
    final pairs = SSHKeyPair.fromPem(pem, passphrase);
    if (pairs.isEmpty) throw const FormatException('No private key found');
    return pairs.first.toPem();
  });
  return _record(label, SSHKeyPair.fromPem(plain).first);
}
