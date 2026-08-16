#!/usr/bin/env bash
#
# mode-mechanism.sh — hardware-free MECHANISM proof for all 5 Refract OS modes.
#
# This runs the SHIPPED modes/modectl/distro-modectl (the exact script installed
# into the image) once per mode and asserts it issues EXACTLY the system-mutating
# commands each mode's contract promises — CPU governor, power profile, GPU
# perf-state, systemd services, GNOME theme/wallpaper/accent, AI-model load/unload,
# and the /run state file. It proves the CONTROL PLANE (what commands the switcher
# fires) without needing any of the hardware those commands drive.
#
# HOW it fakes the world without a GPU / Ollama / real init:
#   * Recording stubs for every external tool (gsettings, cpupower,
#     powerprofilesctl, nvidia-smi, systemctl, distro-ai-model,
#     distro-ai-detect-tier, ...) are put FIRST on PATH. Each stub appends its
#     name + args to /tmp/modelog/<tool>.log and exits 0.
#   * A `sudo` stub makes the sudo re-exec real but hermetic: it records the
#     call, then `exec env FAKE_ROOT=1 "$@"` — so `sudo distro-modectl switch
#     <mode> --yes` actually runs the ROOT pass in-process (governor/power/gpu/
#     services/state-file), and `sudo nvidia-smi ...` just runs the nvidia-smi
#     stub. No password, no privilege, no recursion explosion.
#   * An `id` stub prints 0 when FAKE_ROOT=1 and 1000 otherwise. The FIRST pass
#     therefore looks like uid 1000 (so apply_ai_model / apply_theme /
#     apply_pinned_apps actually run and hit their stubs), and the SECOND pass
#     (after sudo) looks like root, so require_root_for does NOT re-exec again
#     and the root-only steps run.
#   * DBUS_SESSION_BUS_ADDRESS is set to a dummy value and the mode wallpaper
#     files are created, so apply_theme/apply_pinned_apps proceed instead of
#     early-returning.
#
# The whole switch is run as uid 1000 via `setpriv --reuid 1000 --regid 1000
# --clear-groups` (mirroring install-smoke) so the id/sudo dance is realistic
# and the user-level steps are genuinely user-level.
#
# This is CI-oriented: it is meant to run inside the chroot of the mounted live
# squashfs (mode-test.yml sets that up). Exits non-zero if any mode misbehaves.

set -euo pipefail

# --- where the shipped switcher lives inside the image -----------------------
# In the chroot the distro tree is rsynced to /opt/distro (see build.sh) and
# symlinked into PATH. Prefer the symlink; fall back to the tree; finally to a
# repo-relative path so this also runs from a checkout during local dev.
if [ -x /usr/local/bin/distro-modectl ]; then
    MODECTL=/usr/local/bin/distro-modectl
elif [ -x /opt/distro/modes/modectl/distro-modectl ]; then
    MODECTL=/opt/distro/modes/modectl/distro-modectl
else
    SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    MODECTL="$SELF_DIR/../modes/modectl/distro-modectl"
fi
[ -x "$MODECTL" ] || { echo "FATAL: distro-modectl not found/executable (looked at /usr/local/bin, /opt/distro, repo)" >&2; exit 2; }
echo "Using switcher: $MODECTL"

STUB_DIR=/tmp/stubs
LOG_DIR=/tmp/modelog
WALL_DIR=/usr/share/backgrounds/refract
# apply_accent writes the per-mode GTK accent here. run_switch points the
# switcher at it via XDG_CONFIG_HOME so a test run can never touch a real
# user's ~/.config (user_config_dir honours XDG_CONFIG_HOME when not root).
CFG_DIR=/tmp/.config
STATE_FILE=/run/distro-modectl/current-mode

