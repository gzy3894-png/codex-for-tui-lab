#!/usr/bin/env sh
set -eu

SOURCE_DIR="${1:?usage: lab-android-emulator-smoke.sh SOURCE_DIR}"
TMP="${CODEX_TUI_LAB_ANDROID_LOG_ROOT:-${TMPDIR:-/tmp}/codex-tui-lab-android-$$}"
mkdir -p "$TMP/logs"
trap ':' EXIT HUP INT TERM

APK="${CODEX_TUI_APK:-$SOURCE_DIR/android-app/app/build/outputs/apk/debug/app-debug.apk}"
PACKAGE="${CODEX_TUI_PACKAGE:-com.gzy3894.codexfortui.test}"
ACTIVITY="${CODEX_TUI_ACTIVITY:-com.rk.terminal.ui.activities.terminal.MainActivity}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

run_as() {
  quoted="$(printf '%s' "$1" | sed "s/'/'\\\\''/g; s/^/'/; s/$/'/")"
  adb shell run-as "$PACKAGE" sh -c "$quoted"
}

write_browser_request() {
  request_id="$(date +%s).$$.$1"
  action="$1"
  shift
  {
    printf 'request_id=%s\n' "$request_id"
    printf 'stamp=%s\n' "$request_id"
    printf 'action=%s\n' "$action"
    while [ "$#" -gt 0 ]; do
      printf '%s=%s\n' "$1" "$2"
      shift 2
    done
  } > "$TMP/logs/browser-request-$request_id.txt"
  adb push "$TMP/logs/browser-request-$request_id.txt" "/data/local/tmp/browser-request-$request_id" >/dev/null
  run_as "mkdir -p local/browser && cp /data/local/tmp/browser-request-$request_id local/browser/request"
  printf '%s\n' "$request_id"
}

wait_browser_state() {
  request_id="$1"
  expected="$2"
  i=0
  while [ "$i" -lt 45 ]; do
    if run_as "test -s local/browser/status && grep -F 'request_id=$request_id' local/browser/status" >/dev/null 2>&1; then
      run_as "cat local/browser/status" > "$TMP/logs/browser-status-$request_id.txt" || true
      state="$(sed -n 's/^state=//p' "$TMP/logs/browser-status-$request_id.txt" | sed -n '1p')"
      [ "$state" = "$expected" ] && return 0
      [ "$state" = "error" ] && {
        run_as "cat local/browser/result.json" > "$TMP/logs/browser-result-$request_id.json" || true
        fail "browser request $request_id failed"
      }
    fi
    i=$((i + 1))
    sleep 1
  done
  run_as "cat local/browser/status" > "$TMP/logs/browser-status-timeout-$request_id.txt" || true
  fail "browser request $request_id did not reach state=$expected"
}

copy_browser_result() {
  label="$1"
  run_as "cat local/browser/result.json" > "$TMP/logs/browser-result-$label.json"
}

json_value() {
  file="$1"
  expr="$2"
  python3 - "$file" "$expr" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
value = data
for part in sys.argv[2].split("."):
    if part:
        value = value[part]
print(value)
PY
}

