#!/usr/bin/env bash
# Tests for distro-apply-mode-selection — the Calamares helper that persists the
# "what is this machine for?" selection into /etc/refract/enabled-modes.
# ENABLED_MODES_FILE + DISTRO_ROOT are env-overridable (like GOV_AVAIL_FILE), so
# this runs hermetically against fixtures — no real /etc, no real /opt.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APPLY="$REPO_ROOT/modes/modectl/distro-apply-mode-selection"

# Run the helper with a fixture registry file; echo that file's contents.
run_apply() {  # run_apply "<selection arg>" [extra env...]
    local sel="$1"; shift
    local d; d="$(new_stubdir)"
    ( ENABLED_MODES_FILE="$d/enabled-modes" "$@" "$APPLY" "$sel" >/dev/null 2>&1 )
    cat "$d/enabled-modes" 2>/dev/null
    # GNU stat (Linux/CI, the authoritative env) FIRST, BSD stat (macOS) fallback.
    # Order matters: GNU `stat -f` means "filesystem status" and exits 0 with junk
    # rather than erroring, so a BSD-first `stat -f '%Lp' || stat -c '%a'` never
    # reaches the fallback on Linux and prints garbage — which is exactly how this
    # test passed on macOS but failed in CI.
    printf '\n__PERM__%s\n' "$(stat -c '%a' "$d/enabled-modes" 2>/dev/null || stat -f '%Lp' "$d/enabled-modes" 2>/dev/null)"
    rm -rf "$d"
}

# --- a normal multi-select writes exactly those modes, never 'normal' ---
out="$(run_apply "gaming,ai")"
assert_contains "selection writes gaming"        "$out" $'\ngaming'
assert_contains "selection writes ai"            "$out" $'\nai'
assert_not_contains "registry never lists normal" "$out" $'\nnormal'
assert_contains "registry is world-readable 0644" "$out" "__PERM__644"

# --- empty selection -> header-only file (resolves to normal-only) ---
out="$(run_apply "")"
assert_not_contains "empty selection writes no gaming"   "$out" $'\ngaming'
assert_not_contains "empty selection writes no ai"       "$out" $'\nai'
assert_contains     "empty selection still writes header" "$out" "enabled modes"

# --- un-expanded gs[] literal is treated as empty, not a bogus token ---
out="$(run_apply "gs[packagechooser_modes]")"
assert_not_contains "literal gs[] token is NOT persisted" "$out" "packagechooser"
assert_not_contains "literal gs[] yields no mode lines"   "$out" $'\ngaming'

# --- whitelist + dedupe: junk and 'normal' dropped, duplicates collapsed ---
out="$(run_apply "gaming,normal,bogus,ai,ai,gaming")"
assert_not_contains "unknown token 'bogus' dropped"       "$out" "bogus"
assert_not_contains "'normal' dropped from selection"     "$out" $'\nnormal'
assert_eq "gaming appears exactly once" "1" "$(printf '%s\n' "$out" | grep -cx gaming)"
assert_eq "ai appears exactly once"     "1" "$(printf '%s\n' "$out" | grep -cx ai)"

# --- HARD removal (opt-in): non-selected modes' files are deleted, selected kept ---
hd="$(new_stubdir)"
for m in gaming ai server creative; do mkdir -p "$hd/modes/$m"; done
mkdir -p "$hd/modes/modectl/profiles"; : > "$hd/modes/modectl/profiles/ai.conf"
ENABLED_MODES_FILE="$hd/enabled-modes" DISTRO_ROOT="$hd" APPLY_HARD_REMOVAL=1 \
    "$APPLY" "gaming" >/dev/null 2>&1
[ -d "$hd/modes/gaming" ] && pass "HARD: selected mode (gaming) kept" || fail "HARD: gaming was wrongly removed"
[ ! -d "$hd/modes/ai" ]   && pass "HARD: unselected mode (ai) removed" || fail "HARD: ai dir survived"
[ ! -e "$hd/modes/modectl/profiles/ai.conf" ] && pass "HARD: unselected profile removed" || fail "HARD: ai.conf survived"
rm -rf "$hd"

# --- HARD stays OFF by default: without the flag, nothing is deleted ---
sd="$(new_stubdir)"
for m in gaming ai; do mkdir -p "$sd/modes/$m"; done
ENABLED_MODES_FILE="$sd/enabled-modes" DISTRO_ROOT="$sd" "$APPLY" "gaming" >/dev/null 2>&1
[ -d "$sd/modes/ai" ] && pass "default (no flag) leaves unselected files in place" || fail "default run deleted files without APPLY_HARD_REMOVAL"
rm -rf "$sd"

finish
