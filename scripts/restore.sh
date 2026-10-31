#!/usr/bin/env bash
# devbox-restore [--force] [--yes] [--list] [SNAPSHOT_KEY]
# Restore the latest (or a given) snapshot into /workspace and HOME.
#   (default)  only restores into an empty workspace
#   --force    restore into a non-empty workspace; a local safety copy of the
#              current workspace is written to ~/.cache/devbox first
#   --yes      do not ask for confirmation
#   --list     list available snapshots
#   --boot     used by the supervisor at startup (empty workspace only, no prompt)
set -Eeuo pipefail
# shellcheck source=common.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"

FORCE=false; YES=false; BOOT=false; LIST=false; KEY=""
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
    --yes|-y) YES=true ;;
    --boot) BOOT=true; YES=true ;;
    --list) LIST=true ;;
    -*) die "unknown option: $arg" ;;
    *) KEY="$arg" ;;
  esac
done

mkdir -p "$DEVBOX_STATE_DIR"
set_status() { $BOOT && printf '%s\n' "$1" > "$DEVBOX_RESTORE_STATUS"; return 0; }

load_s3_env
if ! s3_configured; then
  set_status skipped
  $BOOT && { log "S3 not configured; boot restore skipped (automatic backup disabled)"; exit 0; }
  die "S3 is not configured"
fi

if $LIST; then
  s3 s3 ls "$(s3_uri snapshots/)"
  exit 0
fi

if $BOOT; then
  if [[ "${DEVBOX_AUTO_RESTORE:-true}" != "true" ]]; then
    set_status skipped; log "DEVBOX_AUTO_RESTORE=false; boot restore skipped"; exit 0
  fi
  if ! workspace_is_empty; then
    set_status ok; log "workspace already has files; boot restore not needed"; exit 0
  fi
  set_status running
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/devbox-restore.XXXXXX")"
# shellcheck disable=SC2154  # rc is assigned inside the trap string
trap 'rc=$?; rm -rf "$WORK"; if $BOOT && (( rc != 0 )); then set_status failed; log "boot restore FAILED (exit $rc); automatic backup is paused until you run devbox-restore or devbox-backup --force"; fi' EXIT

EXPECTED_SHA=""
ENCRYPTED=false
if [[ -z "$KEY" ]]; then
  if ! s3 s3 cp "$(s3_uri latest.json)" "$WORK/latest.json" --only-show-errors 2>"$WORK/err"; then
    if grep -qiE '404|Not ?Found|does not exist' "$WORK/err"; then
      set_status none; log "no snapshot found at $(s3_uri latest.json); nothing to restore"; exit 0
    fi
    cat "$WORK/err" >&2; die "cannot read latest snapshot pointer"
  fi
  KEY="$(jq -r .key "$WORK/latest.json")"
  EXPECTED_SHA="$(jq -r .sha256 "$WORK/latest.json")"
fi
[[ "$KEY" == *.tar.gpg ]] && ENCRYPTED=true

if ! workspace_is_empty && ! $FORCE; then
  die "$WORKSPACE is not empty. Re-run with --force to merge the snapshot over it (a safety copy is kept), or empty it first."
fi

if ! $YES; then
  [[ -t 0 ]] || die "not a terminal; pass --yes to confirm"
  printf 'Restore %s into %s and %s? [y/N] ' "$KEY" "$WORKSPACE" "$HOME"
  read -r ans
  [[ "$ans" == y || "$ans" == Y ]] || die "aborted"
fi

log "downloading $(s3_uri "$KEY")"
s3 s3 cp "$(s3_uri "$KEY")" "$WORK/snapshot" --only-show-errors
if [[ -z "$EXPECTED_SHA" ]]; then
  EXPECTED_SHA="$(s3 s3api head-object --bucket "$S3_BUCKET" --key "${S3_PREFIX}/${KEY}" \
    --query 'Metadata.sha256' --output text 2>/dev/null || true)"
fi
ACTUAL_SHA="$(sha256sum "$WORK/snapshot" | cut -d' ' -f1)"
if [[ -n "$EXPECTED_SHA" && "$EXPECTED_SHA" != "None" ]]; then
  [[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]] || die "checksum mismatch for $KEY (expected $EXPECTED_SHA, got $ACTUAL_SHA)"
  log "checksum verified"
else
  log "warning: no stored checksum for $KEY; integrity not verified"
fi

if $ENCRYPTED; then
  [[ -n "${BACKUP_PASSPHRASE:-}" ]] || die "$KEY is encrypted; set BACKUP_PASSPHRASE"
  export GNUPGHOME="$WORK/gnupg"; install -d -m 0700 "$GNUPGHOME"
  gpg --batch --quiet --pinentry-mode loopback --passphrase-fd 3 \
    -o "$WORK/snapshot.tar" -d "$WORK/snapshot" 3<<<"$BACKUP_PASSPHRASE"
else
  mv "$WORK/snapshot" "$WORK/snapshot.tar"
fi

# Extract into staging first. GNU tar refuses '..' members and strips leading
# '/', and staging is a fresh directory, so nothing lands outside it.
mkdir -p "$WORK/outer" "$WORK/ws" "$WORK/home"
tar -xf "$WORK/snapshot.tar" -C "$WORK/outer" --no-same-owner
[[ -f "$WORK/outer/workspace.tar.gz" ]] || die "snapshot has no workspace.tar.gz"
tar -xzf "$WORK/outer/workspace.tar.gz" -C "$WORK/ws" --no-same-owner
[[ -f "$WORK/outer/home.tar.gz" ]] && tar -xzf "$WORK/outer/home.tar.gz" -C "$WORK/home" --no-same-owner

if ! workspace_is_empty; then
  SAFETY="${HOME}/.cache/devbox/pre-restore-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
  mkdir -p "$(dirname "$SAFETY")"
  tar -czf "$SAFETY" -C "$WORKSPACE" . 2>/dev/null || [[ $? -le 1 ]]
  log "safety copy of the current workspace: $SAFETY"
fi

mkdir -p "$WORKSPACE"
rsync -a "$WORK/ws/" "$WORKSPACE/"
rsync -a "$WORK/home/" "$HOME/"

# Forget the previous fingerprint so the next automatic backup records the
# restored state as a fresh snapshot.
rm -f "$DEVBOX_FINGERPRINT"
set_status ok
log "restore completed from $(s3_uri "$KEY")"
