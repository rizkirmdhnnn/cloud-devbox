#!/usr/bin/env bash
# Shared helpers for devbox-* commands. Sourced, not executed.
# shellcheck disable=SC2034  # variables are used by the sourcing scripts

DEVBOX_STATE_DIR="${HOME}/.config/devbox"
DEVBOX_S3_ENV="${DEVBOX_STATE_DIR}/s3.env"
DEVBOX_RESTORE_STATUS="${DEVBOX_STATE_DIR}/restore-status"
DEVBOX_LAST_BACKUP="${DEVBOX_STATE_DIR}/last-backup.json"
DEVBOX_FINGERPRINT="${DEVBOX_STATE_DIR}/last-fingerprint"
WORKSPACE="${WORKSPACE:-/workspace}"

log() { printf '[devbox %s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# The entrypoint moves S3 settings out of the global environment into a 0600
# file so IDE terminals and extensions do not inherit the credentials.
load_s3_env() {
  if [[ -f "$DEVBOX_S3_ENV" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "$DEVBOX_S3_ENV"
    set +a
  fi
  export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
  # Many S3-compatible services reject the newer default CRC checksums.
  export AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}"
  export AWS_RESPONSE_CHECKSUM_VALIDATION="${AWS_RESPONSE_CHECKSUM_VALIDATION:-when_required}"
  if [[ "${S3_FORCE_PATH_STYLE:-true}" == "true" ]]; then
    export AWS_CONFIG_FILE="${DEVBOX_STATE_DIR}/aws-config"
    if [[ ! -f "$AWS_CONFIG_FILE" ]]; then
      mkdir -p "$DEVBOX_STATE_DIR"
      printf '[default]\ns3 =\n    addressing_style = path\n' > "$AWS_CONFIG_FILE"
    fi
  fi
  S3_PREFIX="${S3_PREFIX:-cloud-devbox}"
  S3_PREFIX="${S3_PREFIX%/}"
}

s3_configured() {
  [[ -n "${S3_ENDPOINT:-}" && -n "${S3_BUCKET:-}" \
     && -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]
}

s3() { aws --endpoint-url "$S3_ENDPOINT" "$@"; }

s3_uri() { printf 's3://%s/%s/%s' "$S3_BUCKET" "$S3_PREFIX" "$1"; }

# A workspace counts as empty when it holds nothing but empty directories.
workspace_is_empty() {
  [[ ! -d "$WORKSPACE" ]] && return 0
  [[ -z "$(find "$WORKSPACE" -mindepth 1 -not -type d -print -quit 2>/dev/null)" ]]
}

# Directory names never worth backing up: they are rebuilt from lockfiles.
default_excludes() {
  printf '%s\n' node_modules vendor .venv venv __pycache__ .cache .next .turbo \
    .pytest_cache .mypy_cache .gradle
}

# HOME paths that restore the editor/shell experience. Credential paths are
# only included when the archive is encrypted (BACKUP_PASSPHRASE set).
home_paths() {
  printf '%s\n' .gitconfig .zshrc .zsh_history .bash_history .tmux.conf \
    .config/nvim .local/share/code-server/User .local/share/code-server/extensions
  if [[ -n "${BACKUP_PASSPHRASE:-}" ]]; then
    printf '%s\n' .config/gh .vscode/cli .ssh .git-credentials .config/composer/auth.json
  fi
}
