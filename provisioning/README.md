# Unattended remote control — per-device setup (Option A)

Generic Android (your UMIDIGI Z93 / Bluemake / FEITIAN kiosks — no Samsung Knox)
will **not** let any app share its screen without a per-session *"Start casting?"*
tap, unless the `PROJECT_MEDIA` app-op is pre-granted. This folder pre-grants it
(plus the accessibility service for input) **once per device**, so afterwards you
can connect from the dashboard with **nobody touching the kiosk**.

This works because the agent is built with **`targetSdk = 33`**. Android 14
(targetSdk ≥ 34) re-enforces the per-session dialog and would defeat this; since
we side-load via the MDM (not Google Play) we are free to target 33.

## What you need
- The **release-signed** agent APK (package `net.mithqal.remoteaccess`,
  `targetSdk = 33`), installed on the device.
- `adb` on your laptop (Android Platform Tools).
- The device reachable by ADB: USB cable with **USB debugging** on, **or** wireless ADB.
  On a Scalefusion kiosk, do this during your normal *"exit kiosk → set up → return
  to kiosk"* window.

## Run it
```bash
# from this folder, with exactly one device connected:
bash setup-remote-access.sh
```
or run the commands by hand (package = `net.mithqal.remoteaccess`):
```bash
# 1) tap-free screen capture (persists across reboot)
adb shell cmd appops set --user 0 net.mithqal.remoteaccess PROJECT_MEDIA allow

# 2) enable remote-input accessibility service
#    (the script APPENDS to existing services; this hand version overwrites them)
adb shell settings put secure enabled_accessibility_services \
  net.mithqal.remoteaccess/net.mithqal.remoteaccess.RemoteInputService
adb shell settings put secure accessibility_enabled 1

# 3) make the "Remote support active" session notification visible
#    (runtime permission on Android 13+; not needed / fails harmlessly on 11-12)
adb shell pm grant net.mithqal.remoteaccess android.permission.POST_NOTIFICATIONS

# 4) keep the background connection alive (no Doze)
adb shell dumpsys deviceidle whitelist +net.mithqal.remoteaccess
```
All four **survive reboots**. Re-run only if the agent app is reinstalled or its
data is cleared.

## ⚠️ Validate on ONE Z93 first (important)
The `appops` trick is reliable but ROM-dependent — Google flagged that some
Android 14/15 OEM builds vary. **Before rolling out to all 257 devices, prove it
on a single Z93:**

1. Build + install the `targetSdk 33` agent on one Z93; enrol it from the dashboard.
2. Run `setup-remote-access.sh` on it.
3. From the dashboard, click **Start session**.
4. ✅ Success = the screen streams and **NO "Start casting?" dialog appears on the
   device**. (If the dialog still appears, the appops route is blocked on this ROM —
   stop and tell the dev; we'll switch plans before touching the other devices.)

## Moving a kiosk from the old `com.example.remote_access` build
The package name is now final: **`net.mithqal.remoteaccess`** (release-signed; see
"Release signing" in `../REMOTE_ACCESS_SETUP.md`). Android treats it as a
**different app** from the old placeholder `com.example.remote_access`, so the
grants above do not carry over. Per kiosk:
1. In the dashboard, **Revoke** the device's remote access (kills the old token).
2. `adb uninstall com.example.remote_access`
3. Install the new release APK, enrol it with a **new** code from the dashboard.
4. Run `setup-remote-access.sh` again.

## Notes
- `PKG` in the script must always equal `applicationId` in
  `android/app/build.gradle.kts` (`net.mithqal.remoteaccess`). Do not change it:
  a new id means a new app on every kiosk and re-provisioning all of them.
- This is the same mechanism used by RustDesk / droidVNC-NG for unattended Android.
- Auto-start-on-boot + staying connected in the background is a **separate** piece
  (in the app itself) — added once tap-free capture is confirmed here.
