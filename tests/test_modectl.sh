#!/usr/bin/env bash
# Tests for modes/modectl/distro-modectl (pure control-flow, no real services).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODECTL="$REPO_ROOT/modes/modectl/distro-modectl"

# status with no recorded mode -> "unknown", exit 0
out="$("$MODECTL" status 2>&1)"; rc=$?
assert_eq "status exits 0" "0" "$rc"
assert_contains "status reports unknown when no mode recorded" "$out" "unknown"

# usage (no args) -> pipe-separated mode list, exit 1
out="$("$MODECTL" 2>&1)"; rc=$?
assert_eq "no-args usage exits 1" "1" "$rc"
assert_contains "usage shows pipe-separated modes" "$out" "gaming|ai|server|creative|normal"

# --yes is forwarded across the sudo re-exec (regression test for the audit fix)
sd="$(new_stubdir)"
stub "$sd" id 'if [ "$1" = "-u" ]; then echo 1000; else exit 0; fi'
stub "$sd" sudo 'echo "REEXEC: $*"; exit 0'
out="$(PATH="$sd:$PATH" "$MODECTL" switch server --yes </dev/null 2>&1)"
assert_contains "switch --yes re-execs WITH --yes" "$out" "$MODECTL switch server --yes"
# the re-exec marker is preserved across sudo so the root pass skips per-user steps
assert_contains "re-exec preserves the _REFRACT_REEXEC marker" "$out" "preserve-env=_REFRACT_REEXEC"

# non-interactive switch WITHOUT --yes refuses to silently prompt
stub "$sd" id 'if [ "$1" = "-u" ]; then echo 1000; else exit 0; fi'
out="$(PATH="$sd:$PATH" "$MODECTL" switch server </dev/null 2>&1)"; rc=$?
assert_contains "non-interactive switch w/o --yes refuses" "$out" "Refusing to prompt"
rm -rf "$sd"

# REGRESSION (symlink blocker): invoked via a /usr/local/bin-style symlink,
# PROFILE_DIR must resolve to the REAL profiles dir, not the symlink's dir.
# `switch` reads the profile (before the sudo re-exec), so it exercises this;
# stub id (non-root) + sudo so it reaches the profile read without escalating.
symdir="$(new_stubdir)"
ln -s "$MODECTL" "$symdir/distro-modectl"
stub "$symdir" id 'if [ "$1" = "-u" ]; then echo 1000; else exit 0; fi'
stub "$symdir" sudo 'echo "REEXEC"; exit 0'
out="$(PATH="$symdir:$PATH" "$symdir/distro-modectl" switch gaming </dev/null 2>&1)"
assert_not_contains "switch via symlink resolves profiles (no 'No profile found')" "$out" "No profile found"
assert_contains "switch via symlink reads the gaming profile" "$out" "Gaming"
rm -rf "$symdir"

# --- switch ai auto-detects the hardware tier on first entry (idempotent) ---
# apply_ai_model runs BEFORE the sudo re-exec, so this is exercised as the
# non-root user. detect-tier is invoked SILENTLY (stdout is swallowed during a
# mode switch), so verify via side effects: an invocation log + the written tier
# file. First entry (no tier recorded) runs it; a later entry must NOT re-run it.
aid="$(new_stubdir)"; cfg="$aid/cfg"
stub "$aid" id 'if [ "$1" = "-u" ]; then echo 1000; else exit 0; fi'
stub "$aid" sudo 'echo "REEXEC"; exit 0'
stub "$aid" distro-ai-detect-tier 'mkdir -p "$XDG_CONFIG_HOME/refract-ai"; echo ran >> "$XDG_CONFIG_HOME/detect-ran.log"; echo ultra > "$XDG_CONFIG_HOME/refract-ai/tier"; exit 0'
stub "$aid" distro-ai-model 'echo "AIMODEL $*"; exit 0'
out="$(PATH="$aid:$PATH" HOME="$aid" XDG_CONFIG_HOME="$cfg" "$MODECTL" switch ai --yes </dev/null 2>&1)"
assert_contains "switch ai loads the use-case model" "$out" "AIMODEL use coding"
if [ -f "$cfg/refract-ai/tier" ]; then pass "switch ai auto-detected the tier (tier file written)"; else fail "switch ai did not auto-detect the tier"; fi
assert_eq "detect-tier ran once on first entry" "1" "$(wc -l < "$cfg/detect-ran.log" 2>/dev/null | tr -d ' ')"
# second entry: tier now recorded -> detect-tier NOT re-run, model still loads
out="$(PATH="$aid:$PATH" HOME="$aid" XDG_CONFIG_HOME="$cfg" "$MODECTL" switch ai --yes </dev/null 2>&1)"
assert_eq "detect-tier NOT re-run once tier recorded" "1" "$(wc -l < "$cfg/detect-ran.log" 2>/dev/null | tr -d ' ')"
assert_contains "switch ai still loads the model on later entries" "$out" "AIMODEL use coding"
rm -rf "$aid"

