#!/usr/bin/env bash
#
# One-time per-device provisioning for the Remote Access agent (Option A:
# unattended, tap-free remote control on generic Android kiosks).
#
# Run ONCE per kiosk during setup, with the device connected over USB
# (USB debugging enabled) or wireless ADB. Every grant below PERSISTS across
# reboots. Re-run only if the agent app is uninstalled/reinstalled or its app
# data is cleared.
#
# Requires: the agent APK built with targetSdk = 33 (see android/app/build.gradle.kts)
# and already installed on the device.
#
# Usage:
#   ./setup-remote-access.sh            # uses the single connected device
#   ANDROID_SERIAL=XXXX ./setup-remote-access.sh   # target a specific device
#
set -euo pipefail

PKG="com.example.remote_access"               # = applicationId in build.gradle.kts
A11Y_SERVICE="${PKG}/${PKG}.RemoteInputService"

echo "== Remote Access provisioning =="
echo "Package: $PKG"
adb devices

# 1) Tap-free screen capture: grant the PROJECT_MEDIA app-op.
#    This is what removes the per-session "Start casting?" system dialog.
echo
echo "1/4  Granting tap-free screen capture (PROJECT_MEDIA)..."
# Older syntax (some ROMs) + the robust modern form. One of them applies; the
# '|| true' tolerates the form a given ROM doesn't recognise.
adb shell appops set "$PKG" PROJECT_MEDIA allow || true
adb shell cmd appops set --user 0 "$PKG" PROJECT_MEDIA allow

# 2) Remote input: enable our AccessibilityService (cannot be enabled by MDM).
#    Append to any existing services rather than overwriting them.
echo "2/4  Enabling the accessibility service for remote input..."
EXISTING="$(adb shell settings get secure enabled_accessibility_services | tr -d '\r')"
if [ -z "$EXISTING" ] || [ "$EXISTING" = "null" ]; then
  NEW="$A11Y_SERVICE"
elif printf '%s' "$EXISTING" | grep -q "$A11Y_SERVICE"; then
  NEW="$EXISTING"                              # already present
else
  NEW="${EXISTING}:${A11Y_SERVICE}"
fi
adb shell settings put secure enabled_accessibility_services "$NEW"
adb shell settings put secure accessibility_enabled 1

# 3) Keep the background connection alive: exempt from battery optimisation / Doze.
echo "3/4  Exempting the agent from battery optimisation..."
adb shell dumpsys deviceidle whitelist +"$PKG" || true

# 4) Verify.
echo "4/4  Verifying..."
echo -n "  PROJECT_MEDIA  : "; adb shell cmd appops get "$PKG" PROJECT_MEDIA 2>/dev/null || echo "(could not read)"
echo -n "  accessibility  : "; adb shell settings get secure enabled_accessibility_services

echo
echo "Done. After this, the device can be remote-controlled with NO on-device tap."
echo "If the agent app is reinstalled or its data cleared, re-run this script."
