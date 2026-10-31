#!/usr/bin/env bash
# devbox-tunnel login|run|status|logout
# VS Code Remote Tunnels via the official VS Code CLI (outbound HTTPS only).
set -Eeuo pipefail
# shellcheck source=common.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"

NAME="${TUNNEL_NAME:-cloud-devbox}"
SVC=(supervisorctl -c /etc/devbox/supervisord.conf)
logged_in() { code tunnel user show 2>/dev/null | grep -qiv 'not logged in'; }

case "${1:-status}" in
  login)
    code tunnel user login --provider "${TUNNEL_PROVIDER:-github}"
    "${SVC[@]}" start tunnel || true
    if [[ -n "${BACKUP_PASSPHRASE:-}" ]] || grep -q '^BACKUP_PASSPHRASE=' "$DEVBOX_S3_ENV" 2>/dev/null; then
      /usr/local/bin/devbox-backup --force || log "could not back up the tunnel login; run devbox-backup later"
    else
      log "BACKUP_PASSPHRASE is not set: the tunnel login is not backed up and must be repeated after the container is recreated"
    fi
    ;;
  run)
    # Started by the supervisor. Exits cleanly (no restart loop) until logged in.
    if ! logged_in; then
      log "tunnel: not logged in; open a terminal and run: devbox-tunnel login"
      exit 0
    fi
    exec code tunnel --accept-server-license-terms --name "$NAME"
    ;;
  status) code tunnel user show || true; "${SVC[@]}" status tunnel || true ;;
  logout) "${SVC[@]}" stop tunnel || true; code tunnel user logout ;;
  *) die "usage: devbox-tunnel login|run|status|logout" ;;
esac
