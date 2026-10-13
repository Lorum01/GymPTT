import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Identità del telefono.
///
/// Il [secret] è casuale, resta sul telefono e viene inviato solo al server
/// GymTalk. L'[identity] pubblica, visibile agli altri nel gruppo, è ricavata
/// dal segreto: chi la conosce non può comunque impersonarti.
/// Stessa funzione in server/lib/identity.dart.
class DeviceIdentity {
  const DeviceIdentity(this.secret, this.identity);

  final String secret;
  final String identity;

  static Future<DeviceIdentity> load() async {
    final prefs = await SharedPreferences.getInstance();
    var secret = prefs.getString('secret');
    if (secret == null) {
      final rnd = Random.secure();
      secret = base64Url
          .encode(List.generate(32, (_) => rnd.nextInt(256)))
          .replaceAll('=', '');
      await prefs.setString('secret', secret);
    }
    return DeviceIdentity(secret, identityFromSecret(secret));
  }
}

String identityFromSecret(String secret) {
  final digest = sha256.convert(utf8.encode('gymtalk:$secret'));
  return 'u_${digest.toString().substring(0, 24)}';
}
