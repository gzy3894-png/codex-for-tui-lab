#!/usr/bin/env sh
set -eu

SOURCE_DIR="${1:?usage: lab-update-atomic-contract.sh SOURCE_DIR}"
SCRIPT_DIR="$SOURCE_DIR/android-arm64-musl"
TMP="${TMPDIR:-/tmp}/codex-tui-lab-update.$$"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file_contains() {
  file="$1"
  pattern="$2"
  grep -F -- "$pattern" "$file" >/dev/null 2>&1 || {
    printf '%s\n' "--- $file ---" >&2
    sed -n '1,220p' "$file" >&2 || true
    fail "expected pattern not found: $pattern"
  }
}

rm -rf "$TMP"
mkdir -p "$TMP/home" "$TMP/install-root/lib" "$TMP/logs"
trap ':' EXIT HUP INT TERM

printf 'old installer\n' > "$TMP/install-root/install-reterminal-alpine.sh"
printf 'old common\n' > "$TMP/install-root/lib/codex-zh-common.sh"

set +e
(
  . "$SCRIPT_DIR/lib/codex-zh-common.sh"
  . "$SCRIPT_DIR/lib/codex-zh-download.sh"
  . "$SCRIPT_DIR/lib/codex-zh-update.sh"
  export HOME="$TMP/home"
  export CODEX_HOME="$TMP/home/.codex"
  export CODEX_ZH_SCRIPT_INSTALL_ROOT="$TMP/install-root"
  export CODEX_ZH_INSTALL_DIR="$TMP/bin"
  codex_download_first_script() {
    rel="$1"
    dest="$2"
    case "$rel" in
      install-reterminal-alpine.sh)
        mkdir -p "$(dirname "$dest")"
        printf 'new installer should not be committed before all files pass\n' > "$dest"
        chmod 755 "$dest"
        return 0
        ;;
      *)
        return 1
        ;;
    esac
  }
  codex_update_apply 0 >"$TMP/logs/update.stdout" 2>"$TMP/logs/update.stderr"
)
rc=$?
set -e

[ "$rc" -ne 0 ] || fail "update should fail when one required file cannot be downloaded"
assert_file_contains "$TMP/logs/update.stderr" "部分脚本更新失败"

if grep -F "new installer should not be committed" "$TMP/install-root/install-reterminal-alpine.sh" >/dev/null 2>&1; then
  fail "update is not atomic: first downloaded file was committed even though later files failed"
fi

assert_file_contains "$TMP/install-root/install-reterminal-alpine.sh" "old installer"
printf 'OK: update atomicity contract passed\n'
