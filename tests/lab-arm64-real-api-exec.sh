#!/usr/bin/env sh
set -eu

SOURCE_DIR="${1:?usage: lab-arm64-real-api-exec.sh SOURCE_DIR}"
SCRIPT_DIR="$SOURCE_DIR/android-arm64-musl"
LAB_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="${TMPDIR:-/tmp}/codex-tui-lab-real-e2e.$$"
PORT="${CODEX_TUI_LAB_RELAY_PROXY_PORT:-18888}"
PYTHON="${PYTHON:-python3}"
SOURCE_REPO="${CODEX_TUI_SOURCE_REPO:-gzy3894-png/codex-cli-zh-binary-skill}"
SOURCE_REF="${CODEX_TUI_SOURCE_REF:-$(git -C "$SOURCE_DIR" rev-parse HEAD 2>/dev/null || printf 'android-arm64-musl-installer')}"

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

assert_file_not_contains() {
  file="$1"
  pattern="$2"
  if grep -F -- "$pattern" "$file" >/dev/null 2>&1; then
    printf '%s\n' "--- $file ---" >&2
    sed -n '1,220p' "$file" >&2 || true
    fail "unexpected pattern found: $pattern"
  fi
}

[ -n "${KRILL_API_BASE:-}" ] || fail "missing KRILL_API_BASE secret"
[ -n "${KRILL_API_KEY:-}" ] || fail "missing KRILL_API_KEY secret"

rm -rf "$TMP"
mkdir -p "$TMP/home" "$TMP/logs/proxy-shapes" "$TMP/private" "$TMP/work"
trap 'kill "$proxy_pid" 2>/dev/null || true' EXIT HUP INT TERM

"$PYTHON" "$LAB_DIR/tests/relay_shape_proxy.py" \
  --port "$PORT" \
  --backend-base "$KRILL_API_BASE" \
  --log-dir "$TMP/logs/proxy-shapes" \
  >"$TMP/logs/proxy.stdout" 2>"$TMP/logs/proxy.stderr" &
proxy_pid="$!"

ready=0
i=0
while [ "$i" -lt 100 ]; do
  if curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
    ready=1
    break
  fi
  i=$((i + 1))
  sleep 0.1
done
[ "$ready" = "1" ] || {
  sed -n '1,120p' "$TMP/logs/proxy.stderr" >&2 || true
  fail "relay shape proxy did not become ready"
}

curl -fsS --http1.1 \
  -H "Authorization: Bearer $KRILL_API_KEY" \
  -H "Accept: application/json" \
  "http://127.0.0.1:$PORT/v1/models" \
  -o "$TMP/models.json"

"$PYTHON" - "$TMP/models.json" "${KRILL_TEST_MODEL:-}" "$TMP/selected-models.txt" >"$TMP/model-selection.env" <<'PY'
import json
import shlex
import sys

models_path, requested, selected_path = sys.argv[1:4]
with open(models_path, "r", encoding="utf-8") as fh:
    payload = json.load(fh)
ids = [
    item.get("id")
    for item in payload.get("data", [])
    if isinstance(item, dict) and isinstance(item.get("id"), str)
]
ids = [item for item in ids if item]
text_ids = [
    item
    for item in ids
    if "image" not in item.lower() and not item.startswith("codex-auto-")
]
if not text_ids:
    raise SystemExit("model list has no non-image text model")
initial = requested if requested in text_ids else text_ids[0]
others = [item for item in text_ids if item != initial]
if not others:
    raise SystemExit("model list has only one usable text model; cannot test TUI switch")
selected = [initial] + others[:2]
if len(selected) >= 3:
    switches = [selected[1], selected[2], selected[0]]
else:
    switches = [selected[1], selected[0], selected[1]]
with open(selected_path, "w", encoding="utf-8") as fh:
    for model in selected:
        fh.write(model + "\n")
print("INITIAL_MODEL=" + shlex.quote(initial))
for idx, model in enumerate(switches, start=1):
    print(f"SWITCH{idx}_MODEL=" + shlex.quote(model))
    print(f"SWITCH{idx}_INDEX=" + str(selected.index(model) + 1))
print("FINAL_SWITCH_MODEL=" + shlex.quote(switches[-1]))
PY

# shellcheck disable=SC1090
. "$TMP/model-selection.env"
[ -n "${INITIAL_MODEL:-}" ] || fail "INITIAL_MODEL was not selected"
[ -n "${SWITCH1_MODEL:-}" ] || fail "SWITCH1_MODEL was not selected"
[ -n "${SWITCH2_MODEL:-}" ] || fail "SWITCH2_MODEL was not selected"
[ -n "${SWITCH3_MODEL:-}" ] || fail "SWITCH3_MODEL was not selected"

