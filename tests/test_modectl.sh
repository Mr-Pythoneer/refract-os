#!/usr/bin/env bash
# Tests for modes/modectl/distro-modectl (pure control-flow, no real services).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODECTL="$REPO_ROOT/modes/modectl/distro-modectl"

# status reads STATE_FILE, which is overridable (like GOV_AVAIL_FILE /
# ENABLED_MODES_FILE) so this asserts against a fixture instead of the runner's
# real /run/distro-modectl/current-mode — a box that HAS switched modes would
# otherwise fail the "unknown" case. Needle is anchored to "Current mode: " for
# the same reason: a bare "unknown" also matches the "Power profile: unknown"
# line this command prints when powerprofilesctl is installed.
ssd="$(new_stubdir)"
out="$(STATE_FILE="$ssd/current-mode" "$MODECTL" status 2>&1)"; rc=$?
assert_eq "status exits 0" "0" "$rc"
assert_contains "status reports unknown when no mode recorded" "$out" "Current mode: unknown"
# ...and the recorded mode when there IS one (proves STATE_FILE is really read)
echo gaming > "$ssd/current-mode"
out="$(STATE_FILE="$ssd/current-mode" "$MODECTL" status 2>&1)"
assert_contains "status reports the recorded mode" "$out" "Current mode: gaming"
rm -rf "$ssd"

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

# --- ... and the same under the DOCUMENTED `sudo distro-modectl switch ai` ---
# REGRESSION (audit): the tier guard must be evaluated in the desktop user's
# context — the one run_as_user actually runs detect-tier in — not the invoking
# process's. sudo's env_reset makes HOME=/root, so a guard reading $HOME tested
# /root/.config/refract-ai/tier: a path nothing ever creates, so it was ALWAYS
# true and detect-tier (--yes => it WRITES) re-ran on every ai switch, silently
# overwriting a forced --tier and the user's image choice. Simulated here as
# root (id -u -> 0) + SUDO_USER=tester + HOME=/root, with a sudo stub that
# reproduces env_reset for run_as_user: XDG_CONFIG_HOME dropped, HOME set to the
# target user's home. The system-side tools are stubbed and STATE_FILE points at
# a fixture, so this fake-root pass touches nothing real.
sad="$(new_stubdir)"; suhome="$sad/home"; mkdir -p "$suhome/.config"
stub "$sad" id 'case "${1:-}" in -u) if [ $# -eq 1 ]; then echo 0; else echo 1000; fi ;; *) echo tester ;; esac'
stub "$sad" getent '[ "${1:-}" = passwd ] && echo "tester:x:1000:1000::$TEST_UHOME:/bin/bash"; exit 0'
stub "$sad" sudo 'while [ $# -gt 0 ]; do case "$1" in -u) shift 2 ;; *=*) shift ;; *) break ;; esac; done
unset XDG_CONFIG_HOME        # sudo env_reset drops it ...
export HOME="$TEST_UHOME"    # ... and points HOME at the target user
exec "$@"'
stub "$sad" distro-ai-detect-tier 'c="${XDG_CONFIG_HOME:-$HOME/.config}"; mkdir -p "$c/refract-ai"; echo ran >> "$c/detect-ran.log"; echo ultra > "$c/refract-ai/tier"; exit 0'
stub "$sad" distro-ai-model 'echo "AIMODEL $*"; exit 0'
for c in cpupower powerprofilesctl gsettings systemctl; do stub "$sad" "$c" 'exit 0'; done
sudo_switch_ai() {
    PATH="$sad:$PATH" HOME=/root SUDO_USER=tester TEST_UHOME="$suhome" \
        STATE_FILE="$sad/current-mode" "$MODECTL" switch ai --yes </dev/null 2>&1
}
ranlog="$suhome/.config/detect-ran.log"
out="$(sudo_switch_ai)"
assert_contains "sudo switch ai loads the use-case model" "$out" "AIMODEL use coding"
assert_eq "sudo switch ai: detect-tier ran once on first entry" "1" "$(wc -l < "$ranlog" 2>/dev/null | tr -d ' ')"
assert_eq "sudo switch ai: tier written to the DESKTOP user's config" "ultra" "$(cat "$suhome/.config/refract-ai/tier" 2>/dev/null)"
# Second entry: the desktop user's tier now exists, so the guard must see it.
# Reading /root/.config here (this process's $HOME) would re-run detect-tier.
out="$(sudo_switch_ai)"
assert_eq "sudo switch ai: detect-tier NOT re-run once the desktop user's tier exists" "1" "$(wc -l < "$ranlog" 2>/dev/null | tr -d ' ')"
assert_contains "sudo switch ai still loads the model on later entries" "$out" "AIMODEL use coding"
rm -rf "$sad"

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

