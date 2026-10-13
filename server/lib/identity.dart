import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Ogni telefono ha un segreto casuale che non condivide con nessuno tranne
/// questo server. L'identità pubblica (visibile agli altri nel gruppo) è
/// ricavata dal segreto: conoscere l'identità di qualcuno non basta per
/// impersonarlo. Stessa funzione in app/lib/services/identity.dart.
String identityFromSecret(String secret) {
  final digest = sha256.convert(utf8.encode('gymtalk:$secret'));
  return 'u_${digest.toString().substring(0, 24)}';
}

final _secretPattern = RegExp(r'^[A-Za-z0-9_-]{32,128}$');

bool isValidSecret(String? secret) =>
    secret != null && _secretPattern.hasMatch(secret);
