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
assert_file_contains "$CFG" 'model_auto_compact_token_limit = 220000'
assert_file_contains "$CFG" 'service_tier = "default"'
assert_file_contains "$CFG" 'disable_response_storage = true'
assert_file_contains "$CFG" '[features]'
assert_file_contains "$CFG" 'auto_compaction = true'
assert_file_contains "$CFG" 'fast_mode = true'
assert_file_contains "$CFG" 'goals = true'
assert_file_contains "$CFG" 'hooks = false'
assert_file_contains "$CFG" '[tui]'
assert_file_contains "$CFG" 'status_line = ["model-with-reasoning", "current-dir", "context-remaining", "used-tokens", "total-input-tokens", "total-output-tokens", "fast-mode", "task-progress"]'
assert_file_contains "$CFG" 'status_line_use_colors = true'
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
if cfg.get("model_auto_compact_token_limit") != 220000:
    raise SystemExit("common auto compact token limit should be 220000")
if cfg.get("service_tier") != "default":
    raise SystemExit("common service_tier should default to explicit default")
if cfg.get("disable_response_storage") is not True:
    raise SystemExit("disable_response_storage should be true")
features = cfg.get("features")
if not isinstance(features, dict):
    raise SystemExit("[features] table missing")
expected_features = {
    "auto_compaction": True,
    "fast_mode": True,
    "goals": True,
    "hooks": False,
}
for key, expected in expected_features.items():
    if features.get(key) is not expected:
        raise SystemExit(f"features.{key} should be {expected!r}, got {features.get(key)!r}")
tui = cfg.get("tui")
if not isinstance(tui, dict):
    raise SystemExit("[tui] table missing")
expected_status_line = [
    "model-with-reasoning",
    "current-dir",
    "context-remaining",
    "used-tokens",
    "total-input-tokens",
    "total-output-tokens",
    "fast-mode",
    "task-progress",
]
if tui.get("status_line") != expected_status_line:
    raise SystemExit(f"unexpected tui.status_line: {tui.get('status_line')!r}")
if tui.get("status_line_use_colors") is not True:
    raise SystemExit("tui.status_line_use_colors should be true")
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
    efforts = [level.get("effort") for level in levels if isinstance(level, dict)]
    if efforts != ["low", "medium", "high", "xhigh"]:
        raise SystemExit(f"unexpected reasoning efforts for {slug}: {efforts!r}")
    if item.get("default_verbosity") != "low":
        raise SystemExit(f"default_verbosity should be low for {slug}")
    if item.get("auto_compact_token_limit") != 220000:
        raise SystemExit(f"auto_compact_token_limit should be 220000 for {slug}")
    if item.get("additional_speed_tiers") != ["fast"]:
        raise SystemExit(f"additional_speed_tiers should expose fast for {slug}")
    service_tiers = item.get("service_tiers")
    if not isinstance(service_tiers, list) or not service_tiers:
        raise SystemExit(f"service_tiers should expose fast mode for {slug}")
    fast_tiers = [
        tier for tier in service_tiers
        if isinstance(tier, dict) and tier.get("id") == "priority"
    ]
    if not fast_tiers:
        raise SystemExit(f"service_tiers missing priority fast tier for {slug}: {service_tiers!r}")
    fast_tier = fast_tiers[0]
    if fast_tier.get("name") != "Fast" or not isinstance(fast_tier.get("description"), str):
        raise SystemExit(f"invalid fast tier metadata for {slug}: {fast_tier!r}")
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

PRESERVE_HOME="$TMP/preserve-home"
mkdir -p "$PRESERVE_HOME/.codex"
cat > "$PRESERVE_HOME/.codex/config.toml" <<'EOF'
# user-edit-marker=must-survive-config-mode
model = "old-model"
model_provider = "old-provider"
model_reasoning_effort = "high"
model_auto_compact_token_limit = 210000
service_tier = "default"

[features]
auto_compaction = false

[tui]
status_line = ["model", "current-dir"]
status_line_use_colors = false

[custom_section]
flag = "survive"

[model_providers.custom]
name = "stale"
base_url = "https://stale.invalid/v1"
wire_api = "responses"
requires_openai_auth = false

[model_providers.custom.auth]
command = "/stale/provider-api-key"
# user-tail-marker=must-survive-provider-rewrite
EOF
printf '%s\n' "gpt-5.4" "gpt-5.5" > "$TMP/preserve-models.txt"
(
  . "$SCRIPT_DIR/lib/codex-zh-common.sh"
  . "$SCRIPT_DIR/lib/codex-zh-config.sh"
  export HOME="$PRESERVE_HOME"
  export CODEX_HOME="$PRESERVE_HOME/.codex"
  codex_config_write_third_party_config "http://127.0.0.1:$PORT/v1" "sk-lab-fake" "gpt-5.4" "$TMP/preserve-models.txt"
) || fail "preservation config rewrite failed"

PCFG="$PRESERVE_HOME/.codex/config.toml"
assert_file_contains "$PCFG" '# user-edit-marker=must-survive-config-mode'
assert_file_contains "$PCFG" 'model = "gpt-5.4"'
assert_file_contains "$PCFG" 'model_provider = "custom"'
assert_file_contains "$PCFG" 'model_reasoning_effort = "high"'
assert_file_contains "$PCFG" 'model_auto_compact_token_limit = 210000'
assert_file_contains "$PCFG" 'service_tier = "default"'
assert_file_contains "$PCFG" 'auto_compaction = false'
assert_file_contains "$PCFG" 'fast_mode = true'
assert_file_contains "$PCFG" 'goals = true'
assert_file_contains "$PCFG" 'hooks = false'
assert_file_contains "$PCFG" 'status_line = ["model", "current-dir"]'
assert_file_contains "$PCFG" 'status_line_use_colors = false'
assert_file_contains "$PCFG" '[custom_section]'
assert_file_contains "$PCFG" 'flag = "survive"'
assert_file_contains "$PCFG" '# user-tail-marker=must-survive-provider-rewrite'
assert_file_contains "$PCFG" 'base_url = "http://127.0.0.1:'"$PORT"'/v1"'
assert_file_not_contains "$PCFG" "https://stale.invalid/v1"
assert_file_not_contains "$PCFG" "/stale/provider-api-key"
assert_file_not_contains "$PCFG" "sk-lab-fake"

"$PYTHON" - "$PCFG" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as fh:
    cfg = tomllib.load(fh)
if cfg.get("model") != "gpt-5.4":
    raise SystemExit("selected model was not updated")
if cfg.get("model_reasoning_effort") != "high":
    raise SystemExit("user reasoning effort was clobbered")
if cfg.get("model_auto_compact_token_limit") != 210000:
    raise SystemExit("user auto compact limit was clobbered")
features = cfg.get("features", {})
if features.get("auto_compaction") is not False:
    raise SystemExit("user auto_compaction override was clobbered")
for key in ("fast_mode", "goals"):
    if features.get(key) is not True:
        raise SystemExit(f"missing common feature {key}")
if features.get("hooks") is not False:
    raise SystemExit("hooks should be false unless user overrides it")
tui = cfg.get("tui", {})
if tui.get("status_line") != ["model", "current-dir"]:
    raise SystemExit("user status_line was clobbered")
if tui.get("status_line_use_colors") is not False:
    raise SystemExit("user status_line_use_colors was clobbered")
if cfg.get("custom_section", {}).get("flag") != "survive":
    raise SystemExit("unrelated user section was not preserved")
print("OK: config mode preserves user common config")
PY

printf 'OK: fake API config contract passed\n'
