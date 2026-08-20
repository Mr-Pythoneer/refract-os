#!/usr/bin/env bash
#
# The updater must not be able to hammer GitHub.
#
# REPORTED BEHAVIOUR: "I'm spamming the update button and it keeps saying GitHub
# is not responding — I tried three networks and a crap ton of VPNs." Every one
# of those clicks sent a fresh request, because nothing cached an answer,
# nothing read a Retry-After and nothing recognised a 403. The failure message
# ("could not reach GitHub") reads as "try again", and trying again is exactly
# what extends the block. Hopping VPNs makes it worse: a shared exit IP usually
# arrives with its 60/hour budget already spent by strangers.
#
# A client that keeps knocking after being told to stop is indistinguishable
# from an attack. These assertions are what stop this one doing that.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

sb="$(new_stubdir)"
trap 'rm -rf "$sb"' EXIT
export DISTRO_UPDATE_SOURCE=1
export REFRACT_CACHE_DIR="$sb/cache"
export REFRACT_PUBKEY="$sb/nokey"
export REFRACT_MIN_CHECK_INTERVAL=300
# shellcheck disable=SC1090
. "$REPO_ROOT/modes/update/distro-update"

# --- cooldown bookkeeping ----------------------------------------------------
assert_eq "no cooldown by default" "0" "$(cooldown_left)"
set_cooldown 120
n="$(cooldown_left)"
if [ "$n" -gt 100 ] && [ "$n" -le 120 ]; then pass "a cooldown is recorded in seconds"
else fail "a cooldown is recorded in seconds" "got [$n]"; fi

# An expired cooldown must read as zero, not as a negative number — a negative
# would pass a `-gt 0` test nowhere but would break the human_secs arithmetic.
printf '%s\n' "$(( $(now_s) - 50 ))" > "$REFRACT_CACHE_DIR/backoff-until"
assert_eq "an expired cooldown reads as 0" "0" "$(cooldown_left)"

# Garbage in the file must not crash the updater or read as a huge wait.
printf 'not-a-number\n' > "$REFRACT_CACHE_DIR/backoff-until"
assert_eq "a corrupt cooldown file reads as 0" "0" "$(cooldown_left)"
rm -f "$REFRACT_CACHE_DIR/backoff-until"

# --- Retry-After is actually parsed -----------------------------------------
# The whole point of honouring a rate limit is using the server's own number.
cat > "$sb/curl" <<'STUB'
#!/usr/bin/env bash
# Minimal curl stub: emits a 429 with a Retry-After into the -D file.
hdr=""; prev=""
for a in "$@"; do [ "$prev" = "-D" ] && hdr="$a"; prev="$a"; done
[ -n "$hdr" ] && printf 'HTTP/2 429\r\nRetry-After: 900\r\n\r\n' > "$hdr"
printf '429'
exit 22
STUB
chmod +x "$sb/curl"
PATH="$sb:$PATH" http_get "https://example.invalid/x" "$sb/out" >/dev/null 2>&1
n="$(cooldown_left)"
if [ "$n" -gt 800 ] && [ "$n" -le 900 ]; then pass "Retry-After: 900 becomes a 15-minute cooldown"
else fail "Retry-After: 900 becomes a 15-minute cooldown" "got [$n]"; fi
assert_contains "the reason names the rate limit, not the network" "$(last_why)" "rate limit"
assert_contains "and says switching VPNs makes it worse"           "$(last_why)" "switching VPNs"
# It must NOT tell somebody their connection is broken, or they go and change
# networks — which is what produced the three-networks-and-VPNs report.
if printf '%s' "$(last_why)" | grep -qi "check your \(network\|connection\|wifi\)"; then
    fail "a rate limit never tells the user to check their connection" "$(last_why)"
else
    pass "a rate limit never tells the user to check their connection"
fi

# --- a refusal with no Retry-After still backs off --------------------------
rm -f "$REFRACT_CACHE_DIR/backoff-until"
cat > "$sb/curl" <<'STUB'
#!/usr/bin/env bash
hdr=""; prev=""
for a in "$@"; do [ "$prev" = "-D" ] && hdr="$a"; prev="$a"; done
[ -n "$hdr" ] && printf 'HTTP/2 403\r\n\r\n' > "$hdr"
printf '403'
exit 22
STUB
chmod +x "$sb/curl"
PATH="$sb:$PATH" http_get "https://example.invalid/x" "$sb/out" >/dev/null 2>&1
if [ "$(cooldown_left)" -gt 0 ]; then pass "a 403 with no Retry-After still backs off"
else fail "a 403 with no Retry-After still backs off" "no cooldown recorded"; fi

# --- a cooldown SUPPRESSES the request entirely ------------------------------
# This is the assertion that matters. If cmd_check still calls out while a
# cooldown is live, everything above is decorative.
set_cooldown 600
cat > "$sb/curl" <<'STUB'
#!/usr/bin/env bash
echo "CURL-WAS-CALLED" >> "$REFRACT_CACHE_DIR/calls"
exit 0
STUB
chmod +x "$sb/curl"
rm -f "$REFRACT_CACHE_DIR/calls"
out="$(PATH="$sb:$PATH" REFRACT_BUILD_ID_FILE=/nonexistent cmd_check 2>&1)"
if [ -f "$REFRACT_CACHE_DIR/calls" ]; then
    fail "no request is sent while a cooldown is active" "curl ran anyway"
else
    pass "no request is sent while a cooldown is active"
fi
assert_contains "and the user is told how long is left" "$out" "left"

# --- a fresh answer is reused instead of re-asking ---------------------------
rm -f "$REFRACT_CACHE_DIR/backoff-until" "$REFRACT_CACHE_DIR/calls"
printf '%s %s\n' "$(now_s)" "$(printf '%040d' 7)" > "$REFRACT_CACHE_DIR/last-check"
out="$(PATH="$sb:$PATH" REFRACT_BUILD_ID_FILE=/nonexistent cmd_check 2>&1)"
if [ -f "$REFRACT_CACHE_DIR/calls" ]; then
    fail "a recent answer is reused without asking again" "curl ran anyway"
else
    pass "a recent answer is reused without asking again"
fi
assert_contains "and says the answer is a reused one" "$out" "reusing that answer"

# A STALE cache must not be reused — the point is to throttle, not to go blind.
printf '%s %s\n' "$(( $(now_s) - 99999 ))" "$(printf '%040d' 7)" > "$REFRACT_CACHE_DIR/last-check"
rm -f "$REFRACT_CACHE_DIR/calls"
PATH="$sb:$PATH" REFRACT_BUILD_ID_FILE=/nonexistent cmd_check >/dev/null 2>&1
if [ -f "$REFRACT_CACHE_DIR/calls" ]; then pass "a stale answer is NOT reused"
else fail "a stale answer is NOT reused" "no request was sent"; fi

# --- diagnose surfaces the cooldown first ------------------------------------
src="$(cat "$REPO_ROOT/modes/update/distro-update")"
assert_contains "diagnose reports an active cooldown" "$src" "Rate-limited: waiting"

finish