dismiss_blocking_dialogs() {
  label="${1:-dialog}"
  adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS >/dev/null 2>&1 || true
  if adb shell uiautomator dump /data/local/tmp/window.xml >/dev/null 2>&1; then
    adb exec-out cat /data/local/tmp/window.xml > "$TMP/logs/window-$label.xml" 2>/dev/null || true
    if grep -E "isn'?t responding|Wait" "$TMP/logs/window-$label.xml" >/dev/null 2>&1; then
      adb shell input tap 360 1380 >/dev/null 2>&1 || true
      sleep 1
    fi
  fi
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
adb shell pm grant "$PACKAGE" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
adb shell appops set "$PACKAGE" MANAGE_EXTERNAL_STORAGE allow >/dev/null 2>&1 || true
adb shell am start -n "$PACKAGE/$ACTIVITY" >"$TMP/logs/am-start.log"
sleep 12
dismiss_blocking_dialogs after-start

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
  fail "run-as unavailable for $PACKAGE; browser bridge assertions require debug private-data access"
fi

WWW="$TMP/www"
mkdir -p "$WWW"
cat > "$WWW/basic.html" <<'HTML'
<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <title>Codex Browser Lab</title>
    <style>
      body { font-family: sans-serif; padding: 32px; }
      input, button { font-size: 22px; padding: 10px; margin: 8px 0; width: 90%; }
      #out { margin-top: 24px; font-size: 24px; color: #0b6b3a; }
    </style>
  </head>
  <body>
    <h1 id="title">Codex Browser Lab</h1>
    <input id="manual" value="" placeholder="type here">
    <button id="go" onclick="document.getElementById('out').textContent='clicked:' + document.getElementById('manual').value">Run</button>
    <main id="out">ready</main>
  </body>
</html>
HTML
python3 -m http.server 8765 --bind 0.0.0.0 --directory "$WWW" > "$TMP/logs/http-server.log" 2>&1 &
http_pid="$!"
trap 'kill "$http_pid" >/dev/null 2>&1 || true' EXIT HUP INT TERM

url="http://10.0.2.2:8765/basic.html"
open_id="$(write_browser_request navigate url "$url")"
wait_browser_state "$open_id" done
copy_browser_result open
dismiss_blocking_dialogs after-open
adb exec-out screencap -p > "$TMP/logs/01-browser-open.png" || true
grep -F "Codex Browser Lab" "$TMP/logs/browser-result-open.json" >/dev/null || fail "browser did not report test page title"

text_id="$(write_browser_request get_text selector "#title")"
wait_browser_state "$text_id" done
copy_browser_result title-text
title_text="$(json_value "$TMP/logs/browser-result-title-text.json" "data.text")"
[ "$title_text" = "Codex Browser Lab" ] || fail "browser text read failed: $title_text"

type_id="$(write_browser_request type selector "#manual" text "bridge")"
wait_browser_state "$type_id" done
click_id="$(write_browser_request click selector "#go")"
wait_browser_state "$click_id" done
read_id="$(write_browser_request execute_js script "return document.getElementById('out').innerText;")"
wait_browser_state "$read_id" done
copy_browser_result bridge-click
bridge_value="$(json_value "$TMP/logs/browser-result-bridge-click.json" "data.value")"
[ "$bridge_value" = "clicked:bridge" ] || fail "bridge click/type did not update DOM: $bridge_value"

focus_id="$(write_browser_request click selector "#manual")"
wait_browser_state "$focus_id" done
dismiss_blocking_dialogs before-user-input
adb shell input text manual42 >/dev/null 2>&1 || true
sleep 2
dismiss_blocking_dialogs after-user-input
adb exec-out screencap -p > "$TMP/logs/02-browser-user-input.png" || true
manual_id="$(write_browser_request execute_js script "return document.getElementById('manual').value;")"
wait_browser_state "$manual_id" done
copy_browser_result user-input
manual_value="$(json_value "$TMP/logs/browser-result-user-input.json" "data.value")"
printf '%s\n' "$manual_value" | grep -F "manual42" >/dev/null || fail "real WebView did not receive adb/user input: $manual_value"

shot_id="$(write_browser_request screenshot)"
wait_browser_state "$shot_id" done
copy_browser_result screenshot
shot_path="$(json_value "$TMP/logs/browser-result-screenshot.json" "data.path")"
run_as "test -s '$shot_path'" || fail "browser screenshot artifact missing: $shot_path"

wait_id="$(write_browser_request user_wait message "请完成测试验证")"
wait_browser_state "$wait_id" waiting_for_user
adb exec-out screencap -p > "$TMP/logs/03-browser-waiting-for-user.png" || true
done_id="$(write_browser_request user_done)"
wait_browser_state "$done_id" done
copy_browser_result user-done

adb logcat -d > "$TMP/logs/logcat.txt" || true
printf 'OK: Android emulator browser smoke passed\n'