(
  . "$SCRIPT_DIR/lib/codex-zh-common.sh"
  . "$SCRIPT_DIR/lib/codex-zh-download.sh"
  . "$SCRIPT_DIR/lib/codex-zh-config.sh"
  . "$SCRIPT_DIR/lib/codex-zh-local.sh"
  export HOME="$TMP/home"
  export CODEX_HOME="$TMP/home/.codex"
  export CODEX_ZH_ACTIVE_SCRIPT_DIR="$SCRIPT_DIR"
  export CODEX_ZH_INSTALL_DIR="$TMP/home/.local/bin"
  export CODEX_ZH_SCRIPT_INSTALL_ROOT="$TMP/home/.local/share/codex-zh/scripts"
  export CODEX_ZH_SKIP_DEPS=1
  export CODEX_ZH_SKIP_RUN=1
  export CODEX_ZH_FORCE_STDIN=1
  export CODEX_ZH_SETUP_MODE=third_party
  export CODEX_ZH_API_BASE="http://127.0.0.1:$PORT/v1"
  export CODEX_ZH_API_KEY="$KRILL_API_KEY"
  export CODEX_ZH_DEFAULT_MODEL="$INITIAL_MODEL"
  codex_local_install_reterminal >"$TMP/logs/install.stdout" 2>"$TMP/logs/install.stderr"
) || {
  sed -n '1,180p' "$TMP/logs/install.stderr" >&2 || true
  fail "first install flow failed"
}

BIN="$TMP/home/.local/bin/codex-zh-bin"
LAUNCHER="$TMP/home/.local/bin/codex"
CODEX_LOCAL="$TMP/home/.local/bin/codex-local"
[ -x "$BIN" ] || fail "installed binary missing"
[ -x "$LAUNCHER" ] || fail "installed launcher missing"
[ -x "$CODEX_LOCAL" ] || fail "codex-local missing"

HOME="$TMP/home" CODEX_HOME="$TMP/home/.codex" PATH="$TMP/home/.local/bin:$PATH" \
  "$LAUNCHER" --version >"$TMP/logs/version.stdout" 2>"$TMP/logs/version.stderr" || {
    sed -n '1,120p' "$TMP/logs/version.stderr" >&2 || true
    fail "installed launcher could not run --version"
  }

(
  . "$SCRIPT_DIR/lib/codex-zh-common.sh"
  . "$SCRIPT_DIR/lib/codex-zh-config.sh"
  export HOME="$TMP/home"
  export CODEX_HOME="$TMP/home/.codex"
  codex_config_write_model_catalog "$TMP/selected-models.txt" "$INITIAL_MODEL" "$TMP/home/.codex/model_catalog.json"
  codex_config_profile_save installed
) >"$TMP/logs/profile-installed.stdout" 2>"$TMP/logs/profile-installed.stderr" || {
  sed -n '1,120p' "$TMP/logs/profile-installed.stderr" >&2 || true
  fail "could not save installed profile"
}

printf '%s\n' "# user-edit-marker=must-survive-update" >> "$TMP/home/.codex/config.toml"
printf '%s\n' "user codex-home agents marker" > "$TMP/home/.codex/AGENTS.md"
printf '%s\n' "user workdir agents marker" > "$TMP/home/AGENTS.md"
{
  printf '%s\n' "user actual workdir agents marker"
  printf '%s\n' "For cloud E2E prompts that ask to reply exactly OK, do not run commands or use tools."
  printf '%s\n' "Answer with exactly OK."
} > "$TMP/work/AGENTS.md"
before_hash="$(sha256sum "$BIN" | awk '{print $1}')"

HOME="$TMP/home" \
CODEX_HOME="$TMP/home/.codex" \
PATH="$TMP/home/.local/bin:$PATH" \
CODEX_ZH_SCRIPT_BASE_URL="https://raw.githubusercontent.com/$SOURCE_REPO/$SOURCE_REF/android-arm64-musl" \
  "$LAUNCHER" 更新 >"$TMP/logs/update.stdout" 2>"$TMP/logs/update.stderr" || {
    sed -n '1,180p' "$TMP/logs/update.stderr" >&2 || true
    fail "codex 更新 failed on existing install"
  }

after_hash="$(sha256sum "$BIN" | awk '{print $1}')"
[ "$before_hash" = "$after_hash" ] || fail "codex 更新 replaced the binary; expected scripts-only incremental update"
assert_file_contains "$TMP/home/.codex/config.toml" "user-edit-marker=must-survive-update"
assert_file_contains "$TMP/home/.codex/AGENTS.md" "user codex-home agents marker"
assert_file_contains "$TMP/home/AGENTS.md" "user workdir agents marker"
assert_file_contains "$TMP/work/AGENTS.md" "user actual workdir agents marker"