# --- `modes` on a mode-omitted / hard-removed install (two audit findings) ---
# Both need a build whose catalog and profiles/ differ from the repo's, so they
# share one fixture: a COPY of the script laid out the way it ships (a
# distro-modectl next to its own profiles/ dir, which is what PROFILE_DIR reads),
# with ALL_MODES=(...) rewritten exactly as iso/build.sh rewrites it for a
# REFRACT_OMIT_MODES build.
#   1. The `modes` error strings must be DERIVED from ALL_MODES — a hardcoded
#      "gaming ai server creative" made an ai-omitted build advertise 'ai'.
#   2. `modes enable` must refuse a mode whose profile is absent: an
#      APPLY_HARD_REMOVAL install (distro-apply-mode-selection) deletes
#      profiles/<mode>.conf but leaves ALL_MODES alone, so enable reported
#      success for a mode `switch` can never resolve.
osd="$(new_stubdir)"
cp "$MODECTL" "$osd/distro-modectl"; chmod +x "$osd/distro-modectl"; mkdir -p "$osd/profiles"
# -i.bak: the one spelling BSD sed (dev box) and GNU sed (CI) both accept.
sed -i.bak 's/^ALL_MODES=(.*/ALL_MODES=(gaming server normal)/' "$osd/distro-modectl"
cp "$REPO_ROOT/modes/modectl/profiles/gaming.conf" "$osd/profiles/"   # 'server' profile deliberately absent
oemf="$osd/enabled-modes"; printf 'gaming\n' > "$oemf"

out="$(ENABLED_MODES_FILE="$oemf" "$osd/distro-modectl" modes enable ai </dev/null 2>&1)"; rc=$?
assert_eq "omitted build: 'modes enable ai' exits 1" "1" "$rc"
assert_contains "omitted build: optional-mode list is derived from ALL_MODES" "$out" "Optional modes are: gaming server."
assert_not_contains "omitted build: an omitted mode is never advertised" "$out" "creative"
out="$(ENABLED_MODES_FILE="$oemf" "$osd/distro-modectl" modes enable </dev/null 2>&1)"
assert_contains "omitted build: enable usage lists only the modes it ships" "$out" "modes enable <gaming|server>"

# Profile gone (APPLY_HARD_REMOVAL): refuse rather than record an unswitchable
# mode. Runs unprivileged on purpose — the check must precede require_root_for.
out="$(ENABLED_MODES_FILE="$oemf" "$osd/distro-modectl" modes enable server </dev/null 2>&1)"; rc=$?
assert_eq "profile missing: 'modes enable server' exits 1" "1" "$rc"
assert_contains "profile missing: enable says the profile is gone" "$out" "profile is missing"
assert_not_contains "profile missing: registry is left untouched" "$(cat "$oemf")" "server"
rm -rf "$osd"

# --- switching to a KNOWN-but-disabled mode points at `modes enable` (design §5) ---
dsd="$(new_stubdir)"; demf="$dsd/enabled-modes"
printf 'gaming\n' > "$demf"   # 'ai' deliberately NOT enabled
out="$(ENABLED_MODES_FILE="$demf" "$MODECTL" switch ai </dev/null 2>&1)"; rc=$?
assert_eq "switch to a disabled mode exits 1" "1" "$rc"
assert_contains "switch to disabled 'ai' points at 'modes enable ai'" "$out" "modes enable ai"
assert_not_contains "disabled-mode rejection is not the bare usage line" "$out" "switch <"
rm -rf "$dsd"

finish
