#!/usr/bin/env sh
set -eu

SOURCE_DIR="${1:?usage: lab-arm64-codex-config-load.sh SOURCE_DIR}"
SCRIPT_DIR="$SOURCE_DIR/android-arm64-musl"
TMP="${TMPDIR:-/tmp}/codex-tui-lab-arm64.$$"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

rm -rf "$TMP"
mkdir -p "$TMP/home" "$TMP/download" "$TMP/logs"
trap ':' EXIT HUP INT TERM

(
  . "$SCRIPT_DIR/lib/codex-zh-common.sh"
  . "$SCRIPT_DIR/lib/codex-zh-config.sh"
  export HOME="$TMP/home"
  export CODEX_HOME="$TMP/home/.codex"
  printf '%s\n' "gpt-5.5" > "$TMP/models.txt"
  codex_config_write_third_party_config "http://127.0.0.1:9/v1" "sk-lab-fake" "gpt-5.5" "$TMP/models.txt"
) || fail "failed to generate test config"

grep -F 'model_auto_compact_token_limit = 220000' "$TMP/home/.codex/config.toml" >/dev/null 2>&1 ||
  fail "generated config missing common auto compact limit"
grep -F 'fast_mode = true' "$TMP/home/.codex/config.toml" >/dev/null 2>&1 ||
  fail "generated config missing fast_mode feature"
grep -F 'goals = true' "$TMP/home/.codex/config.toml" >/dev/null 2>&1 ||
  fail "generated config missing goals feature"
grep -F 'status_line = ["model-with-reasoning", "current-dir", "context-remaining", "used-tokens", "total-input-tokens", "total-output-tokens", "fast-mode", "task-progress"]' "$TMP/home/.codex/config.toml" >/dev/null 2>&1 ||
  fail "generated config missing status line template"
grep -F '"id": "priority"' "$TMP/home/.codex/model_catalog.json" >/dev/null 2>&1 ||
  fail "generated model catalog missing priority fast service tier"

archive="codex-0.142.4-zh-aarch64-unknown-linux-musl.tar.gz"
archive_url="https://github.com/gzy3894-png/codex-cli-zh-binary-skill/releases/download/codex-for-tui-v1.0.0/$archive"
curl -fsSL "$archive_url" -o "$TMP/download/$archive"
tar -xzf "$TMP/download/$archive" -C "$TMP/download"
bin="$TMP/download/codex-0.142.4-zh-aarch64-unknown-linux-musl"
[ -x "$bin" ] || chmod +x "$bin"

"$bin" --version >"$TMP/logs/version.stdout" 2>"$TMP/logs/version.stderr" || {
  sed -n '1,120p' "$TMP/logs/version.stderr" >&2 || true
  fail "ARM64 Codex binary did not execute on this runner"
}

set +e
HOME="$TMP/home" \
CODEX_HOME="$TMP/home/.codex" \
TERM=xterm-256color \
  timeout 20s "$bin" exec --skip-git-repo-check "ping" \
  >"$TMP/logs/codex-exec.stdout" 2>"$TMP/logs/codex-exec.stderr"
rc=$?
set -e

if grep -F "failed to parse model_catalog_json" "$TMP/logs/codex-exec.stderr" >/dev/null 2>&1 || \
   grep -F "unknown variant" "$TMP/logs/codex-exec.stderr" >/dev/null 2>&1; then
  sed -n '1,220p' "$TMP/logs/codex-exec.stderr" >&2 || true
  fail "real ARM64 Codex rejected generated model_catalog_json"
fi

if [ "$rc" -eq 124 ]; then
  printf 'WARN: codex exec timed out after config load; no model_catalog parse error observed\n' >&2
elif [ "$rc" -ne 0 ]; then
  printf 'INFO: codex exec exited nonzero after config load; this is acceptable without a live API\n' >&2
fi

printf 'OK: ARM64 Codex config load contract passed\n'
