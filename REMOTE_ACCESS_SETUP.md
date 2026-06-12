# Remote Access Agent — build & run

Flutter device-agent for the charity kiosk remote-control feature. It enrols
with a one-time code, keeps a persistent Reverb connection, and on request
captures the screen (MediaProjection) and streams it over WebRTC. Input
injection (AccessibilityService) lands in **Phase 5**.

## Prerequisites
- Flutter SDK (Dart 3.11+) and Android tooling.
- Min Android 11 (API 30). `compileSdk`/`targetSdk` set to 35.

## Install deps
```bash
flutter pub get
```
Versions in `pubspec.yaml` were set to recent releases; if pub can't resolve a
constraint (this is a fast-moving set), run:
```bash
flutter pub add flutter_webrtc pusher_channels_flutter flutter_secure_storage \
  permission_handler http device_info_plus package_info_plus
```

## Configure the backend endpoints
Defaults target production (`api.mithqal.net` / `wss://ws.mithqal.net:443`).
Override with `--dart-define` for local testing (Android emulator → host is `10.0.2.2`):
```bash
flutter run \
  --dart-define=API_BASE=http://10.0.2.2:8082 \
  --dart-define=REVERB_HOST=10.0.2.2 \
  --dart-define=REVERB_PORT=8084 \
  --dart-define=REVERB_SCHEME=ws
```
The Reverb **app key** is delivered by the enrollment response (not hard-coded).

## Enrol a device
1. In the dashboard, open the device → Remote Control → **Generate enrollment code**.
2. Type the `RMT-…` code into the app's enrolment screen.
3. The app stores a revocable device token (EncryptedSharedPreferences) and connects.

## Permissions the technician grants on the device (one-time, per Phase 0)
- **Screen capture (MediaProjection):** approved when the first session starts.
  On stock Android 11+ this prompt reappears after a reboot / capture-service
  kill — keep the app foregrounded; full unattended capture needs the
  Scalefusion Device-Owner path (future).
- **AccessibilityService:** enabled in Settings (Phase 5 wires the native side).

## Verify
Because no Dart/Flutter toolchain was available where this code was generated,
it has NOT been compiled here. Build it yourself:
```bash
flutter analyze
flutter run            # or: flutter build apk --debug
```

## Phase 5 boundary
`lib/src/input/input_dispatcher.dart` calls the `remote_access/input` MethodChannel
(`tap`/`longpress`/`swipe`/`key`/`text`). Phase 5 implements the native
AccessibilityService handler for that channel. Until then, input calls are
caught and logged; screen viewing works on its own.