# --- the dock, as a real machine has one --------------------------------------
# DOCK_FILE holds favorite-apps between switches (the gsettings stub reads and
# writes it), so the five switches below act on ONE evolving dock instead of
# five independent blank ones. DOCK_DEFAULT is what the image ships and what
# `dconf reset` restores. DOCK_USER adds a pin of the user's own — code.desktop
# — because the bug being guarded here destroyed exactly that: pins the user
# added themselves, which no mode profile knows about and nothing can recreate.
DOCK_FILE=/tmp/dock-favorites
DOCK_DEFAULT="google-chrome.desktop org.gnome.Nautilus.desktop org.gnome.Terminal.desktop org.gnome.Settings.desktop org.gnome.Software.desktop"
DOCK_USER="$DOCK_DEFAULT code.desktop"
# The .desktop files that "exist" on this machine. apply_pinned_apps refuses to
# pin a launcher it cannot find, so this fixture decides which of each profile's
# PINNED_APPS are pinnable. Deliberately PARTIAL: steam and lutris are here but
# bottles is not, and Blender is here but FreeCAD and Kdenlive are not — which is
# the realistic case, since none of those six ship in any Refract image and only
# arrive when someone runs a mode's setup scripts.
APPS_DIR=/tmp/fixture-applications

FAILS=0
ok()   { echo "ok   $1: $2"; }
bad()  { echo "FAIL $1: $2"; FAILS=$((FAILS+1)); }

# assert that a per-tool log CONTAINS a substring (fixed-string match)
log_has() {  # log_has <mode> <tool> <needle> <human-desc>
    local mode="$1" tool="$2" needle="$3" desc="$4" f="$LOG_DIR/$2.log"
    if [ -f "$f" ] && grep -qF -- "$needle" "$f"; then ok "$mode" "$desc"
    else bad "$mode" "$desc (want [$needle] in $tool.log)"; fi
}
# assert that a per-tool log does NOT contain a substring (absence proof)
log_lacks() {  # log_lacks <mode> <tool> <needle> <human-desc>
    local mode="$1" tool="$2" needle="$3" desc="$4" f="$LOG_DIR/$2.log"
    if [ -f "$f" ] && grep -qF -- "$needle" "$f"; then bad "$mode" "$desc (unwanted [$needle] in $tool.log)"
    else ok "$mode" "$desc"; fi
}
# assert a tool was never invoked at all (no log, or empty)
tool_silent() {  # tool_silent <mode> <tool> <human-desc>
    local mode="$1" tool="$2" desc="$3" f="$LOG_DIR/$2.log"
    if [ -s "$f" ]; then bad "$mode" "$desc ($tool.log non-empty: $(tr '\n' ';' < "$f"))"
    else ok "$mode" "$desc"; fi
}

