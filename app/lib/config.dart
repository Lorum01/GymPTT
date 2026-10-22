/// Indirizzo del server GymTalk (cartella `server/`).
///
/// Server online (Render): flutter build apk --dart-define=TOKEN_SERVER=https://...
/// Server sul PC, stessa Wi-Fi dei telefoni (solo versioni di sviluppo):
///   flutter run --dart-define=TOKEN_SERVER=http://192.168.1.10:8080
const tokenServerUrl = String.fromEnvironment(
  'TOKEN_SERVER',
  defaultValue: 'http://192.168.1.10:8080',
);

/// Forza l'audio attraverso il relay TURN di LiveKit invece della connessione
/// diretta UDP. Utile sull'emulatore Android, la cui rete virtuale perde i
/// pacchetti UDP:  flutter run --dart-define=FORCE_RELAY=true
const forceRelay = bool.fromEnvironment('FORCE_RELAY');
