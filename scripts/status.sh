#!/usr/bin/env bash
# devbox-status: services, restore state, last backup.
set -uo pipefail
# shellcheck source=common.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"
echo "== services"; supervisorctl -c /etc/devbox/supervisord.conf status
echo "== boot restore: $(cat "$DEVBOX_RESTORE_STATUS" 2>/dev/null || echo unknown)"
echo "== last backup: $(cat "$DEVBOX_LAST_BACKUP" 2>/dev/null || echo none in this container)"
echo "== disk"; df -h "$WORKSPACE" /tmp | tail -n +2
