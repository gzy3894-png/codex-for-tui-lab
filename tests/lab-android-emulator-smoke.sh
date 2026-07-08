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

seed_app_settings() {
  cat > "$TMP/logs/Settings.xml" <<'XML'
<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
  <boolean name="ignore_storage_permission" value="true" />
</map>
XML
  adb push "$TMP/logs/Settings.xml" /data/local/tmp/codex-tui-settings.xml >/dev/null
  run_as "mkdir -p shared_prefs && cp /data/local/tmp/codex-tui-settings.xml shared_prefs/Settings.xml"
}

top_window_target() {
  adb shell dumpsys window 2>/dev/null \
    | sed -n \
      -e 's/.*mCurrentFocus=Window{[^ ]* [^ ]* \([^}]*\)}.*/\1/p' \
      -e 's/.*mFocusedApp=ActivityRecord{[^ ]* [^ ]* \([^ ]*\).*/\1/p' \
      -e 's/.*mResumedActivity: ActivityRecord{[^ ]* [^ ]* \([^ ]*\).*/\1/p' \
    | tr -d '\r' \
    | sed -n '1p'
}

start_main_activity() {
  label="$1"
  adb shell am start -n "$PACKAGE/$ACTIVITY" >"$TMP/logs/am-start-$label.log" 2>&1 || true
}

