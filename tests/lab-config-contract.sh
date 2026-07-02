#!/usr/bin/env sh
set -eu

SOURCE_DIR="${1:?usage: lab-config-contract.sh SOURCE_DIR}"
SCRIPT_DIR="$SOURCE_DIR/android-arm64-musl"
LAB_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="${TMPDIR:-/tmp}/codex-tui-lab-config.$$"
PORT="${CODEX_TUI_LAB_FAKE_API_PORT:-18765}"
PYTHON="${PYTHON:-python3}"

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

rm -rf "$TMP"
mkdir -p "$TMP/home" "$TMP/logs"

"$PYTHON" "$LAB_DIR/tests/fake_openai_server.py" \
  --port "$PORT" \
  --models "gpt-5.4,gpt-5.4-mini,gpt-5.5,codex-auto-review" \
  > "$TMP/logs/fake-api.log" 2>&1 &
server_pid="$!"
trap 'kill "$server_pid" 2>/dev/null || true' EXIT HUP INT TERM

ready=0
i=0
while [ "$i" -lt 50 ]; do
  if curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
    ready=1
    break
  fi
  i=$((i + 1))
  sleep 0.1
done
[ "$ready" = "1" ] || {
  sed -n '1,120p' "$TMP/logs/fake-api.log" >&2 || true
  fail "fake API server did not become ready"
}

(
  . "$SCRIPT_DIR/lib/codex-zh-common.sh"
  . "$SCRIPT_DIR/lib/codex-zh-config.sh"
  export HOME="$TMP/home"
  export CODEX_HOME="$TMP/home/.codex"
  export CODEX_ZH_FORCE_STDIN=1
  export CODEX_ZH_SETUP_MODE=third_party
  export CODEX_ZH_API_BASE="http://127.0.0.1:$PORT/v1"
  export CODEX_ZH_API_KEY="sk-lab-fake"
  export CODEX_ZH_DEFAULT_MODEL="gpt-5.5"
  codex_config_prompt_third_party >"$TMP/logs/config.stdout" 2>"$TMP/logs/config.stderr"
) || {
  sed -n '1,200p' "$TMP/logs/config.stderr" >&2 || true
  fail "codex_config_prompt_third_party failed"
}

CFG="$TMP/home/.codex/config.toml"
AUTH="$TMP/home/.codex/auth.json"
CATALOG="$TMP/home/.codex/model_catalog.json"
HELPER="$TMP/home/.codex/bin/provider-api-key"

[ -s "$CFG" ] || fail "config.toml was not written"
[ -s "$AUTH" ] || fail "auth.json was not written"
[ -s "$CATALOG" ] || fail "model_catalog.json was not written"
[ -x "$HELPER" ] || fail "provider-api-key helper was not executable"

assert_file_contains "$CFG" 'model = "gpt-5.5"'
assert_file_not_contains "$CFG" "可用模型"
assert_file_not_contains "$CFG" "sk-lab-fake"
assert_file_contains "$AUTH" '"OPENAI_API_KEY"'
[ "$(HOME="$TMP/home" CODEX_HOME="$TMP/home/.codex" "$HELPER")" = "sk-lab-fake" ] || fail "provider-api-key did not read auth.json"

"$PYTHON" - "$CFG" "$CATALOG" <<'PY'
import json
import sys
import tomllib

cfg_path, catalog_path = sys.argv[1:3]
with open(cfg_path, "rb") as fh:
    cfg = tomllib.load(fh)
model = cfg.get("model")
if model != "gpt-5.5":
    raise SystemExit(f"model should be a single selected id, got {model!r}")
if "\n" in model or "可用模型" in model:
    raise SystemExit(f"polluted model value: {model!r}")
with open(catalog_path, "r", encoding="utf-8") as fh:
    catalog = json.load(fh)
models = catalog.get("models")
if not isinstance(models, list) or not models:
    raise SystemExit("model_catalog.json has no models list")
allowed_web_search_types = {"text", "text_and_image"}
for item in models:
    slug = item.get("slug")
    if not slug:
        raise SystemExit(f"catalog item missing slug: {item!r}")
    value = item.get("web_search_tool_type")
    if value is not None and value not in allowed_web_search_types:
        raise SystemExit(
            "invalid web_search_tool_type for current Codex: "
            f"{value!r}; expected one of {sorted(allowed_web_search_types)}"
        )
    levels = item.get("supported_reasoning_levels")
    if not isinstance(levels, list):
        raise SystemExit(f"supported_reasoning_levels should be a list: {item!r}")
    for level in levels:
        if not isinstance(level, dict):
            raise SystemExit(
                "supported_reasoning_levels entries must be objects with "
                f"effort/description, got {level!r}"
            )
        if not isinstance(level.get("effort"), str) or not level["effort"]:
            raise SystemExit(f"reasoning level missing effort: {level!r}")
        if not isinstance(level.get("description"), str):
            raise SystemExit(f"reasoning level missing description: {level!r}")
print("OK: config and model catalog contract passed")
PY

printf 'OK: fake API config contract passed\n'