# --- apply_cpu_governor adapts to the CPU's available governors ---
# Regression guard for the Intel intel_pstate fix: that driver offers ONLY
# performance/powersave, so a profile requesting schedutil must MAP to powersave,
# not fail with a scary WARNING (the default Normal/AI modes request schedutil,
# and the first flash target is an Intel ThinkPad). We source the script with the
# dispatch guarded off and call the function directly, stubbing cpupower and
# pointing GOV_AVAIL_FILE at a fixture.
gsd="$(new_stubdir)"
stub "$gsd" cpupower 'echo "cpupower $*" >&2; exit 0'   # >&2: apply_cpu_governor calls cpupower >/dev/null
ips="$gsd/ips_governors"; printf 'performance powersave\n' > "$ips"
# shellcheck disable=SC1090  # $MODECTL is the script under test, resolved at runtime
gov_out() { ( export PATH="$gsd:$PATH" GOV_AVAIL_FILE="$1" DISTRO_MODECTL_SOURCE=1; . "$MODECTL"; apply_cpu_governor "$2" 2>&1 ); }
assert_contains "intel_pstate: schedutil -> powersave"     "$(gov_out "$ips" schedutil)"   "frequency-set -g powersave"
assert_contains "intel_pstate: ondemand -> powersave"      "$(gov_out "$ips" ondemand)"    "frequency-set -g powersave"
assert_contains "intel_pstate: performance stays"          "$(gov_out "$ips" performance)" "frequency-set -g performance"
assert_contains "intel_pstate: powersave stays"            "$(gov_out "$ips" powersave)"   "frequency-set -g powersave"
acpi="$gsd/acpi_governors"; printf 'conservative ondemand userspace powersave performance schedutil\n' > "$acpi"
assert_contains "acpi-cpufreq: schedutil used as-is"       "$(gov_out "$acpi" schedutil)"  "frequency-set -g schedutil"
assert_contains "no governors file: passes through"        "$(gov_out "$gsd/nope" schedutil)" "frequency-set -g schedutil"
rm -rf "$gsd"

# --- enabled-modes registry: load_valid_modes honors ENABLED_MODES_FILE ---
# Mirrors the GOV_AVAIL_FILE fixture pattern above. VALID_MODES is populated by
# load_valid_modes() before dispatch, so usage() (which joins VALID_MODES with
# '|') is a black-box window onto what the loader produced.
rsd="$(new_stubdir)"; emf="$rsd/enabled-modes"

# file present -> ONLY the listed modes are valid, with 'normal' force-appended
printf 'server\ncreative\n' > "$emf"
out="$(ENABLED_MODES_FILE="$emf" "$MODECTL" 2>&1)"; rc=$?
assert_eq "usage with a 2-mode registry exits 1" "1" "$rc"
assert_contains "registry present: usage advertises only enabled modes (+normal)" "$out" "<server|creative|normal>"
assert_not_contains "registry present: a disabled mode is not advertised" "$out" "gaming"

# file absent -> back-compat fallback to all five modes
out="$(ENABLED_MODES_FILE="$rsd/nonexistent" "$MODECTL" 2>&1)"
assert_contains "registry absent: falls back to all five modes" "$out" "<gaming|ai|server|creative|normal>"

# 'normal' is ALWAYS present, even when the file lists a single optional mode
printf 'gaming\n' > "$emf"
out="$(ENABLED_MODES_FILE="$emf" "$MODECTL" 2>&1)"
assert_contains "registry with one mode still force-appends 'normal'" "$out" "<gaming|normal>"

# present-but-all-junk -> provably-minimal 'normal' only (NOT a silent re-enable)
printf '# only comments\nbogusmode 12345\n' > "$emf"
out="$(ENABLED_MODES_FILE="$emf" "$MODECTL" 2>&1)"
assert_contains "registry of only junk -> 'normal' only" "$out" "<normal>"
rm -rf "$rsd"

# --- `modes enable` / `modes disable` mutate the registry (design §5) ---
# Fake root (id -u -> 0) so require_root_for does NOT re-exec and the file write
# lands here; point ENABLED_MODES_FILE at a fixture we own.
msd="$(new_stubdir)"
stub "$msd" id 'if [ "$1" = "-u" ]; then echo 0; else echo root; fi'
memf="$msd/enabled-modes"; printf 'gaming\n' > "$memf"

ENABLED_MODES_FILE="$memf" PATH="$msd:$PATH" "$MODECTL" modes enable server </dev/null >/dev/null 2>&1
reg="$(grep -v '^#' "$memf")"
assert_contains "modes enable server: 'server' added to registry" "$reg" "server"
assert_contains "modes enable server: pre-existing 'gaming' preserved" "$reg" "gaming"
assert_not_contains "registry never lists 'normal'" "$reg" "normal"

ENABLED_MODES_FILE="$memf" PATH="$msd:$PATH" "$MODECTL" modes disable gaming </dev/null >/dev/null 2>&1
reg="$(grep -v '^#' "$memf")"
assert_not_contains "modes disable gaming: 'gaming' removed" "$reg" "gaming"
assert_contains "modes disable gaming: 'server' preserved" "$reg" "server"

# 'normal' is rejected as an enable target (never selectable/deselectable)
out="$(ENABLED_MODES_FILE="$memf" PATH="$msd:$PATH" "$MODECTL" modes enable normal </dev/null 2>&1)"; rc=$?
assert_eq "modes enable normal is rejected (exit 1)" "1" "$rc"
assert_contains "modes enable normal explains it is the always-on base" "$out" "always-on"
rm -rf "$msd"

# --- switching to a KNOWN-but-disabled mode points at `modes enable` (design §5) ---
dsd="$(new_stubdir)"; demf="$dsd/enabled-modes"
printf 'gaming\n' > "$demf"   # 'ai' deliberately NOT enabled
out="$(ENABLED_MODES_FILE="$demf" "$MODECTL" switch ai </dev/null 2>&1)"; rc=$?
assert_eq "switch to a disabled mode exits 1" "1" "$rc"
assert_contains "switch to disabled 'ai' points at 'modes enable ai'" "$out" "modes enable ai"
assert_not_contains "disabled-mode rejection is not the bare usage line" "$out" "switch <"
rm -rf "$dsd"

finish
