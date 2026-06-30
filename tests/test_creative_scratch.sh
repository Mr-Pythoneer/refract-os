#!/usr/bin/env bash
# Tests for modes/creative/bin/distro-creative-scratch (NVMe detection).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CS="$REPO_ROOT/modes/creative/bin/distro-creative-scratch"

# REGRESSION (the df -lP bug): on real Linux/GNU coreutils, the exact df form
# the script now uses must succeed and produce output. This is the assertion
# that can ONLY be meaningful on the Ubuntu CI runner — macOS has BSD df.
if is_linux; then
  if df -l --output=source,target,avail >/dev/null 2>&1; then
    pass "GNU df -l --output works (the -lP regression is fixed)"
  else
    fail "GNU df -l --output works" "df rejected the flags the script relies on"
  fi
else
  note "skipping real-df check (not Linux; logic still covered by stubs below)"
fi

# detect with stubbed df/lsblk: picks the NVMe with the most free space.
sd="$(new_stubdir)"
stub "$sd" df 'if [[ "$*" == *-P* && "$*" == *--output* ]]; then echo "df: --portability and --output are mutually exclusive" >&2; exit 1; fi
cat <<TBL
Filesystem Mounted Avail
/dev/sda2 / 20000000
/dev/nvme0n1p1 /home 500000000
/dev/nvme1n1p1 /data 100000000
TBL'
stub "$sd" lsblk 'dev="${@: -1}"; mode="$2"
case "$dev" in
  /dev/sda2) r=1; n=sda;;
  /dev/nvme0n1p1) r=0; n=nvme0n1;;
  /dev/nvme1n1p1) r=0; n=nvme1n1;;
  *) r=1; n=x;;
esac
[ "$mode" = ROTA ] && echo "$r" || echo "$n"'
out="$(PATH="$sd:$PATH" "$CS" detect 2>/dev/null)"; rc=$?
assert_eq "detect exits 0" "0" "$rc"
assert_eq "detect picks the biggest NVMe mount" "/home" "$out"

# df failing entirely -> loud fallback to /var/tmp, still exit 0
stub "$sd" df 'exit 1'
out="$(PATH="$sd:$PATH" "$CS" detect 2>/dev/null)"; rc=$?
assert_eq "df-failure detect exits 0" "0" "$rc"
assert_eq "df-failure falls back to /var/tmp" "/var/tmp" "$out"
rm -rf "$sd"

finish
