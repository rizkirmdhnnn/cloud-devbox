#!/usr/bin/env bash
# devbox-backup [--force]
# Snapshot /workspace plus selected HOME settings to S3-compatible storage.
#   --force  upload even if nothing changed, the workspace is empty, or the
#            boot-time restore has not completed.
set -Eeuo pipefail
# shellcheck source=common.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"

FORCE=false
[[ "${1:-}" == "--force" ]] && FORCE=true

load_s3_env
s3_configured || die "S3 is not configured (need S3_ENDPOINT, S3_BUCKET, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)"
mkdir -p "$DEVBOX_STATE_DIR"

# Only one backup at a time; a manual run waits for an automatic one to finish.
exec 9>"${DEVBOX_STATE_DIR}/backup.lock"
flock -w "${DEVBOX_BACKUP_LOCK_WAIT:-600}" 9 || die "another backup is still running"

if ! $FORCE; then
  status="$(cat "$DEVBOX_RESTORE_STATUS" 2>/dev/null || echo unknown)"
  case "$status" in
    ok|none|skipped) ;;
    *) die "boot restore status is '$status'; refusing to overwrite the latest snapshot. Run devbox-restore, or devbox-backup --force if this workspace is the one to keep." ;;
  esac
  if workspace_is_empty; then
    log "workspace is empty; skipping (use --force to upload an empty snapshot)"
    exit 0
  fi
fi

mapfile -t EXCLUDES < <(default_excludes; tr ' ' '\n' <<<"${DEVBOX_BACKUP_EXCLUDES:-}" | sed '/^$/d')
EXCLUDE_ARGS=()
PRUNE_ARGS=()
for e in "${EXCLUDES[@]}"; do
  EXCLUDE_ARGS+=(--exclude="$e")
  PRUNE_ARGS+=(-name "$e" -o)
done

HOME_LIST=()
while IFS= read -r p; do
  [[ -e "$HOME/$p" ]] && HOME_LIST+=("$p")
done < <(home_paths)

# Cheap change detection: paths, sizes and mtimes of everything we would archive.
fingerprint="$(
  {
    find "$WORKSPACE" \( "${PRUNE_ARGS[@]}" -false \) -prune -o -printf '%P %s %T@\n'
    (( ${#HOME_LIST[@]} )) && (cd "$HOME" && find "${HOME_LIST[@]}" -printf '%p %s %T@\n')
    printf 'encrypted=%s\n' "${BACKUP_PASSPHRASE:+yes}"
  } 2>/dev/null | LC_ALL=C sort | sha256sum | cut -d' ' -f1
)"
if ! $FORCE && [[ "$fingerprint" == "$(cat "$DEVBOX_FINGERPRINT" 2>/dev/null)" ]]; then
  log "no changes since last backup; skipping"
  exit 0
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/devbox-backup.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# GNU tar exits 1 when a file changes while being read (live dev servers,
# logs, SQLite). That is a warning for a dev snapshot, not a failure.
tar_ok() { local rc=0; "$@" || rc=$?; (( rc <= 1 )) || return "$rc"; }

tar_ok tar -czf "$WORK/workspace.tar.gz" --warning=no-file-changed --warning=no-file-removed \
  "${EXCLUDE_ARGS[@]}" -C "$WORKSPACE" .
if (( ${#HOME_LIST[@]} )); then
  tar_ok tar -czf "$WORK/home.tar.gz" --warning=no-file-changed --warning=no-file-removed \
    --exclude='CachedExtensionVSIXs' --exclude='*.log' -C "$HOME" "${HOME_LIST[@]}"
fi
printf '{"created":"%s","host":"%s","workspace":"%s"}\n' "$STAMP" "$(hostname)" "$WORKSPACE" > "$WORK/manifest.json"
MEMBERS=(manifest.json workspace.tar.gz)
[[ -f "$WORK/home.tar.gz" ]] && MEMBERS+=(home.tar.gz)
tar -cf "$WORK/snapshot.tar" -C "$WORK" "${MEMBERS[@]}"

SUFFIX=tar
UPLOAD="$WORK/snapshot.tar"
if [[ -n "${BACKUP_PASSPHRASE:-}" ]]; then
  export GNUPGHOME="$WORK/gnupg"; install -d -m 0700 "$GNUPGHOME"
  gpg --batch --quiet --pinentry-mode loopback --passphrase-fd 3 \
    --symmetric --cipher-algo AES256 --compress-algo none \
    -o "$WORK/snapshot.tar.gpg" "$WORK/snapshot.tar" 3<<<"$BACKUP_PASSPHRASE"
  SUFFIX=tar.gpg
  UPLOAD="$WORK/snapshot.tar.gpg"
fi

SHA="$(sha256sum "$UPLOAD" | cut -d' ' -f1)"
SIZE="$(stat -c %s "$UPLOAD")"
KEY="snapshots/${STAMP}.${SUFFIX}"

s3 s3 cp "$UPLOAD" "$(s3_uri "$KEY")" --only-show-errors --metadata "sha256=${SHA}"
# Verify the stored object before advancing the pointer.
REMOTE_SIZE="$(s3 s3api head-object --bucket "$S3_BUCKET" --key "${S3_PREFIX}/${KEY}" --query ContentLength --output text)"
[[ "$REMOTE_SIZE" == "$SIZE" ]] || die "uploaded size mismatch ($REMOTE_SIZE != $SIZE); latest pointer not updated"

printf '{"key":"%s","sha256":"%s","size":%s,"created":"%s","encrypted":%s}\n' \
  "$KEY" "$SHA" "$SIZE" "$STAMP" "$([[ $SUFFIX == tar.gpg ]] && echo true || echo false)" > "$WORK/latest.json"
s3 s3 cp "$WORK/latest.json" "$(s3_uri latest.json)" --only-show-errors --content-type application/json
cp "$WORK/latest.json" "$DEVBOX_LAST_BACKUP"
printf '%s\n' "$fingerprint" > "$DEVBOX_FINGERPRINT"

# Retention: keep the newest DEVBOX_BACKUP_KEEP snapshots.
KEEP="${DEVBOX_BACKUP_KEEP:-48}"
if [[ "$KEEP" =~ ^[0-9]+$ ]] && (( KEEP > 0 )); then
  s3 s3 ls "$(s3_uri snapshots/)" | awk '{print $4}' | grep -E '^[0-9]{8}T[0-9]{6}Z\.tar(\.gpg)?$' \
    | LC_ALL=C sort -r | tail -n +"$((KEEP + 1))" | while read -r old; do
      s3 s3 rm "$(s3_uri "snapshots/$old")" --only-show-errors && log "pruned $old"
    done
fi

log "backup uploaded: $(s3_uri "$KEY") ($(numfmt --to=iec "$SIZE"), sha256 ${SHA:0:12}…${BACKUP_PASSPHRASE:+, encrypted})"
[[ -z "${BACKUP_PASSPHRASE:-}" ]] && log "note: BACKUP_PASSPHRASE is not set; snapshot is unencrypted and credentials (gh, tunnel, ssh) were not included"
exit 0
