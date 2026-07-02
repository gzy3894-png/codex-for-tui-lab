#!/usr/bin/env sh
set -eu

SOURCE_DIR="${1:?usage: lab-real-api-contract.sh SOURCE_DIR}"
SCRIPT_DIR="$SOURCE_DIR/android-arm64-musl"
TMP="${TMPDIR:-/tmp}/codex-tui-lab-real-api.$$"
PYTHON="${PYTHON:-python3}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[ -n "${KRILL_API_BASE:-}" ] || fail "missing KRILL_API_BASE secret"
[ -n "${KRILL_API_KEY:-}" ] || fail "missing KRILL_API_KEY secret"

rm -rf "$TMP"
mkdir -p "$TMP/home" "$TMP/logs"
trap ':' EXIT HUP INT TERM

(
  . "$SCRIPT_DIR/lib/codex-zh-common.sh"
  . "$SCRIPT_DIR/lib/codex-zh-config.sh"
  export HOME="$TMP/home"
  export CODEX_HOME="$TMP/home/.codex"
  export CODEX_ZH_FORCE_STDIN=1
  export CODEX_ZH_SETUP_MODE=third_party
  export CODEX_ZH_API_BASE="$KRILL_API_BASE"
  export CODEX_ZH_API_KEY="$KRILL_API_KEY"
  export CODEX_ZH_DEFAULT_MODEL="${KRILL_TEST_MODEL:-}"
  codex_config_prompt_third_party >"$TMP/logs/config.stdout" 2>"$TMP/logs/config.stderr"
) || {
  sed -n '1,120p' "$TMP/logs/config.stderr" >&2 || true
  fail "real API config flow failed"
}

CFG="$TMP/home/.codex/config.toml"
CATALOG="$TMP/home/.codex/model_catalog.json"
[ -s "$CFG" ] || fail "config.toml was not written"
[ -s "$CATALOG" ] || fail "model_catalog.json was not written"

if grep -F "$KRILL_API_KEY" "$CFG" >/dev/null 2>&1; then
  fail "API key leaked into config.toml"
fi

"$PYTHON" - "$CFG" "$CATALOG" <<'PY'
import json
import sys
import tomllib

cfg_path, catalog_path = sys.argv[1:3]
with open(cfg_path, "rb") as fh:
    cfg = tomllib.load(fh)
model = cfg.get("model", "")
if not model or "\n" in model or "可用模型" in model:
    raise SystemExit(f"invalid model value: {model!r}")
with open(catalog_path, "r", encoding="utf-8") as fh:
    catalog = json.load(fh)
for item in catalog.get("models", []):
    value = item.get("web_search_tool_type")
    if value is not None and value not in {"text", "text_and_image"}:
        raise SystemExit(f"invalid web_search_tool_type: {value!r}")
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
print("OK: real API rendered config passed")
PY

printf 'OK: real API contract passed\n'
