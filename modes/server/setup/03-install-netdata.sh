#!/usr/bin/env bash
#
# Installs Netdata via its official kickstart script for the monitoring
# stack mentioned in DESIGN.md §4. Netdata's own install method IS a
# curl-pipe-to-shell kickstart script (no separate apt repo path that stays
# current) — review https://github.com/netdata/netdata/blob/master/packaging/installer/kickstart.sh
# before running this if that's a concern; --stable-channel pins to
# released versions rather than nightly.

set -euo pipefail

echo -e "\033[36mInstalling Netdata (stable channel)...\033[0m"
curl -fsSL https://get.netdata.cloud/kickstart.sh -o /tmp/netdata-kickstart.sh
sh /tmp/netdata-kickstart.sh --stable-channel --disable-telemetry --non-interactive
rm -f /tmp/netdata-kickstart.sh

echo -e "\033[32mNetdata installed, dashboard at http://localhost:19999 (local-network only by default).\033[0m"
echo "Telemetry disabled via --disable-telemetry, matching this project's local-first stance."
