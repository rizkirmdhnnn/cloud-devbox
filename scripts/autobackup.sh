#!/usr/bin/env bash
# Supervised loop: periodic devbox-backup, plus a final backup on SIGTERM.
set -Euo pipefail
# shellcheck source=common.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"

load_s3_env
if ! s3_configured; then
  log "autobackup: S3 not configured; automatic backup disabled"
  exit 0
fi
INTERVAL="${DEVBOX_BACKUP_INTERVAL:-900}"
if [[ "$INTERVAL" == "0" ]]; then
  log "autobackup: DEVBOX_BACKUP_INTERVAL=0; automatic backup disabled"
  exit 0
fi

run_backup() { /usr/local/bin/devbox-backup || log "autobackup: backup failed (will retry next interval)"; }

stopping=false
on_term() {
  stopping=true
  log "autobackup: shutdown requested; running final backup"
  run_backup
  exit 0
}
trap on_term TERM INT

# Wait for the boot restore to settle so an empty fresh container never
# replaces a good snapshot.
while :; do
  case "$(cat "$DEVBOX_RESTORE_STATUS" 2>/dev/null || echo pending)" in
    ok|none|skipped) break ;;
    failed) log "autobackup: boot restore failed; paused until restore succeeds or devbox-backup --force runs" ;;
  esac
  sleep 10 & wait $!
done

log "autobackup: enabled every ${INTERVAL}s"
while ! $stopping; do
  sleep "$INTERVAL" & wait $!
  run_backup
done