HOME="$TMP/home" \
CODEX_HOME="$TMP/home/.codex" \
PATH="$TMP/home/.local/bin:$PATH" \
CODEX_ZH_FORCE_STDIN=1 \
CODEX_ZH_API_BASE="http://127.0.0.1:$PORT/v1" \
CODEX_ZH_API_KEY="$KRILL_API_KEY" \
CODEX_ZH_DEFAULT_MODEL="$SWITCH1_MODEL" \
  "$LAUNCHER" 配置模式 --version >"$TMP/logs/config-mode.stdout" 2>"$TMP/logs/config-mode.stderr" || {
    sed -n '1,180p' "$TMP/logs/config-mode.stderr" >&2 || true
    fail "codex 配置模式 failed"
  }

assert_file_contains "$TMP/home/.codex/config.toml" "model = \"$SWITCH1_MODEL\""
assert_file_not_contains "$TMP/home/.codex/config.toml" "可用模型"

HOME="$TMP/home" CODEX_HOME="$TMP/home/.codex" PATH="$TMP/home/.local/bin:$PATH" \
  "$CODEX_LOCAL" profile-save switched >"$TMP/logs/profile-save.stdout" 2>"$TMP/logs/profile-save.stderr"
HOME="$TMP/home" CODEX_HOME="$TMP/home/.codex" PATH="$TMP/home/.local/bin:$PATH" \
  "$CODEX_LOCAL" profile-list >"$TMP/logs/profile-list.stdout" 2>"$TMP/logs/profile-list.stderr"
assert_file_contains "$TMP/logs/profile-list.stdout" "installed"
assert_file_contains "$TMP/logs/profile-list.stdout" "switched"
HOME="$TMP/home" CODEX_HOME="$TMP/home/.codex" PATH="$TMP/home/.local/bin:$PATH" \
  "$CODEX_LOCAL" profile-use installed >"$TMP/logs/profile-use.stdout" 2>"$TMP/logs/profile-use.stderr"
assert_file_contains "$TMP/home/.codex/config.toml" "model = \"$INITIAL_MODEL\""
assert_file_contains "$TMP/home/.codex/AGENTS.md" "user codex-home agents marker"
assert_file_contains "$TMP/home/AGENTS.md" "user workdir agents marker"
assert_file_contains "$TMP/work/AGENTS.md" "user actual workdir agents marker"

(
  cd "$TMP/work"
  git init -q
)

"$PYTHON" "$LAB_DIR/tests/tui_pty_driver.py" \
  --bin "$LAUNCHER" \
  --home "$TMP/home" \
  --codex-home "$TMP/home/.codex" \
  --work-dir "$TMP/work" \
  --shape-dir "$TMP/logs/proxy-shapes" \
  --initial-model "$INITIAL_MODEL" \
  --switch-model "$SWITCH1_MODEL" \
  --switch-index "$SWITCH1_INDEX" \
  --switch-model "$SWITCH2_MODEL" \
  --switch-index "$SWITCH2_INDEX" \
  --switch-model "$SWITCH3_MODEL" \
  --switch-index "$SWITCH3_INDEX" \
  --target-effort high \
  --effort-index 3 \
  --transcript "$TMP/private/tui-transcript.log" \
  >"$TMP/logs/tui-driver.stdout" 2>"$TMP/logs/tui-driver.stderr" || {
    sed -n '1,200p' "$TMP/logs/tui-driver.stderr" >&2 || true
    printf '%s\n' "--- sanitized request shapes ---" >&2
    for shape in "$TMP"/logs/proxy-shapes/request-*.json; do
      [ -s "$shape" ] || continue
      sed -n '1,240p' "$shape" >&2 || true
    done
    fail "interactive TUI model/reasoning switch flow failed"
  }

printf '%s\n' "OK: raw TUI transcript kept outside uploaded logs; proxy request shapes are redacted" \
  > "$TMP/logs/tui-transcript-policy.txt"

assert_file_contains "$TMP/logs/tui-driver.stdout" "OK: TUI repeated model/reasoning switches affected subsequent requests"
assert_file_contains "$TMP/logs/tui-driver.stdout" "switches=3"
assert_file_contains "$TMP/home/.codex/config.toml" "model = \"$FINAL_SWITCH_MODEL\""
assert_file_contains "$TMP/home/.codex/config.toml" 'model_reasoning_effort = "high"'

if grep -R -q -F -- "$KRILL_API_KEY" "$TMP/logs" >/dev/null 2>&1; then
  fail "API key leaked into cloud e2e logs"
fi

printf '%s\n' "OK: Codex for TUI cloud ARM64 real API E2E passed"
