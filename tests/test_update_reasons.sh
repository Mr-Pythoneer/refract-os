#!/usr/bin/env bash
#
# A failing update check must say WHICH thing failed.
#
# The bug this locks out: every distinct failure in the chain — DNS, a blocked
# asset CDN, a half-published release, a captive portal, an invalid signature,
# an exhausted API rate limit — printed the single sentence "Could not reach
# GitHub to check for updates". That sentence names the one cause the user can
# do nothing about, and for most of those failures it is simply false. A machine
# rejecting a bad signature would report a network problem forever, and nobody
# would ever look at the signature.
#
# So the assertions here are deliberately about WORDING, because the wording IS
# the feature. Each branch must be distinguishable from the others by reading it.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

sb="$(new_stubdir)"
trap 'rm -rf "$sb"' EXIT

# Source the REAL functions rather than re-implementing them. (The signing test
# learned this the hard way: its first version carved them out with sed and
# verified nothing.)
export DISTRO_UPDATE_SOURCE=1
export REFRACT_PUBKEY="$sb/pub"
export REFRACT_LAYER_BASE="file://$sb/rel"
mkdir -p "$sb/rel"

# shellcheck disable=SC1090
. "$REPO_ROOT/modes/update/distro-update"

reason_for() {  # reason_for  -> runs fetch_verified_manifest, prints the reason
    local w; w="$(mktemp -d)"
    fetch_verified_manifest "$w" >/dev/null 2>&1
    rm -rf "$w"
    last_why
}

# --- 1. the manifest itself is unreachable ----------------------------------
# The most common real-world shape of this is a network that permits github.com
# and blocks the release CDN, which is invisible unless the message says so.
out="$(reason_for)"
assert_contains "an unreachable manifest is not blamed on 'GitHub' generally" \
    "$out" "objects.githubusercontent.com"

# --- 2. manifest present, signature missing ---------------------------------
printf 'refract-layer-manifest v1\ncommit %040d\n' 1 > "$sb/rel/refract-layer.manifest"
out="$(reason_for)"
assert_contains "a missing signature is reported as a half-published release" \
    "$out" "half-published"

# --- 3. both present but the signature does not verify ----------------------
# This is a SECURITY event, and the one message that must never mention the
# network — "check your connection" would send somebody to reboot a router.
if command -v openssl >/dev/null 2>&1; then
    openssl genpkey -algorithm ed25519 -out "$sb/k1" 2>/dev/null
    openssl genpkey -algorithm ed25519 -out "$sb/k2" 2>/dev/null
    openssl pkey -in "$sb/k1" -pubout -out "$sb/pub" 2>/dev/null
    # Signed with the WRONG key: exactly what a stale build sees after a rotation.
    openssl pkeyutl -sign -rawin -inkey "$sb/k2" \
        -in "$sb/rel/refract-layer.manifest" -out "$sb/rel/refract-layer.manifest.sig" 2>/dev/null
    out="$(reason_for)"
    assert_contains "a bad signature says the signature is bad"  "$out" "signature is NOT valid"
    assert_contains "and points at the diagnostic command"       "$out" "distro-update diagnose"
    if printf '%s' "$out" | grep -qi "reach\|connection\|wifi\|network is"; then
        fail "a bad signature is never blamed on the network" "$out"
    else
        pass "a bad signature is never blamed on the network"
    fi

    # ...and the good key must still verify, or the test above proves nothing.
    openssl pkeyutl -sign -rawin -inkey "$sb/k1" \
        -in "$sb/rel/refract-layer.manifest" -out "$sb/rel/refract-layer.manifest.sig" 2>/dev/null
    w="$(mktemp -d)"
    if fetch_verified_manifest "$w" >/dev/null 2>&1; then
        pass "a correctly signed manifest still verifies"
    else
        fail "a correctly signed manifest still verifies"
    fi
    rm -rf "$w"
else
    echo "  -- openssl not available; signature branches not exercised"
fi

# --- 4. the reason survives a subshell --------------------------------------
# fetch_verified_manifest is called inside $( ), so a plain variable would be
# discarded before the caller could read it. This is the whole reason the reason
# is written to a file, and it is worth an explicit assertion.
why "MARKER-SURVIVES"
got="$( ( last_why ) )"
assert_eq "the failure reason crosses a subshell boundary" "MARKER-SURVIVES" "$got"

# --- 5. the messages are actually distinct ----------------------------------
# If two branches produced the same text the whole feature would be decorative.
rm -f "$sb/rel/refract-layer.manifest" "$sb/rel/refract-layer.manifest.sig"
a="$(reason_for)"
printf 'refract-layer-manifest v1\n' > "$sb/rel/refract-layer.manifest"
b="$(reason_for)"
if [ "$a" != "$b" ]; then pass "different failures produce different messages"
else fail "different failures produce different messages" "both said: $a"; fi

# --- 6. diagnose exists and is wired up -------------------------------------
src="$(cat "$REPO_ROOT/modes/update/distro-update")"
assert_contains "diagnose is dispatched"      "$src" "diagnose)           cmd_diagnose"
assert_contains "diagnose is in the help text" "$src" "distro-update diagnose"
# It must test the asset host SEPARATELY from github.com — testing only
# github.com is what makes a blocked CDN look like a total outage.
assert_contains "diagnose checks the asset CDN host on its own" \
    "$src" "DNS: objects.githubusercontent.com"
assert_contains "diagnose prints the key fingerprint" "$src" "fingerprint"

# --- 7. apply's trap must not leak the reason file --------------------------
# cmd_apply sets its own EXIT trap, which REPLACES the one at the top of the
# script. Forgetting the reason file there leaks one temp file per apply.
assert_contains "apply's trap also removes the reason file" "$src" "rm -f '\$REASON_FILE'"

finish