ensure_app_foreground() {
  label="$1"
  start_main_activity "$label"
  i=0
  while [ "$i" -lt 20 ]; do
    target="$(top_window_target)"
    printf '%s\n' "$target" > "$TMP/logs/top-window-$label.txt"
    case "$target" in
      "$PACKAGE"/*|*/"$PACKAGE"/*|*"$PACKAGE"*) return 0 ;;
    esac
    i=$((i + 1))
    sleep 1
    start_main_activity "$label-retry-$i"
  done
  adb shell dumpsys window > "$TMP/logs/window-$label.txt" 2>/dev/null || true
  adb logcat -d > "$TMP/logs/logcat-$label.txt" 2>/dev/null || true
  fail "app did not stay foreground for $label; top=$(top_window_target)"
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

write_media_request() {
  request_id="$(date +%s).$$.$1"
  kind="$1"
  path="$2"
  name="$3"
  {
    printf 'action=show\n'
    printf 'stamp=%s\n' "$request_id"
    printf 'kind=%s\n' "$kind"
    printf 'path=%s\n' "$path"
    printf 'name=%s\n' "$name"
  } > "$TMP/logs/media-request-$request_id.txt"
  adb push "$TMP/logs/media-request-$request_id.txt" "/data/local/tmp/media-request-$request_id" >/dev/null
  run_as "mkdir -p local/media-preview && cp /data/local/tmp/media-request-$request_id local/media-preview/request"
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
  adb shell dumpsys window > "$TMP/logs/window-browser-timeout-$request_id.txt" 2>/dev/null || true
  adb logcat -d > "$TMP/logs/logcat-browser-timeout-$request_id.txt" 2>/dev/null || true
  adb shell uiautomator dump /data/local/tmp/window.xml >/dev/null 2>&1 || true
  adb exec-out cat /data/local/tmp/window.xml > "$TMP/logs/window-browser-timeout-$request_id.xml" 2>/dev/null || true
  fail "browser request $request_id did not reach state=$expected"
}

wait_browser_url() {
  request_id="$1"
  expected_url="$2"
  i=0
  while [ "$i" -lt 45 ]; do
    run_as "cat local/browser/status" > "$TMP/logs/browser-status-url-$request_id.txt" 2>/dev/null || true
    if grep -F "request_id=$request_id" "$TMP/logs/browser-status-url-$request_id.txt" >/dev/null 2>&1; then
      state="$(sed -n 's/^state=//p' "$TMP/logs/browser-status-url-$request_id.txt" | sed -n '1p')"
      current_url="$(sed -n 's/^url=//p' "$TMP/logs/browser-status-url-$request_id.txt" | sed -n '1p')"
      [ "$state" = "done" ] && [ "$current_url" = "$expected_url" ] && return 0
      [ "$state" = "error" ] && {
        run_as "cat local/browser/result.json" > "$TMP/logs/browser-result-$request_id.json" || true
        fail "browser request $request_id failed while waiting for $expected_url"
      }
    fi
    i=$((i + 1))
    sleep 1
  done
  run_as "cat local/browser/status" > "$TMP/logs/browser-status-url-timeout-$request_id.txt" || true
  adb shell dumpsys window > "$TMP/logs/window-browser-url-timeout-$request_id.txt" 2>/dev/null || true
  adb logcat -d > "$TMP/logs/logcat-browser-url-timeout-$request_id.txt" 2>/dev/null || true
  fail "browser request $request_id did not load $expected_url"
}

wait_media_status() {
  stamp="$1"
  expected_kind="$2"
  i=0
  while [ "$i" -lt 30 ]; do
    if run_as "test -s local/media-preview/status && grep -F 'shown=1' local/media-preview/status && grep -F 'kind=$expected_kind' local/media-preview/status" >/dev/null 2>&1; then
      run_as "cat local/media-preview/status" > "$TMP/logs/media-status-$stamp.txt" || true
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  run_as "cat local/media-preview/status" > "$TMP/logs/media-status-timeout-$stamp.txt" || true
  fail "media request $stamp did not show kind=$expected_kind"
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

first_edit_text_center() {
  file="$1"
  python3 - "$file" <<'PY'
import re
import sys
import xml.etree.ElementTree as ET

try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception:
    print("170 760")
    raise SystemExit

for node in root.iter("node"):
    if node.attrib.get("class") == "android.widget.EditText":
        match = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.attrib.get("bounds", ""))
        if match:
            x1, y1, x2, y2 = map(int, match.groups())
            print((x1 + x2) // 2, (y1 + y2) // 2)
            raise SystemExit

print("170 760")
PY
}

text_center() {
  file="$1"
  needle="$2"
  python3 - "$file" "$needle" <<'PY'
import re
import sys
import xml.etree.ElementTree as ET

needle = sys.argv[2]
try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception:
    raise SystemExit(1)

for node in root.iter("node"):
    text = node.attrib.get("text", "") or node.attrib.get("content-desc", "")
    if needle in text:
        match = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.attrib.get("bounds", ""))
        if match:
            x1, y1, x2, y2 = map(int, match.groups())
            print((x1 + x2) // 2, (y1 + y2) // 2)
            raise SystemExit

raise SystemExit(1)
PY
}

exact_text_center() {
  file="$1"
  needle="$2"
  python3 - "$file" "$needle" <<'PY'
import re
import sys
import xml.etree.ElementTree as ET

needle = sys.argv[2]
try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception:
    raise SystemExit(1)

for node in root.iter("node"):
    text = node.attrib.get("text", "") or node.attrib.get("content-desc", "")
    if text == needle:
        match = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.attrib.get("bounds", ""))
        if match:
            x1, y1, x2, y2 = map(int, match.groups())
            print((x1 + x2) // 2, (y1 + y2) // 2)
            raise SystemExit

raise SystemExit(1)
PY
}

node_center_after() {
  file="$1"
  marker="$2"
  mode="$3"
  value="${4:-}"
  python3 - "$file" "$marker" "$mode" "$value" <<'PY'
import re
import sys
import xml.etree.ElementTree as ET

marker = sys.argv[2]
mode = sys.argv[3]
value = sys.argv[4]
try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception:
    raise SystemExit(1)

seen_marker = False
for node in root.iter("node"):
    text = node.attrib.get("text", "") or node.attrib.get("content-desc", "")
    if not seen_marker:
        if marker in text:
            seen_marker = True
        continue
    if (mode == "exact_text" and text == value) or (
        mode == "edit_text" and node.attrib.get("class") == "android.widget.EditText"
    ):
        match = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.attrib.get("bounds", ""))
        if match:
            x1, y1, x2, y2 = map(int, match.groups())
            print((x1 + x2) // 2, (y1 + y2) // 2)
            raise SystemExit

raise SystemExit(1)
PY
}

tap_text() {
  needle="$1"
  label="$2"
  adb shell uiautomator dump /data/local/tmp/window.xml >/dev/null 2>&1 || return 1
  adb exec-out cat /data/local/tmp/window.xml > "$TMP/logs/window-$label.xml" 2>/dev/null || true
  xy="$(text_center "$TMP/logs/window-$label.xml" "$needle")" || return 1
  set -- $xy
  adb shell input tap "$1" "$2" >/dev/null 2>&1
}

tap_exact_text() {
  needle="$1"
  label="$2"
  adb shell uiautomator dump /data/local/tmp/window.xml >/dev/null 2>&1 || return 1
  adb exec-out cat /data/local/tmp/window.xml > "$TMP/logs/window-$label.xml" 2>/dev/null || true
  xy="$(exact_text_center "$TMP/logs/window-$label.xml" "$needle")" || return 1
  set -- $xy
  adb shell input tap "$1" "$2" >/dev/null 2>&1
}

tap_exact_text_after() {
  marker="$1"
  needle="$2"
  label="$3"
  adb shell uiautomator dump /data/local/tmp/window.xml >/dev/null 2>&1 || return 1
  adb exec-out cat /data/local/tmp/window.xml > "$TMP/logs/window-$label.xml" 2>/dev/null || true
  xy="$(node_center_after "$TMP/logs/window-$label.xml" "$marker" exact_text "$needle")" || return 1
  set -- $xy
  adb shell input tap "$1" "$2" >/dev/null 2>&1
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
seed_app_settings
adb shell pm grant "$PACKAGE" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
adb shell appops set "$PACKAGE" MANAGE_EXTERNAL_STORAGE allow >/dev/null 2>&1 || true
start_main_activity initial
sleep 12
dismiss_blocking_dialogs after-start
ensure_app_foreground after-start

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
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Codex Browser Lab</title>
    <style>
      body { font-family: sans-serif; margin: 0; padding: 18px; }
      h1 { font-size: 26px; margin: 0 0 12px; }
      input, button { box-sizing: border-box; font-size: 22px; padding: 10px; margin: 8px 0; width: 94%; }
      #manual { height: 56px; }
      #out { margin-top: 18px; font-size: 24px; color: #0b6b3a; }
    </style>
  </head>
  <body>
    <h1 id="title">Codex Browser Lab</h1>
    <input id="manual" value="" placeholder="type here">
    <button id="go" onclick="document.getElementById('out').textContent='clicked:' + document.getElementById('manual').value">Run</button>
    <button id="intent-fallback" onclick="location.href='intent://scan/#Intent;scheme=zxing;S.browser_fallback_url=http%3A%2F%2F10.0.2.2%3A8765%2Ffallback.html;end'">Fallback</button>
    <main id="out">ready</main>
  </body>
</html>
HTML
cat > "$WWW/fallback.html" <<'HTML'
<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Codex Browser Fallback</title>
  </head>
  <body>
    <h1 id="fallback-title">Codex Browser Fallback</h1>
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

fallback_click_id="$(write_browser_request click selector "#intent-fallback")"
wait_browser_state "$fallback_click_id" waiting_for_user
fallback_external_id="$(sed -n 's/^external_request_id=//p' "$TMP/logs/browser-status-$fallback_click_id.txt" | sed -n '1p')"
[ -n "$fallback_external_id" ] || fail "external fallback prompt did not expose external_request_id"
write_browser_request external_confirm external_request_id "$fallback_external_id" >/dev/null
wait_browser_url "$fallback_external_id" "http://10.0.2.2:8765/fallback.html"
fallback_text_id="$(write_browser_request get_text selector "#fallback-title")"
wait_browser_state "$fallback_text_id" done
copy_browser_result scheme-fallback
fallback_text="$(json_value "$TMP/logs/browser-result-scheme-fallback.json" "data.text")"
[ "$fallback_text" = "Codex Browser Fallback" ] || fail "external scheme fallback did not load: $fallback_text"
return_id="$(write_browser_request navigate url "$url")"
wait_browser_state "$return_id" done

focus_id="$(write_browser_request click selector "#manual")"
wait_browser_state "$focus_id" done
clear_id="$(write_browser_request execute_js script "const el=document.getElementById('manual'); el.value=''; el.dispatchEvent(new Event('input',{bubbles:true})); el.scrollIntoView({block:'start'}); el.blur(); return el.value;")"
wait_browser_state "$clear_id" done
dismiss_blocking_dialogs before-user-input
adb exec-out screencap -p > "$TMP/logs/02-browser-before-user-tap.png" || true
tap_xy="$(first_edit_text_center "$TMP/logs/window-before-user-input.xml")"
set -- $tap_xy
adb shell input tap "$1" "$2" >/dev/null 2>&1 || true
sleep 1
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

auth_id="$(write_browser_request auth url "$url")"
wait_browser_state "$auth_id" waiting_for_user
copy_browser_result auth
adb exec-out screencap -p > "$TMP/logs/04-browser-auth-external.png" || true
adb shell am start -n "$PACKAGE/$ACTIVITY" >/dev/null 2>&1 || true
sleep 2
write_browser_request auth_done auth_request_id "$auth_id" >/dev/null
wait_browser_state "$auth_id" user_done

close_id="$(write_browser_request close)"
wait_browser_state "$close_id" closed

MEDIA="$TMP/media"
mkdir -p "$MEDIA"
printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=' | base64 -d > "$MEDIA/tiny.png"
printf 'fake mp4 payload for tray smoke\n' > "$MEDIA/clip.mp4"
i=0
while [ "$i" -lt 300 ]; do
  printf 'codex tray long text line %s\n' "$i"
  i=$((i + 1))
done > "$MEDIA/notes.md"

adb push "$MEDIA/tiny.png" /data/local/tmp/codex-tray-tiny.png >/dev/null
adb push "$MEDIA/clip.mp4" /data/local/tmp/codex-tray-clip.mp4 >/dev/null
adb push "$MEDIA/notes.md" /data/local/tmp/codex-tray-notes.md >/dev/null
run_as "mkdir -p local/media-preview/files && cp /data/local/tmp/codex-tray-tiny.png local/media-preview/files/tiny.png && cp /data/local/tmp/codex-tray-clip.mp4 local/media-preview/files/clip.mp4 && cp /data/local/tmp/codex-tray-notes.md local/media-preview/files/notes.md"

image_id="$(write_media_request image "/data/data/$PACKAGE/local/media-preview/files/tiny.png" tiny.png)"
wait_media_status "$image_id" image
video_id="$(write_media_request video "/data/data/$PACKAGE/local/media-preview/files/clip.mp4" clip.mp4)"
wait_media_status "$video_id" video
text_id="$(write_media_request text "/data/data/$PACKAGE/local/media-preview/files/notes.md" notes.md)"
wait_media_status "$text_id" text
adb exec-out screencap -p > "$TMP/logs/05-media-tray-thumbnails.png" || true

adb shell uiautomator dump /data/local/tmp/window.xml >/dev/null 2>&1 || fail "could not dump file tray UI"
adb exec-out cat /data/local/tmp/window.xml > "$TMP/logs/window-media-tray.xml" 2>/dev/null || true
grep -F 'text="文件"' "$TMP/logs/window-media-tray.xml" >/dev/null 2>&1 || fail "file tray title/entry was not visible"
grep -F 'text="发送"' "$TMP/logs/window-media-tray.xml" >/dev/null 2>&1 || fail "file tray send button was not visible"
if grep -F '预览托盘' "$TMP/logs/window-media-tray.xml" >/dev/null 2>&1; then
  fail "old preview tray wording is still visible"
fi

tap_exact_text_after "tiny.png" "发送" media-send || fail "could not tap file tray send button"
sleep 1
adb shell uiautomator dump /data/local/tmp/window.xml >/dev/null 2>&1 || fail "could not dump send file dialog"
adb exec-out cat /data/local/tmp/window.xml > "$TMP/logs/window-media-send-dialog.xml" 2>/dev/null || true
grep -F '发送文件' "$TMP/logs/window-media-send-dialog.xml" >/dev/null 2>&1 || fail "send file dialog did not open"
grep -F '附加说明' "$TMP/logs/window-media-send-dialog.xml" >/dev/null 2>&1 || fail "send file dialog missing optional note field"
send_xy="$(node_center_after "$TMP/logs/window-media-send-dialog.xml" "发送文件" edit_text)"
set -- $send_xy
adb shell input tap "$1" "$2" >/dev/null 2>&1 || true
sleep 1
adb shell input text ui-note >/dev/null 2>&1 || true
sleep 1
tap_exact_text_after "附加说明" "发送" media-send-confirm || fail "could not confirm file send"
sleep 2
run_as "test -d local/media-preview/refs" || fail "file send did not create preview refs directory"
run_as "ls local/media-preview/refs | sed -n '1p'" > "$TMP/logs/media-ref-id.txt"
ref_id="$(sed -n '1p' "$TMP/logs/media-ref-id.txt" | tr -d '\r')"
[ -n "$ref_id" ] || fail "file send did not create a preview ref"
run_as "cat local/media-preview/refs/$ref_id" > "$TMP/logs/media-ref-$ref_id.txt" || fail "preview ref missing path"
resolved_ref="$(sed -n 's/^path=//p' "$TMP/logs/media-ref-$ref_id.txt" | sed -n '1p' | tr -d '\r')"
case "$resolved_ref" in
  /data/data/"$PACKAGE"/local/media-preview/files/*|/data/user/0/"$PACKAGE"/local/media-preview/files/*) ;;
  *) fail "preview ref resolved unexpected path: $resolved_ref" ;;
esac

run_as "cat local/media-preview/request" > "$TMP/logs/media-request-final.txt" || true
if grep -F 'codex tray long text line' "$TMP/logs/media-request-final.txt" >/dev/null 2>&1; then
  fail "media bridge request dumped long text content"
fi

adb shell input keyevent KEYCODE_BACK >/dev/null 2>&1 || true
sleep 1
ensure_app_foreground before-media-add
sleep 1
if ! tap_exact_text "添加" media-add; then
  if tap_exact_text "+" media-expand-topbar || tap_exact_text "文件" media-expand-topbar-file; then
    sleep 1
    tap_exact_text "添加" media-add-expanded || tap_exact_text "添加文件" media-add-empty || fail "could not tap expanded file tray add button"
  else
    fail "could not expand preview tray add controls"
  fi
fi
sleep 3
adb exec-out screencap -p > "$TMP/logs/06-system-file-picker.png" || true
adb shell dumpsys window > "$TMP/logs/window-after-file-picker.txt" 2>/dev/null || true
if ! grep -E "documentsui|DocumentsUI|resolver" "$TMP/logs/window-after-file-picker.txt" >/dev/null 2>&1; then
  fail "system file picker did not open from preview tray"
fi
adb shell input keyevent KEYCODE_BACK >/dev/null 2>&1 || true
sleep 1

adb logcat -d > "$TMP/logs/logcat.txt" || true
printf 'OK: Android emulator browser smoke passed\n'
