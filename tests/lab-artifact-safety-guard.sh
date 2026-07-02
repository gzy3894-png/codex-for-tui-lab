#!/usr/bin/env sh
set -eu

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

if grep -R -n -E '/tmp/codex-tui-lab-[^[:space:]]*/\*\*/\*' .github/workflows >/tmp/codex-tui-lab-artifact-paths.txt 2>/dev/null; then
  cat /tmp/codex-tui-lab-artifact-paths.txt >&2
  fail "workflow artifact paths must not upload entire lab temp directories"
fi

if grep -R -n -F '.codex' .github/workflows >/tmp/codex-tui-lab-artifact-codex-paths.txt 2>/dev/null; then
  cat /tmp/codex-tui-lab-artifact-codex-paths.txt >&2
  fail "workflow artifacts must not upload .codex data"
fi

required='logs/**'
for workflow in .github/workflows/contracts.yml \
  .github/workflows/arm64-config-load.yml \
  .github/workflows/arm64-real-api-exec.yml \
  .github/workflows/real-api.yml \
  .github/workflows/android-emulator.yml
do
  grep -F -- "$required" "$workflow" >/dev/null 2>&1 ||
    fail "workflow does not upload logs-only artifacts: $workflow"
done

printf 'OK: artifact safety guard passed\n'
