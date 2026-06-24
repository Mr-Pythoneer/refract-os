#!/usr/bin/env bash
#
# Sanity-checks the Server mode bundle.

set -uo pipefail

PASS=0
FAIL=0

check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo -e "\033[32m[PASS]\033[0m $desc"
        PASS=$((PASS + 1))
    else
        echo -e "\033[31m[FAIL]\033[0m $desc"
        FAIL=$((FAIL + 1))
    fi
}

check "ssh server installed and active" systemctl is-active ssh
check "password auth disabled" grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config.d/99-distro-hardening.conf
check "docker installed" command -v docker
check "docker daemon active" systemctl is-active docker
check "netdata installed" systemctl is-active netdata

echo -e "\n$PASS passed, $FAIL failed."
echo "Note: this script does NOT verify the box is usable with zero display attached — that needs an actual headless boot test, not something checkable from within a running session."
[ "$FAIL" -eq 0 ]
