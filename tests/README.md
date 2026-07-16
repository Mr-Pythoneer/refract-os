# Tests

Stub-based execution tests for the pure-logic scripts. They run BOTH locally
(`./tests/run.sh` under homebrew bash on macOS) and — more importantly — on a
real Ubuntu runner via `.github/workflows/tests.yml`. The CI run is the point:
some behaviour only shows up on the real target OS (GNU vs BSD coreutils), so
`test_creative_scratch.sh` asserts the exact `df -l --output` form the script
relies on actually works on GNU `df` — something a macOS dev box can't verify.

These complement (don't replace) `shellcheck.yml`, which only lints. Here the
scripts actually run.

## Running

```bash
./tests/run.sh                       # all test files, tallied
bash tests/test_modectl.sh           # one file
python3 tests/validate-compat-db.py  # compat-db schema check (standalone)
```

## What's covered

| File | Script under test | Notable regression guards |
|---|---|---|
| `test_modectl.sh` | `distro-modectl` | `--yes` forwarded across sudo re-exec; usage() pipe-separated |
| `test_gaming_compat.sh` | `distro-gaming-compat` | malformed DB entry hits the friendly guard, no traceback |
| `test_creative_scratch.sh` | `distro-creative-scratch` | **GNU `df -l --output` works** (the `df -lP` bug); NVMe pick; df-failure fallback |
| `test_ai_ask.sh` | `distro-ai-ask` | happy/empty/unreachable/malformed against a stub server |
| `test_cloud_toggle.sh` | `distro-ai-cloud-toggle` | refuses enable without a key; writes config with one |
| `test_detect_tier.sh` | `distro-ai-detect-tier` | VRAM→tier thresholds; multi-GPU homogeneous pooling; datacenter guard → Server mode; laptop profile + image opt-in |
| `test_ai_model.sh` | `distro-ai-model` | tier/VRAM-fit tag resolution; `min_vram_gb` warning; ollama pull/ps/load path; ComfyUI tags refused |
| `test_ai_setup.sh` | `distro-ai-setup` | guided vs `--install` order; image=none skip; datacenter exit-3 passthrough; hermetic (stubbed detect + setup) |
| `test_compat_db_schema.sh` | `validate-compat-db.py` | the validator rejects missing keys / bad status / etc. |

## Conventions

- Each `test_*.sh` sources `lib.sh`, sets up its own throwaway stub dir, and
  exits non-zero if any assertion fails.
- Tests are hermetic: they stub external commands (`sudo`, `df`, `lsblk`,
  `winetricks`, …) on a temp `PATH` and never touch real system state.
- Assertions that only matter on the target OS are guarded with `is_linux`
  and skipped (with a `note`) elsewhere — so the macOS run stays green while
  the CI run does the real check.
- `validate-compat-db.py` is standalone (also a CI step) so a malformed
  `compat-db/apps.json` fails with an obvious, clearly-named signal.

The GPU-/desktop-/build-host-dependent scripts (driver installs, llama.cpp
build, live-build, gsettings/GNOME) are intentionally NOT here — they need real
hardware or a live session and are covered by the
[first-hardware runbook](../docs/first-hardware-runbook.md) instead.
