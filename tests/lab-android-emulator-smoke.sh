#!/usr/bin/env sh
set -eu

SOURCE_DIR="${1:?usage: lab-android-emulator-smoke.sh SOURCE_DIR}"
TMP="${TMPDIR:-/tmp}/codex-tui-lab-android.$$"
mkdir -p "$TMP/logs"
trap ':' EXIT HUP INT TERM

APK="${CODEX_TUI_APK:-$SOURCE_DIR/android-app/app/build/outputs/apk/debug/app-debug.apk}"
PACKAGE="${CODEX_TUI_PACKAGE:-com.gzy3894.codexfortui.debug}"
ACTIVITY="${CODEX_TUI_ACTIVITY:-com.rk.terminal.ui.activities.terminal.MainActivity}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[ -s "$APK" ] || fail "APK not found: $APK"

adb wait-for-device
boot=""
i=0
while [ "$i" -lt 90 ]; do
  boot="$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' | sed -n '1p' || true)"
  [ "$boot" = "1" ] && break
  i=$((i + 1))
  sleep 2
done
[ "$boot" = "1" ] || fail "emulator did not finish booting"

adb install -r "$APK" >"$TMP/logs/install.log"
adb shell pm clear "$PACKAGE" >/dev/null || true
adb shell am start -n "$PACKAGE/$ACTIVITY" >"$TMP/logs/am-start.log"
sleep 12

pid="$(adb shell pidof "$PACKAGE" 2>/dev/null | tr -d '\r' | sed -n '1p' || true)"
[ -n "$pid" ] || {
  adb logcat -d > "$TMP/logs/logcat.txt" || true
  fail "app process is not running after launch"
}

if adb shell run-as "$PACKAGE" pwd >/dev/null 2>&1; then
  adb shell run-as "$PACKAGE" sh -c 'find . -maxdepth 4 -type f | sort | sed -n "1,200p"' > "$TMP/logs/private-files.txt" || true
  if adb shell run-as "$PACKAGE" sh -c 'test -e local/alpine/sdcard/.codex' >/dev/null 2>&1; then
    fail "legacy local/alpine/sdcard/.codex exists in app private data"
  fi
else
  printf 'WARN: run-as unavailable for %s; private data assertions skipped\n' "$PACKAGE" >&2
fi

adb logcat -d > "$TMP/logs/logcat.txt" || true
printf 'OK: Android emulator launch smoke passed\n'
