#!/usr/bin/env bash
# Container entrypoint (runs as the unprivileged user, never as root).
# Prepares config, moves secrets out of the environment, then hands PID 1 to
# supervisord, which runs code-server, Redis, boot restore, autobackup, tunnel.
set -Eeuo pipefail
log() { printf '[devbox %s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

# A platform may run the image with an arbitrary UID that cannot write the
# baked-in home. Fall back to an ephemeral home instead of crashing.
if ! { mkdir -p "$HOME/.config" && touch "$HOME/.config/.write-test"; } 2>/dev/null; then
  log "warning: $HOME is not writable for uid $(id -u); using /tmp/home"
  export HOME=/tmp/home
  mkdir -p "$HOME"
  cp -n /etc/skel-devbox/.zshrc "$HOME/.zshrc"
fi
rm -f "$HOME/.config/.write-test"
WORKSPACE="${WORKSPACE:-/workspace}"
if ! { mkdir -p "$WORKSPACE" && touch "$WORKSPACE/.write-test"; } 2>/dev/null; then
  log "error: workspace $WORKSPACE is not writable for uid $(id -u)"
  exit 1
fi
rm -f "$WORKSPACE/.write-test"
export WORKSPACE

if [[ -z "${PASSWORD:-}" && -z "${HASHED_PASSWORD:-}" ]]; then
  log "error: set PASSWORD or HASHED_PASSWORD as a platform secret"
  exit 1
fi

umask 077
mkdir -p "$HOME/.config/code-server" "$HOME/.config/devbox" "$HOME/.local/share" "$HOME/.cache"

# code-server config. Values are JSON-encoded, which is valid YAML, so any
# character in the password is safe.
python3 - <<'PY'
import json, os
from pathlib import Path
port = os.environ.get("PORT") or "8080"
lines = [f"bind-addr: {json.dumps('0.0.0.0:' + port)}", "auth: password", "cert: false"]
if os.environ.get("HASHED_PASSWORD"):
    lines.append(f"hashed-password: {json.dumps(os.environ['HASHED_PASSWORD'])}")
else:
    lines.append(f"password: {json.dumps(os.environ['PASSWORD'])}")
domains = [d.strip() for d in os.environ.get("PROXY_DOMAIN", "").split(",") if d.strip()]
if domains:
    lines.append("proxy-domain: " + json.dumps(domains))
p = Path(os.environ["HOME"]) / ".config/code-server/config.yaml"
p.write_text("\n".join(lines) + "\n")
p.chmod(0o600)
PY

# Accept the variable names a platform binding publishes (Skalo: S3_KEY,
# S3_SECRET, S3_REGION) as well as the standard AWS names.
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-${S3_ACCESS_KEY_ID:-${S3_KEY:-}}}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-${S3_SECRET_ACCESS_KEY:-${S3_SECRET:-}}}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-${S3_REGION:-}}"

# Backup settings go to a 0600 file read only by devbox-* scripts.
S3_VARS=(S3_ENDPOINT S3_BUCKET S3_PREFIX S3_FORCE_PATH_STYLE AWS_ACCESS_KEY_ID
         AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION BACKUP_PASSPHRASE)
: > "$HOME/.config/devbox/s3.env"
for v in "${S3_VARS[@]}"; do
  [[ -n "${!v:-}" ]] && printf '%s=%q\n' "$v" "${!v}" >> "$HOME/.config/devbox/s3.env"
done
rm -f "$HOME/.config/devbox/restore-status" "$HOME/.config/devbox/aws-config"

# Nothing below this point (IDE, terminals, extensions, project code) needs
# these. exec replaces this process, so /proc/1/environ is clean as well.
unset PASSWORD HASHED_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY BACKUP_PASSPHRASE \
      S3_KEY S3_SECRET S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY
umask 022

exec /usr/bin/supervisord -n -c /etc/devbox/supervisord.conf
