#!/usr/bin/env bash
#
# Every download link the website can produce must point at a file that exists.
#
# THE BUG THIS EXISTS FOR. docs/index.html built its download URL by pasting the
# strain name into a template: refract-os-<strain>.iso. That is true for five of
# the six strains. The lowspec image is over GitHub's 2 GB per-release-asset
# limit, so CI publishes it as .part00/.part01 and there is no
# refract-os-lowspec.iso at all — so the one button on the page that matters
# returned a GitHub 404, and only for visitors who said they had under 8 GB of
# RAM, which is precisely the audience the lowspec build exists to serve.
#
# Nothing in the repo could notice: the page is a single static file, the URL is
# assembled at runtime in the browser, and the release assets live on a server.
# The only way to catch it is to extract the strains the page can reach and ask
# GitHub whether those files are really there.
#
# OFFLINE IS NOT A FAILURE. This is the one test in the suite that needs the
# network. It reports and skips rather than failing, so a train-journey `make
# test` does not go red for a reason that has nothing to do with the change.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DOC="$REPO_ROOT/docs/index.html"
REL="https://github.com/Mr-Pythoneer/refract-os/releases/download"

# --- what the page can actually build ---------------------------------------
# Read the strain list and the split table OUT OF THE PAGE rather than
# hard-coding them here. A copy of the list in this file would drift, and a
# stale copy would happily pass while the real page 404s.
strains="$(sed -n '/var STRAINS = {/,/^  };/p' "$DOC" \
    | sed -n 's/^[[:space:]]*\([a-z]\{4,\}\):[[:space:]]*{.*/\1/p' | sort -u)"
if [ -z "$strains" ]; then
    fail "could not read the strain list out of docs/index.html"
    finish
fi
pass "read $(echo "$strains" | wc -w | tr -d ' ') strains out of the page"

split_count() {  # split_count <strain> -> part count, or 0
    sed -n 's/.*var SPLIT = {\(.*\)};.*/\1/p' "$DOC" \
        | tr ',' '\n' | awk -F: -v s="$1" '$1 ~ s {gsub(/[^0-9]/,"",$2); print $2; exit}'
}

# Every strain listed in the picker must have a release tag, and the strain the
# renderer treats as split must be the one that really is split.
for s in $strains; do
    n="$(split_count "$s")"
    [ -n "$n" ] || n=0
    if [ "$n" -gt 0 ]; then
        pass "page knows $s is published in $n parts"
    fi
done

# --- do those files exist? ---------------------------------------------------
command -v curl >/dev/null 2>&1 || { echo "  -- curl unavailable; link checks skipped"; finish; }
if ! curl -fsS -m 15 -o /dev/null https://github.com 2>/dev/null; then
    echo "  -- offline; link checks skipped (this is not a failure)"
    finish
fi

# HEAD would be ideal but GitHub redirects release assets to a CDN that answers
# 403 to HEAD on a signed URL. A one-byte ranged GET follows the redirect and
# proves the object is really there.
#
# RETRIED, because this test fires one request per strain in quick succession
# and GitHub's CDN throttles that — which produced a suite that failed roughly
# one run in three for a reason unrelated to any change. A test that cries wolf
# gets ignored, and then it is worth less than no test at all. Two attempts with
# a pause between them turns "throttled" back into "genuinely missing".
exists() {
    curl -fsSL -m 30 -r 0-0 -o /dev/null "$1" 2>/dev/null && return 0
    sleep 2
    curl -fsSL -m 30 -r 0-0 -o /dev/null "$1" 2>/dev/null
}

for s in $strains; do
    n="$(split_count "$s")"; [ -n "$n" ] || n=0
    if [ "$n" -gt 0 ]; then
        i=0
        while [ "$i" -lt "$n" ]; do
            u="$REL/latest-$s/refract-os-$s.iso.part0$i"
            if exists "$u"; then pass "$s part $((i+1))/$n is downloadable"
            else fail "$s part $((i+1))/$n is downloadable" "404: $u"; fi
            i=$((i+1))
        done
        # ...and the single-file name must NOT exist, or the split table is
        # wrong in the other direction and visitors get two parts they did not
        # need to join.
        if exists "$REL/latest-$s/refract-os-$s.iso"; then
            fail "$s is listed as split but a single-file ISO also exists" \
                 "the SPLIT table in docs/index.html is out of date"
        else
            pass "$s has no single-file ISO, as the page assumes"
        fi
    else
        u="$REL/latest-$s/refract-os-$s.iso"
        if exists "$u"; then pass "$s downloads as a single file"
        else fail "$s downloads as a single file" "404: $u — is it split now?"; fi
    fi
done

finish
