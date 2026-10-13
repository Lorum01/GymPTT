# GymTalk

Push-to-talk per amici in palestra: ognuno ascolta la propria musica, e tenendo
premuto **Parla** si parla a tutto il gruppo o a una sola persona. A chi ascolta
la musica si abbassa (ducking) solo finché l'altro sta parlando.

```
app/      App Flutter (Android + iOS)
server/   Token server Dart (rilascia i token LiveKit)
```

## Come funziona

- **Audio**: WebRTC tramite [LiveKit Cloud](https://cloud.livekit.io). Ogni gruppo è
  una "stanza" LiveKit identificata dal codice gruppo.
- **Push-to-talk**: il microfono è pubblicato ma muto; si apre solo tenendo premuto.
- **Parlare a uno solo**: si limitano i permessi di sottoscrizione della traccia
  audio al solo destinatario: il server non inoltra l'audio agli altri.
- **Ducking**: prima di parlare l'app manda un messaggio `start` ai destinatari,
  che attivano l'audio di sistema in modalità "ducking" (Android: audio focus
  `GAIN_TRANSIENT_MAY_DUCK`; iOS: AVAudioSession `.duckOthers`). Al messaggio
  `stop` l'audio viene rilasciato e la musica torna al volume normale.
  Vedi `app/lib/services/voice_audio.dart`.
- **Cuffie Bluetooth**: l'app evita il profilo "telefonata" (HFP), che renderebbe la
  musica mono e di bassa qualità. Le cuffie restano in A2DP e si parla nel
  microfono del telefono.

## Setup

### 1. LiveKit Cloud
Crea un progetto gratuito su https://cloud.livekit.io e annota:
`LIVEKIT_URL` (wss://…), `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`.

### 2. Server GymTalk (sul PC o sul Mac)
Crea `server/.env` (escluso da git):
```
LIVEKIT_URL=wss://xxx.livekit.cloud
LIVEKIT_API_KEY=...
LIVEKIT_API_SECRET=...
PORT=8080
```
poi:
```bash
cd server
dart pub get
dart run bin/server.dart
```
Il server ascolta sulla porta 8080 e salva i gruppi in `server/data/groups.json`.
Finché gira sul PC, per **entrare** nei gruppi i telefoni devono essere sulla stessa
Wi-Fi (la voce invece passa da LiveKit Cloud e funziona ovunque).

Il server gestisce gruppi e ruoli: **host** (chi crea il gruppo), **admin** e membri.
Host e admin possono espellere/bannare i membri e nominare admin; solo l'host può
togliere admin e agire sugli admin. Le regole sono in `server/lib/groups.dart`.

### 3. App
```bash
cd app
flutter pub get
flutter run --dart-define=TOKEN_SERVER=http://<IP-del-computer>:8080
```
- **iPhone**: serve il Mac con Xcode. Apri `app/ios/Runner.xcworkspace`, in
  *Signing & Capabilities* scegli il tuo Apple ID come Team (gratis: l'app resta
  installata 7 giorni).
- **Android**: abilita "Debug USB" sul telefono, collegalo e lancia `flutter run`.
- **Emulatore Android**: la sua rete virtuale perde i pacchetti UDP, usa il relay:
  `flutter run --dart-define=FORCE_RELAY=true`. Per il microfono del PC attiva
  *Extended controls → Microphone → Virtual microphone uses host audio input*.

## Prova

1. Avvia Spotify (o altro) su due telefoni con le cuffie.
2. Telefono A: nome → **Crea un gruppo** → condividi il codice.
3. Telefono B: nome → codice → **Entra nel gruppo**.
4. Tieni premuto il pulsante su A: su B la musica si abbassa e senti la voce.
5. Con 3 telefoni: su A tocca il nome di B e parla. C non sente nulla e la sua musica non cambia.

## Limiti attuali (MVP) e prossimi passi

- [ ] **Schermo bloccato / app in background**: per ora lo schermo resta acceso
      mentre si è nel gruppo. Prossimo passo: foreground service su Android e
      framework PushToTalk di Apple (iOS 16+) su iOS.
- [ ] Pubblicare il token server online (HTTPS) per usarlo fuori dalla Wi-Fi di casa,
      poi rimuovere `usesCleartextTraffic` (Android) e `NSAllowsArbitraryLoads` (iOS).
- [ ] Suono breve di inizio/fine trasmissione, modalità "blocca per parlare".
- [ ] Gruppi salvati e inviti via link.
