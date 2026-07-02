# Codex for TUI Lab

Black-box CI lab for the Codex for TUI installer, config writer, updater, ARM64 binary config loading, and Android APK launch path.

This repository does not contain production keys. Push CI uses a fake OpenAI-compatible `/v1/models` server. Real relay/API testing is manual only and uses GitHub Actions secrets.

## Source Under Test

Default source repository:

```text
gzy3894-png/codex-cli-zh-binary-skill
```

Default source ref:

```text
android-arm64-musl-installer
```

Every workflow clones the source repository into `_source` and tests it as a consumer would. The lab does not vendor or silently copy the source scripts.

## Workflows

- `Codex for TUI Contracts`: automatic on push and manual. Runs shell contracts, fake API config checks, update rollback checks, and the source repo smoke tests.
- `Codex for TUI ARM64 Config Load`: automatic on push and manual. Runs on `ubuntu-24.04-arm`, downloads the ARM64 musl Codex binary, generates config, and verifies the real binary does not reject `model_catalog_json`.
- `Codex for TUI Android Emulator`: manual. Builds the APK and launches it in an Android emulator.
- `Codex for TUI Real API`: manual. Uses relay/API secrets only when explicitly triggered.

## Real API Secrets

Set these only after the fake/API-free lab is stable:

```text
KRILL_API_BASE
KRILL_API_KEY
KRILL_TEST_MODEL
```

The real API workflow must not run on push. It is intentionally `workflow_dispatch` only.

## Pass Criteria

A candidate source ref is not acceptable unless:

1. `config.toml` keeps `model` as one plain model id.
2. API keys are written to `auth.json`, not `config.toml`.
3. `model_catalog.json` parses as JSON and does not use invalid current-Codex enum values such as `web_search`.
4. `codex 更新` is atomic: if any file update fails, already installed scripts are not left half-updated.
5. The real ARM64 Codex binary does not fail with `failed to parse model_catalog_json`.
6. The APK builds and starts in the Android emulator.
