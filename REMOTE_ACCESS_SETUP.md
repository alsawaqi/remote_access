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
flutter pub add flutter_webrtc dart_pusher_channels flutter_secure_storage \
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
- **AccessibilityService:** enabled in Settings (Phase 5 wires the native side).

## ⚠️ Android 14 (API 34+) screen-capture requirement — READ THIS
On Android 14+, starting the `mediaProjection` foreground service throws a
`SecurityException` unless the **`project_media` app-op** is granted. A fresh
install does NOT have it (default mode `ignore`). Symptoms if it's missing:

- **Before the fix:** the app hard-crashed ("remote_access has stopped") the
  moment a session started — the uncaught exception in
  `ScreenCaptureService.onStartCommand` killed the process.
- **After the fix (current):** the service catches the failure, the session is
  aborted cleanly, and the admin sees *"Screen capture could not start…"*
  instead of a crash. **But the screen still won't share until the op is
  granted.** The fix removes the crash; it does not remove the requirement.

Grant the op (this is the kiosk/unattended mechanism):

```bash
# Per device, via adb (or the MDM equivalent):
adb shell appops set com.example.remote_access PROJECT_MEDIA allow
# verify -> should print: PROJECT_MEDIA: allow
adb shell appops get com.example.remote_access PROJECT_MEDIA
```

### Granting it on the fleet — `targetSdk 33` + adb provisioning (the working method)
This app is built with **`targetSdk = 33`** and side-loaded via the MDM (not
Google Play). That is deliberate: apps targeting SDK 34+ are subject to Android
14's per-session MediaProjection consent that cannot be suppressed, which would
break unattended capture. Targeting 33 keeps the **`project_media` app-op grant
effective**, so once granted the "Start casting?" dialog never appears, and the
grant **survives reboot** (confirmed in AOSP
`MediaProjectionManagerService.hasProjectionPermission` — the consent activity
short-circuits to RESULT_OK when the op is allowed).

Grant it **once per device via adb** during setup — see **[`provisioning/`](provisioning/)**:
`setup-remote-access.sh` grants `PROJECT_MEDIA`, enables the AccessibilityService
(for input), and battery-exempts the app. All three survive reboot; re-run only
if the app is reinstalled or its data cleared. **Validate on one device first**
(see `provisioning/README.md`) — success = the screen streams with NO dialog on
the kiosk.

Why adb and not an MDM policy: `project_media` is an Android **app-op** (setting
it needs signature-level `MANAGE_APP_OPS_MODES`), not a runtime permission — so no
Scalefusion policy grants it, but adb during the normal "exit kiosk → set up →
return to kiosk" window does. This is the supported path for the generic-Android
fleet (UMIDIGI Z93 / Bluemake / FEITIAN — no Knox, no Sunmi OEM lock).

**Fallback — locked devices you can't adb into** (e.g. Samsung Knox, or a Sunmi
build with no setup window): the app-op can only be set by a platform-signed
helper, or by OEM-signing the APK to hold `CAPTURE_VIDEO_OUTPUT` — i.e. an OEM
partner agreement. Not needed for the adb-provisioned fleet above.

> After changing any of the native (Kotlin) code, rebuild and **redeploy the APK
> to the kiosks** — the running production build still has the old crash.

## Verify
```bash
flutter analyze
flutter build apk --debug   # compiles Dart + the Kotlin native side
flutter run                 # to run on a connected device
```

## Phase 5 boundary
`lib/src/input/input_dispatcher.dart` calls the `remote_access/input` MethodChannel
(`tap`/`longpress`/`swipe`/`key`/`text`). Phase 5 implements the native
AccessibilityService handler for that channel. Until then, input calls are
caught and logged; screen viewing works on its own.