# --- (re)build the recording stubs on a clean PATH ---------------------------
make_stubs() {
    rm -rf "$STUB_DIR"; mkdir -p "$STUB_DIR"
    # Generic recorder: append "toolname arg1 arg2 ..." to its own log, exit 0.
    local rec
    for rec in cpupower powerprofilesctl \
               distro-ai-model distro-ai-detect-tier \
               gtk-update-icon-cache nvidia-settings gnome-extensions; do
        {
            printf '#!/usr/bin/env bash\n'
            printf 'echo "%s $*" >> "%s/%s.log"\n' "$rec" "$LOG_DIR" "$rec"
            printf 'exit 0\n'
        } > "$STUB_DIR/$rec"
        chmod +x "$STUB_DIR/$rec"
    done

    # gsettings needs STATE, not just recording. apply_pinned_apps no longer
    # blind-writes the dock: it READS favorite-apps, subtracts the previous
    # mode's overlay and writes base+wanted back. A stub that records and prints
    # nothing makes every read return an empty dock, so the very thing this is
    # meant to prove — that a user's own pins SURVIVE a mode switch — could not
    # be observed. This stub keeps the list in a file across all five switches,
    # exactly like dconf does on a real machine. Everything that is not
    # favorite-apps still just records and exits 0, so the wallpaper/theme/accent
    # assertions are untouched.
    # Written with an UNQUOTED heredoc: the paths below interpolate now, and
    # everything the stub must evaluate at RUN time is escaped as \$.
    cat > "$STUB_DIR/gsettings" <<STUB
#!/usr/bin/env bash
echo "gsettings \$*" >> "$LOG_DIR/gsettings.log"
if [ "\${2:-}" = "org.gnome.shell" ] && [ "\${3:-}" = "favorite-apps" ]; then
    if [ "\$1" = "get" ]; then
        read -r -a a < "$DOCK_FILE" 2>/dev/null || a=()
        if [ \${#a[@]} -eq 0 ]; then echo "@as []"
        else j=\$(printf "'%s', " "\${a[@]}"); echo "[\${j%, }]"; fi
        exit 0
    fi
    if [ "\$1" = "set" ]; then
        printf '%s\n' "\$4" | tr -d "[]'\\"" | sed 's/@as//' | tr ',' ' ' | xargs > "$DOCK_FILE"
        exit 0
    fi
fi
exit 0
STUB
    chmod +x "$STUB_DIR/gsettings"

    # dconf: record, and make `dconf reset .../favorite-apps` restore the image
    # default, which is what the real dconf does when the user value is cleared.
    cat > "$STUB_DIR/dconf" <<STUB
#!/usr/bin/env bash
echo "dconf \$*" >> "$LOG_DIR/dconf.log"
if [ "\${1:-}" = "reset" ] && [ "\${2:-}" = "/org/gnome/shell/favorite-apps" ]; then
    echo "$DOCK_DEFAULT" > "$DOCK_FILE"
fi
exit 0
STUB
    chmod +x "$STUB_DIR/dconf"

    # systemctl needs special handling: apply_services only issues `enable --now
    # <svc>` when `systemctl list-unit-files "<svc>*"` reports the unit installed
    # (grep -q "^<svc>"). So the stub must (a) record every call and (b) echo a
    # matching "<svc>.service" line for a list-unit-files query — otherwise every
    # enable would be skipped with a NOTE and the contract couldn't be proven.
    {
        printf '#!/usr/bin/env bash\n'
        printf 'echo "systemctl $*" >> "%s/systemctl.log"\n' "$LOG_DIR"
        # shellcheck disable=SC2016  # $1/$2 stay literal in the generated stub
        printf 'if [ "$1" = "list-unit-files" ]; then\n'
        # shellcheck disable=SC2016
        printf '  unit="${2%%\\*}"\n'          # strip the trailing glob "*"
        # shellcheck disable=SC2016
        printf '  echo "${unit}.service enabled enabled"\n'
        printf 'fi\n'
        printf 'exit 0\n'
    } > "$STUB_DIR/systemctl"
    chmod +x "$STUB_DIR/systemctl"

    # nvidia-smi needs to look like a real GPU is present AND feed a parseable
    # max clock to the -q -d SUPPORTED_CLOCKS awk ('/Graphics/{print $3; exit}').
    {
        printf '#!/usr/bin/env bash\n'
        printf 'echo "nvidia-smi $*" >> "%s/nvidia-smi.log"\n' "$LOG_DIR"
        # shellcheck disable=SC2016  # $1 must stay literal in the generated stub
        printf 'if [ "$1" = "-q" ]; then\n'
        printf '  echo "    Supported Clocks"\n'
        printf '  echo "        Graphics                          : 2100 MHz"\n'
        printf '  echo "        Memory                            : 9501 MHz"\n'
        printf 'fi\n'
        printf 'exit 0\n'
    } > "$STUB_DIR/nvidia-smi"
    chmod +x "$STUB_DIR/nvidia-smi"

    # sudo: record, then re-exec the SAME command with FAKE_ROOT=1 so the id
    # stub reports root. Handles both `sudo distro-modectl switch ...` (the
    # re-exec) and `sudo nvidia-smi ...` (the GPU calls) transparently.
    {
        printf '#!/usr/bin/env bash\n'
        printf 'echo "sudo $*" >> "%s/sudo.log"\n' "$LOG_DIR"
        printf 'exec env FAKE_ROOT=1 "$@"\n'
    } > "$STUB_DIR/sudo"
    chmod +x "$STUB_DIR/sudo"

    # id: root (0) only under FAKE_ROOT, else the invoking uid (1000). Everything
    # that isn't `id -u` falls through to the real id.
    {
        printf '#!/usr/bin/env bash\n'
        # shellcheck disable=SC2016  # $1/$FAKE_ROOT must stay literal in the stub
        printf 'if [ "${1:-}" = "-u" ]; then\n'
        # shellcheck disable=SC2016
        printf '  if [ "${FAKE_ROOT:-}" = "1" ]; then echo 0; else echo 1000; fi\n'
        printf '  exit 0\n'
        printf 'fi\n'
        # shellcheck disable=SC2016
        printf 'exec /usr/bin/id "$@"\n'
    } > "$STUB_DIR/id"
    chmod +x "$STUB_DIR/id"
}

# --- run one mode switch under the stubbed world -----------------------------
run_switch() {  # run_switch <mode>
    local mode="$1"
    make_stubs
    rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
    # State dir: /run/distro-modectl is root-owned; the CI pre-creates it owned by
    # uid 1000 before this (root-only) step. As uid 1000 we just clear any stale
    # file. Guard everything so a read-only/again-owned dir can't abort the run.
    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
    rm -f "$STATE_FILE" 2>/dev/null || true
    # Wallpaper files must exist so apply_theme's `[ -f "$WALLPAPER" ]` passes. In
    # the real image they already ship under $WALL_DIR (root-owned, readable); only
    # create a placeholder if one is genuinely missing AND we can write it.
    rm -f "$CFG_DIR"/gtk-4.0/gtk.css "$CFG_DIR"/gtk-3.0/gtk.css 2>/dev/null || true
    mkdir -p "$WALL_DIR" 2>/dev/null || true
    [ -f "$WALL_DIR/$mode.png" ] || : > "$WALL_DIR/$mode.png" 2>/dev/null || true

    echo "=================================================================="
    echo ">>> switch $mode"
    # First on PATH: the stubs. DBUS set so gsettings paths run. DISPLAY unset
    # so we assert the headless GPU/nvidia-settings behaviour (nvidia-smi still
    # fires; nvidia-settings does not — matches the contract's DISPLAY guard).
    # HOME=/tmp so the AI tier-file path is writable.
    PATH="$STUB_DIR:$PATH" \
    HOME=/tmp \
    XDG_CONFIG_HOME="$CFG_DIR" \
    REFRACT_DESKTOP_DIRS="$APPS_DIR" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/tmp/fake-bus" \
    DISPLAY='' \
        "$MODECTL" switch "$mode" --yes </dev/null 2>&1 | sed 's/^/    | /' || {
            echo "    (switcher exited non-zero for $mode)"; bad "$mode" "switcher exited 0"; return 0; }
    ok "$mode" "switcher exited 0"
}

# --- per-mode contract assertions -------------------------------------------
# Shared invariants every mode must satisfy, plus the mode-specific ones.

assert_common() {  # assert_common <mode> <gov> <power> <accent-hex> <gpu:max|auto>
    # $4 (accent) is LIVE again. It was dead while every mode rendered identical
    # WhiteSur chrome; apply_accent now writes the mode's ray colour into the GTK
    # accent overrides, so the switch is visible in the UI and not just the
    # wallpaper. Asserting it here is what stops that silently regressing.
    local mode="$1" gov="$2" power="$3" accent="$4" gpu="$5"
    local wall="$WALL_DIR/$mode.png"

    # CPU governor + power profile (root pass).
    log_has "$mode" cpupower "frequency-set -g $gov" "cpupower set governor '$gov'"
    log_has "$mode" powerprofilesctl "set $power" "powerprofilesctl set '$power'"

    # GPU perf-state.
    if [ "$gpu" = "max" ]; then
        log_has "$mode" nvidia-smi "-pm 1" "nvidia-smi persistence mode on (GPU_PERF=max)"
        log_has "$mode" nvidia-smi "-q -d SUPPORTED_CLOCKS" "nvidia-smi queried supported clocks"
        log_has "$mode" nvidia-smi "-lgc 2100,2100" "nvidia-smi locked graphics clock to parsed max"
        log_lacks "$mode" nvidia-smi "-rgc" "GPU NOT reset (no -rgc when max)"
    else
        log_has "$mode" nvidia-smi "-rgc" "nvidia-smi reset graphics clocks (GPU_PERF=auto)"
        log_has "$mode" nvidia-smi "-rmc" "nvidia-smi reset memory clocks (GPU_PERF=auto)"
        log_lacks "$mode" nvidia-smi "-pm 1" "GPU NOT pinned (no -pm 1 when auto)"
        log_lacks "$mode" nvidia-smi "-lgc" "GPU NOT clock-locked (no -lgc when auto)"
    fi
    # DISPLAY is empty in this harness, so GpuPowerMizerMode must NOT be touched.
    tool_silent "$mode" nvidia-settings "nvidia-settings NOT called (no X DISPLAY)"

    # Theme: wallpaper -> the mode's png, dark scheme, and the CONSISTENT macOS
    # (WhiteSur) GTK/icon/shell theme across EVERY mode — a switch must NOT revert
    # the desktop to Ubuntu's Yaru.
    log_has "$mode" gsettings "picture-uri file://$wall" "wallpaper picture-uri -> $mode.png"
    log_has "$mode" gsettings "picture-uri-dark file://$wall" "wallpaper picture-uri-dark -> $mode.png"
    log_has "$mode" gsettings "picture-options zoom" "wallpaper picture-options 'zoom'"
    log_has "$mode" gsettings "color-scheme prefer-dark" "color-scheme 'prefer-dark'"
    log_has "$mode" gsettings "gtk-theme WhiteSur-Dark" "gtk-theme 'WhiteSur-Dark' (macOS look kept)"
    log_has "$mode" gsettings "icon-theme WhiteSur-dark" "icon-theme 'WhiteSur-dark'"
    log_has "$mode" gsettings "name WhiteSur-Dark" "shell user-theme 'WhiteSur-Dark'"
    log_lacks "$mode" gsettings "gtk-theme Yaru" "does NOT revert to Yaru"

    # Per-mode accent must land in BOTH GTK generations, carrying this mode's
    # colour and the generated-file marker that protects a user-authored gtk.css.
    local gen
    for gen in gtk-4.0 gtk-3.0; do
        if [ -f "$CFG_DIR/$gen/gtk.css" ] && grep -qF -- "$accent" "$CFG_DIR/$gen/gtk.css"; then
            ok "$mode" "$gen accent -> $accent"
        else
            bad "$mode" "$gen accent -> $accent (want it in $CFG_DIR/$gen/gtk.css)"
        fi
    done
    if [ -f "$CFG_DIR/gtk-4.0/gtk.css" ] && head -n1 "$CFG_DIR/gtk-4.0/gtk.css" | grep -qF "generated by distro-modectl"; then
        ok "$mode" "accent stylesheet carries the generated-by marker"
    else
        bad "$mode" "accent stylesheet missing the generated-by marker (user gtk.css would be clobbered)"
    fi

    # Liquid glass (frosted blur): Normal ENABLES blur-my-shell; every other mode
    # DISABLES it, since real-time blur is GPU-heavy and gaming/ai/creative need
    # every cycle. This is the whole point of scoping glass to Normal.
    if [ "$mode" = normal ]; then
        log_has  "$mode" gnome-extensions "enable blur-my-shell@aunetx"  "liquid glass ENABLED (Normal)"
        log_lacks "$mode" gnome-extensions "disable blur-my-shell@aunetx" "glass not disabled in Normal"
    else
        log_has  "$mode" gnome-extensions "disable blur-my-shell@aunetx" "liquid glass DISABLED ($mode)"
        log_lacks "$mode" gnome-extensions "enable blur-my-shell@aunetx"  "glass not enabled in $mode"
    fi

    # State file records the mode.
    if [ -f "$STATE_FILE" ] && [ "$(cat "$STATE_FILE")" = "$mode" ]; then
        ok "$mode" "state file /run/distro-modectl/current-mode == '$mode'"
    else
        bad "$mode" "state file == '$mode' (got '$(cat "$STATE_FILE" 2>/dev/null || echo MISSING)')"
    fi

    # sudo re-exec actually happened, carrying --yes across.
    log_has "$mode" sudo "switch $mode --yes" "sudo re-exec forwarded 'switch $mode --yes'"
}

# THE DOCK CONTRACT, rewritten. The old assertions here codified the bug:
# assert_pinned checked that the dock had been REPLACED by the mode's three apps,
# and assert_no_pin checked that a mode with no pins left the dock alone. Together
# they described a switcher that destroys the user's dock on entering Gaming and
# never gives it back — which is what a real install did, and what got reported:
# "when changing modes, it unpins all the pinned apps".
#
# What must hold instead: after ANY switch the dock is the user's own list plus
# this mode's installed pins, in that order, and nothing else.
assert_dock() {  # assert_dock <mode> <expected full dock, space-separated>
    local mode="$1" want="$2" got
    got="$(cat "$DOCK_FILE" 2>/dev/null || echo MISSING)"
    if [ "$got" = "$want" ]; then ok "$mode" "dock == [$want]"
    else bad "$mode" "dock == [$want] (got [$got])"; fi
}

# The user's own pins are the point. Asserted separately from the whole-dock
# comparison so a failure says WHICH half broke.
assert_user_pins_survive() {  # assert_user_pins_survive <mode>
    local mode="$1" missing="" a
    for a in $DOCK_USER; do
        grep -qwF -- "$a" "$DOCK_FILE" 2>/dev/null || missing="$missing $a"
    done
    if [ -z "$missing" ]; then ok "$mode" "every pin the user had is still in the dock"
    else bad "$mode" "user pins survive the switch (lost:$missing)"; fi
}

# A launcher that isn't installed must never be pinned: gnome-shell drops it
# silently, so pinning one costs a dock slot and shows nothing.
assert_not_pinned() {  # assert_not_pinned <mode> <app...>
    local mode="$1"; shift
    local a bad_=""
    for a in "$@"; do grep -qwF -- "$a" "$DOCK_FILE" 2>/dev/null && bad_="$bad_ $a"; done
    if [ -z "$bad_" ]; then ok "$mode" "uninstalled launchers not pinned ($*)"
    else bad "$mode" "uninstalled launchers must not be pinned (found:$bad_)"; fi
}

assert_no_services() {  # assert_no_services <mode>
    tool_silent "$1" systemctl "no systemctl enable/disable (empty service arrays)"
}

# ============================ RUN ALL 5 MODES ================================

# The dock and the installed-applications fixture are set up ONCE, before the
# first switch, and deliberately NOT reset between modes: the property under
# test is what five consecutive switches do to one dock over time, which is
# exactly what a person does to their machine and exactly what nothing checked.
rm -rf "$APPS_DIR"; mkdir -p "$APPS_DIR"
for a in $DOCK_USER steam.desktop net.lutris.Lutris.desktop org.blender.Blender.desktop; do
    : > "$APPS_DIR/$a"
done
echo "$DOCK_USER" > "$DOCK_FILE"
rm -f "$CFG_DIR/refract/dock-managed"

# ---- gaming: performance/performance, GPU max, red, dock pins, unload AI ----
run_switch gaming
assert_common gaming performance performance "#ff5a52" max
assert_dock gaming "$DOCK_USER steam.desktop net.lutris.Lutris.desktop"
assert_user_pins_survive gaming
assert_not_pinned gaming com.usebottles.bottles.desktop
assert_no_services gaming
log_has  gaming distro-ai-model "unload" "distro-ai-model unload (STOP_AI_MODEL=true)"
log_lacks gaming distro-ai-model "use" "distro-ai-model 'use' NOT called (no autostart use-case)"
tool_silent gaming distro-ai-detect-tier "tier auto-detect NOT run (not AI mode)"

# ---- ai: schedutil/balanced, GPU auto, blue, NO pins, load 'coding' --------
run_switch ai
assert_common ai schedutil balanced "#4a9df0" auto
# THE REGRESSION. AI has an empty PINNED_APPS, and the old code returned early
# on empty — so Gaming's three replacements stayed forever and the dock never
# came back. Leaving a mode must REMOVE that mode's overlay and nothing else.
assert_dock ai "$DOCK_USER"
assert_user_pins_survive ai
assert_not_pinned ai steam.desktop net.lutris.Lutris.desktop
assert_no_services ai
log_has  ai distro-ai-model "use coding" "distro-ai-model use coding (AI_AUTOSTART_USECASE)"
log_lacks ai distro-ai-model "unload" "distro-ai-model unload NOT called (STOP_AI_MODEL=false)"
log_has  ai distro-ai-detect-tier "--yes" "distro-ai-detect-tier --yes on first AI entry (no tier file)"

# ---- server: powersave/power-saver, GPU auto, viridian, services, unload ---
run_switch server
assert_common server powersave power-saver "#7bc043" auto
assert_dock server "$DOCK_USER"
assert_user_pins_survive server
log_has server systemctl "enable --now ssh" "systemctl enable --now ssh"
log_has server systemctl "enable --now docker" "systemctl enable --now docker"
log_has server systemctl "enable --now netdata" "systemctl enable --now netdata"
# Display managers get a DEFERRED disable (plain `disable`, NOT --now) so the
# ACTIVE graphical session survives; the effect lands next boot.
log_has server systemctl "disable gdm" "systemctl disable gdm (deferred, no --now)"
log_lacks server systemctl "disable --now gdm" "gdm disable is deferred — no --now (keeps the live session)"
log_has  server distro-ai-model "unload" "distro-ai-model unload (STOP_AI_MODEL=true)"
log_lacks server distro-ai-model "use" "distro-ai-model 'use' NOT called (no autostart use-case)"

# ---- creative: performance/performance, GPU max, magenta, dock pins, unload -
run_switch creative
assert_common creative performance performance "#e857a0" max
assert_dock creative "$DOCK_USER org.blender.Blender.desktop"
assert_user_pins_survive creative
assert_not_pinned creative org.freecad.FreeCAD.desktop org.kde.kdenlive.desktop
assert_no_services creative
log_has  creative distro-ai-model "unload" "distro-ai-model unload (STOP_AI_MODEL=true)"
log_lacks creative distro-ai-model "use" "distro-ai-model 'use' NOT called (no autostart use-case)"

# ---- normal: schedutil/balanced, GPU auto, NO accent, NO pins, unload ------
run_switch normal
assert_common normal schedutil balanced "#ffa23d" auto
assert_dock normal "$DOCK_USER"
assert_user_pins_survive normal
assert_not_pinned normal org.blender.Blender.desktop
assert_no_services normal
log_has  normal distro-ai-model "unload" "distro-ai-model unload (STOP_AI_MODEL=true)"
log_lacks normal distro-ai-model "use" "distro-ai-model 'use' NOT called (no autostart use-case)"
tool_silent normal distro-ai-detect-tier "tier auto-detect NOT run (no autostart use-case)"

echo "=================================================================="
if [ "$FAILS" -eq 0 ]; then
    echo "MODE-MECHANISM: ALL modes issued exactly their contracted commands."
    exit 0
else
    echo "MODE-MECHANISM: $FAILS assertion(s) FAILED."
    exit 1
fi
