#!/usr/bin/env bash
#
# Refract Tips renders the update history from WHATS-NEW.md. Two things can break
# it silently, and both are checked here with Python rather than by eye:
#
#   1. The parser and the file drifting apart. The file is hand-written, and a
#      heading that does not match the expected shape does not error — the entry
#      simply never appears in the app, and nobody notices a note that was never
#      there.
#   2. The markup conversion escaping in the wrong order. Pango does not render a
#      broken markup string, it renders NOTHING, so a stray & in a note would
#      blank the whole entry.
#
# It also asserts the file is installed by both delivery paths, since a page that
# reads a file nothing ships is just an empty page.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TIPS="$REPO_ROOT/modes/tips/refract-tips"
NOTES="$REPO_ROOT/WHATS-NEW.md"

if [ ! -f "$NOTES" ]; then
    fail "WHATS-NEW.md exists" "the update history is the source for the Tips page"
    finish; exit $?
fi

out="$(python3 - "$TIPS" "$NOTES" <<'PY' 2>&1
import re, sys
src = open(sys.argv[1]).read()
ns = {"re": re, "os": __import__("os"),
      "GLib": type("G", (), {"markup_escape_text": staticmethod(
          lambda s: s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))})()}
exec(compile(re.search(r"def _markup.*?(?=\ndef _exists)", src, re.S).group(0), "m", "exec"), ns)
exec(compile(re.search(r"def read_whats_new.*?\n    return entries", src, re.S).group(0), "r", "exec"), ns)
ns["_WHATS_NEW_FALLBACKS"] = (sys.argv[2],)

entries = ns["read_whats_new"]()
print("COUNT", len(entries))

# Every heading the file declares must survive the parser. A silent drop is the
# failure mode this whole test exists for.
declared = [l[3:].strip() for l in open(sys.argv[2]).read().splitlines() if l.startswith("## ")]
print("DECLARED", len(declared))
print("MATCH", declared == [h for h, _ in entries])

# Newest first — distro-update's cursor and this page both depend on it.
dates = [h.split(" ")[0] for h, _ in entries]
print("SORTED", dates == sorted(dates, reverse=True))

# No entry may be empty: a title that expands to nothing is worse than no title.
print("NOBODY_EMPTY", all(b.strip() for _, b in entries))

# Escaping happens BEFORE tags are added, or a & in a note blanks the entry.
m = ns["_markup"]("**b** `c` & <x>")
print("MARKUP_OK", "<b>b</b>" in m and "<tt>c</tt>" in m and "&amp;" in m and "&lt;x&gt;" in m)

# And the real bodies must all convert without leaving a raw & behind.
bad = [h for h, b in entries if "&" in ns["_markup"](b).replace("&amp;", "").replace("&lt;", "").replace("&gt;", "").replace("&quot;", "").replace("&#39;", "")]
print("NO_RAW_AMP", not bad, bad[:2])
PY
)"

get() { printf '%s\n' "$out" | awk -v k="$1" '$1==k {print $2; exit}'; }

n="$(get COUNT)"
if [ "${n:-0}" -gt 0 ]; then pass "the Tips parser reads $n entries"; else fail "the Tips parser reads entries" "$out"; fi
assert_eq "every heading in the file survives the parser" "True" "$(get MATCH)"
assert_eq "entries are newest-first" "True" "$(get SORTED)"
assert_eq "no entry has an empty body" "True" "$(get NOBODY_EMPTY)"
assert_eq "markup escapes before it tags" "True" "$(get MARKUP_OK)"
assert_eq "no note leaves a raw ampersand in the markup" "True" "$(get NO_RAW_AMP)"

# --- both delivery paths must install it ------------------------------------
assert_contains "iso/build.sh installs it into the image" \
    "$(cat "$REPO_ROOT/iso/build.sh")" "usr/share/refract/WHATS-NEW.md"
assert_contains "distro-update apply refreshes it" \
    "$(cat "$REPO_ROOT/modes/update/distro-update")" '/usr/share/refract/$NOTES_FILE'
assert_contains "the signed payload carries it" \
    "$(cat "$REPO_ROOT/.github/workflows/sign-layer.yml")" "WHATS-NEW.md"

finish
