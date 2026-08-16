#!/usr/bin/env bash
#
# The update signature, exercised for real: a throwaway Ed25519 key is generated
# here, a manifest is signed with it, and distro-update's own verifier is run
# against the result — good, tampered, wrong-key, truncated and missing.
#
# WHY THIS TEST IS NOT OPTIONAL. Every failure mode of a verifier looks identical
# to success from the outside: it installs the update either way. The only way to
# know it rejects a bad signature is to hand it one. A "grep the source for
# openssl" check would pass on a verifier that ignores openssl's exit status —
# which is a real mistake and an easy one, because
#     openssl pkeyutl -verify ... | head -3
# exits 0 on a BAD signature (the status is head's). That was caught by hand
# while writing this; the assertions below are what stop it coming back.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPDATE="$REPO_ROOT/modes/update/distro-update"

if ! command -v openssl >/dev/null 2>&1; then
    note "openssl not available — skipping (this runs for real in CI on Ubuntu)"
    finish; exit $?
fi
if ! openssl genpkey -algorithm ed25519 -out /dev/null 2>/dev/null; then
    note "this openssl has no Ed25519 (LibreSSL?) — skipping; CI's does"
    finish; exit $?
fi

sb="$(new_stubdir)"
trap 'rm -rf "$sb"' EXIT

openssl genpkey -algorithm ed25519 -out "$sb/key.pem" 2>/dev/null
openssl pkey -in "$sb/key.pem" -pubout -out "$sb/key.pub" 2>/dev/null
openssl genpkey -algorithm ed25519 -out "$sb/other.pem" 2>/dev/null
openssl pkey -in "$sb/other.pem" -pubout -out "$sb/other.pub" 2>/dev/null

printf 'refract-layer-manifest v1\ncommit %s\nsha256 %s\nbuilt 2026-08-16T00:00:00Z\n' \
    "$(printf 'a%.0s' {1..40})" "$(printf 'b%.0s' {1..64})" > "$sb/m"
openssl pkeyutl -sign -rawin -inkey "$sb/key.pem" -in "$sb/m" -out "$sb/m.sig" 2>/dev/null

# Serve the manifest/signature from disk: `curl file://…` needs no network and
# still exercises the real code path, including its exit-status handling.
verify() {  # verify <pubkey> <manifest> <sig> -> exit status of the real function
    local dir; dir="$(mktemp -d "$sb/w.XXXXXX")"
    (
        cp "$2" "$dir/refract-layer.manifest" 2>/dev/null
        cp "$3" "$dir/refract-layer.manifest.sig" 2>/dev/null
        export REFRACT_PUBKEY="$1"
        export REFRACT_LAYER_BASE="file://$dir"
        # SOURCE the shipped script — do not carve functions out of it. The first
        # version of this used two sed ranges that overlapped (duplicating every
        # line of the verifier) and a third that ran to EOF, and the resulting
        # eval'd wreckage returned 0 for a tampered signature. The test reported
        # everything passing while verifying nothing, which is the precise
        # failure this file exists to make impossible.
        # Consumed by the source guard at the bottom of distro-update, which
        # returns before the command dispatch so this gets the functions and the
        # variables without running anything.
        export DISTRO_UPDATE_SOURCE=1
        # shellcheck disable=SC1090
        . "$UPDATE"
        fetch_verified_manifest "$dir" >/dev/null 2>&1
    )
}

# --- a good signature verifies ----------------------------------------------
verify "$sb/key.pub" "$sb/m" "$sb/m.sig"
assert_eq "a valid signature verifies" "0" "$?"

# --- a tampered manifest is REJECTED ----------------------------------------
# The realistic attack: the payload is swapped and the manifest edited to match.
sed 's/^sha256 .*/sha256 deadbeef/' "$sb/m" > "$sb/m.tampered"
verify "$sb/key.pub" "$sb/m.tampered" "$sb/m.sig"
assert_eq "an edited manifest is rejected" "1" "$?"

# --- a signature from a different key is REJECTED ---------------------------
openssl pkeyutl -sign -rawin -inkey "$sb/other.pem" -in "$sb/m" -out "$sb/m.other.sig" 2>/dev/null
verify "$sb/key.pub" "$sb/m" "$sb/m.other.sig"
assert_eq "a signature from another key is rejected" "1" "$?"

# --- a truncated signature is REJECTED --------------------------------------
head -c 30 "$sb/m.sig" > "$sb/m.trunc.sig"
verify "$sb/key.pub" "$sb/m" "$sb/m.trunc.sig"
assert_eq "a truncated signature is rejected" "1" "$?"

# --- a MISSING signature is REJECTED, not treated as fine -------------------
# The most dangerous bug in this class: "could not fetch the signature" quietly
# becoming "no signature to fail against".
: > "$sb/m.empty.sig"
verify "$sb/key.pub" "$sb/m" "$sb/m.empty.sig"
assert_eq "an empty signature is rejected" "1" "$?"

# --- the source-level invariants the above cannot see -----------------------
src="$(cat "$UPDATE")"
assert_contains "verification uses a LOCAL key path, never a fetched one" \
    "$src" 'PUBKEY="${REFRACT_PUBKEY:-/usr/share/refract/refract-signing.pub}"'
assert_contains "Ed25519 needs -rawin, or openssl errors instead of verifying" \
    "$src" "-verify -rawin -pubin"
assert_contains "the tarball digest is checked against the SIGNED manifest" \
    "$src" 'got_sha" = "$want_sha'
assert_contains "a digest mismatch refuses to install" \
    "$src" "REFUSING to install"
# The verifier must never be at the end of a pipeline: `openssl ... | head` exits
# with head's status, which is 0 for a BAD signature.
# Same reason the parity test uses `case`: a matching `grep -q` at the end of a
# pipeline under pipefail returns 141, not 0.
if grep -q 'pkeyutl -verify.*|' "$UPDATE"; then
    fail "the verify call is not piped (a pipeline would return the wrong status)"
else
    pass "the verify call is not piped (a pipeline would return the wrong status)"
fi

finish
