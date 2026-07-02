#!/usr/bin/env sh
set -eu

LOG_ROOT="${CODEX_TUI_LAB_ANDROID_LOG_ROOT:-android-emulator-logs}"
LOG_DIR="$LOG_ROOT/logs"
LOG_FILE="$LOG_DIR/pre-emulator-launch.log"
AVD_HOME="${ANDROID_AVD_HOME:-$HOME/.android/avd}"

mkdir -p "$LOG_DIR"

{
  date -u
  printf 'ANDROID_AVD_HOME=%s\n' "${ANDROID_AVD_HOME:-}"
  ls -l /dev/kvm || true
  find "$AVD_HOME" -maxdepth 3 -type f -name config.ini -print -exec sed -n '1,220p' {} \; || true
} > "$LOG_FILE" 2>&1 || true

exit 0
