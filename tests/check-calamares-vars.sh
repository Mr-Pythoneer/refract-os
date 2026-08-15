#!/usr/bin/env bash
# Calamares expands $word and ${word} in shellprocess commands ITSELF, before the
# shell runs, from a dictionary containing exactly ROOT, USER and LANG
# (libcalamares/utils/CommandList.cpp, get_gs_expander). Any other name aborts
# the install at that job with:
#     The commands use variables that are not defined. Missing variables are: f,f,f,f
#
# This has now cost two hardware install attempts — once with ${gs[...]}, which
# does not exist as a syntax at all, and once with an ordinary shell variable
# $f used to hold a path. Both looked completely normal, and both were invisible
# to local shell testing, because running the command in sh skips the layer that
# rejects it.
#
# So: assert it statically, on every push, with no ISO required.
set -uo pipefail
cd "$(dirname "$0")/.."

ALLOWED='^(ROOT|USER|LANG)$'
fail=0

for f in iso/calamares/modules/*.conf; do
    [ -e "$f" ] || continue
    # Only the command strings matter; comments explaining the rule must not trip it.
    names=$(grep -vE '^[[:space:]]*#' "$f" \
              | grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*' \
              | sed -E 's/^\$\{?//' | sort -u)
    for n in $names; do
        if ! printf '%s' "$n" | grep -qE "$ALLOWED"; then
            echo "FAIL $f: uses \$$n — Calamares only defines ROOT, USER and LANG."
            echo "     Write the value out in full, or move the logic into a script shipped in the image."
            fail=1
        fi
    done
done

# gs[...] is not a Calamares syntax in shellprocess at any version; it belongs to
# contextualprocess's config schema and was copied across by mistake once already.
if grep -rlE '\$\{?gs\[' iso/calamares/modules/ 2>/dev/null | grep -q .; then
    echo "FAIL: a module conf uses \${gs[...]} — shellprocess has no such expansion."
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "ok: all Calamares module commands use only ROOT/USER/LANG"
fi
exit "$fail"
