#!/usr/bin/env bash
# End-to-end persistence test against a disposable S3 server:
#   tests/e2e-backup.sh IMAGE [S3_IMAGE]
# Covers auto-restore on boot, periodic + shutdown backup, encryption,
# credential round-trip, restore guards, failed-restore safety, retention.
set -Eeuo pipefail
IMG="${1:?usage: tests/e2e-backup.sh IMAGE [S3_IMAGE]}"
S3IMG="${2:-rustfs/rustfs:latest}"
NET="devbox-e2e-$$"
P="dbx-e2e-$$"
fail() { echo "FAIL: $*" >&2; for c in a b c d; do docker logs "$P-$c" 2>&1 | tail -15 | sed "s/^/[$c] /" >&2 || true; done; exit 1; }
pass() { echo "ok   $*"; }
cleanup() { docker rm -f "$P-s3" "$P-a" "$P-b" "$P-c" "$P-d" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; }
trap cleanup EXIT
trap 'echo "FAIL: line $LINENO: $BASH_COMMAND" >&2' ERR

docker network create "$NET" >/dev/null
docker run -d --name "$P-s3" --network "$NET" --network-alias s3 \
  -e RUSTFS_ACCESS_KEY=e2euser -e RUSTFS_SECRET_KEY=e2epass1234 -e RUSTFS_ADDRESS=0.0.0.0:9000 \
  -e RUSTFS_VOLUMES=/data --tmpfs /data:mode=1777 --tmpfs /logs:mode=1777 "$S3IMG" /data >/dev/null

ENVS=(-e PASSWORD=x -e S3_ENDPOINT=http://s3:9000 -e S3_BUCKET=e2e -e S3_PREFIX=e2e/devbox
      -e AWS_ACCESS_KEY_ID=e2euser -e AWS_SECRET_ACCESS_KEY=e2epass1234
      -e BACKUP_PASSPHRASE='correct horse "battery" $staple' -e DEVBOX_BACKUP_INTERVAL=15 -e DEVBOX_BACKUP_KEEP=3)
start() { local n=$1; shift; docker run -d --name "$P-$n" --network "$NET" "$@" "$IMG" >/dev/null; }
ex() { local n=$1; shift; docker exec "$P-$n" bash -c "$*"; }
wait_log() { local n=$1 pat=$2 t=${3:-90}; for _ in $(seq 1 "$t"); do docker logs "$P-$n" 2>&1 | grep -q -- "$pat" && return 0; sleep 1; done; return 1; }

start a "${ENVS[@]}"
for _ in $(seq 1 30); do ex a 'set -a; . ~/.config/devbox/s3.env; aws --endpoint-url $S3_ENDPOINT s3 mb s3://e2e' >/dev/null 2>&1 && break; sleep 2; done
docker restart "$P-a" >/dev/null   # boot again now that the bucket exists
wait_log a "nothing to restore" || fail "boot restore did not report an empty bucket"
pass "boot restore on empty bucket -> status none"

for _ in $(seq 1 60); do docker exec "$P-a" devbox-healthcheck 2>/dev/null && break; sleep 2; done
pid=$(docker exec "$P-a" pgrep -o -f /usr/lib/code-server) || fail "code-server not running"
ex a "! tr '\0' '\n' < /proc/$pid/environ | grep -qE '^(AWS_SECRET_ACCESS_KEY|BACKUP_PASSPHRASE)='" || fail "S3 secrets visible to code-server"
pass "S3 secret and passphrase not in code-server environment"

ex a '
set -e; cd /workspace/projects && mkdir app && cd app && git init -q
git config --global user.name "E2E User"; git config --global user.email e2e@example.com
echo committed > a.txt && git add a.txt && git commit -qm init
echo wip > wip.txt; echo staged > s.txt; git add s.txt
printf "#!/bin/sh\necho hi\n" > run.sh; chmod 0755 run.sh; ln -s a.txt link.txt
echo "APP_KEY=secret" > .env; mkdir -p node_modules/x && echo big > node_modules/x/f
mkdir -p ~/.config/gh ~/.vscode/cli && echo "token: fake" > ~/.config/gh/hosts.yml && echo "{\"t\":1}" > ~/.vscode/cli/token.json
echo "echo restored-history" >> ~/.zsh_history'
ex a 'cd /workspace && find . -path ./projects/app/node_modules -prune -o -type f -print0 | sort -z | xargs -0 sha256sum' > /tmp/$P-before
wait_log a "backup uploaded" 60 || fail "periodic autobackup did not run"
pass "periodic autobackup uploaded an encrypted snapshot"

ex a 'bash -c "while :; do echo \$RANDOM >> /workspace/projects/app/live.log; sleep 0.01; done" >/dev/null 2>&1 & W=$!
sleep 1; devbox-backup --force; rc=$?; kill $W; rm -f /workspace/projects/app/live.log; exit $rc' >/dev/null 2>&1 \
  || fail "backup failed while a file was being written"
pass "backup succeeds while files change (tar exit 1 tolerated)"

ex a 'echo final-change > /workspace/projects/app/last-minute.txt'
docker stop -t 120 "$P-a" >/dev/null
docker logs "$P-a" 2>&1 | grep -q "running final backup" || fail "no final backup on SIGTERM"
docker logs "$P-a" 2>&1 | tail -5 | grep -q "backup uploaded" || fail "final backup did not upload"
pass "final backup on SIGTERM captured last-minute change"

start b "${ENVS[@]}"
wait_log b "restore completed" 120 || fail "fresh container did not auto-restore"
ex b 'cd /workspace && find . -path ./projects/app/node_modules -prune -o -type f -not -name last-minute.txt -print0 | sort -z | xargs -0 sha256sum' > /tmp/$P-after
diff /tmp/$P-before /tmp/$P-after >/dev/null || { diff /tmp/$P-before /tmp/$P-after | head; fail "restored files differ"; }
ex b 'cd /workspace/projects/app && test "$(cat last-minute.txt)" = final-change && test -x run.sh && test -L link.txt \
  && test ! -e node_modules && git status --short | grep -q "^A  s.txt" && git status --short | grep -q "?? wip.txt"' || fail "workspace state not restored"
ex b 'test "$(git config --global user.name)" = "E2E User" && grep -q fake ~/.config/gh/hosts.yml && test -f ~/.vscode/cli/token.json && grep -q restored-history ~/.zsh_history' \
  || fail "HOME settings/credentials not restored"
pass "fresh container auto-restored workspace (hashes match), git state, modes, symlinks, HOME, gh + tunnel credentials"

ex b 'devbox-restore --yes' >/dev/null 2>&1 && fail "restore into non-empty workspace allowed without --force"
ex b 'echo local-newer > /workspace/projects/app/a.txt; devbox-restore --force --yes' >/dev/null 2>&1 || fail "forced restore failed"
ex b 'ls ~/.cache/devbox/pre-restore-*.tar.gz >/dev/null && tar -xzOf ~/.cache/devbox/pre-restore-*.tar.gz ./projects/app/a.txt | grep -q local-newer' \
  || fail "no safety copy before forced restore"
pass "restore refuses non-empty workspace; --force keeps a safety copy"

before_latest=$(ex b 'set -a; . ~/.config/devbox/s3.env; aws --endpoint-url $S3_ENDPOINT s3 cp s3://e2e/e2e/devbox/latest.json - ')
docker rm -f "$P-b" >/dev/null
start c "${ENVS[@]}" -e BACKUP_PASSPHRASE=wrong-passphrase
wait_log c "boot restore FAILED" 90 || fail "wrong passphrase did not fail the boot restore"
sleep 25
ex c 'echo junk > /workspace/junk.txt; devbox-backup' >/dev/null 2>&1 && fail "backup allowed after failed restore"
after_latest=$(ex c 'set -a; . ~/.config/devbox/s3.env; aws --endpoint-url $S3_ENDPOINT s3 cp s3://e2e/e2e/devbox/latest.json - ')
[[ "$before_latest" == "$after_latest" ]] || fail "latest snapshot pointer changed after a failed restore"
pass "failed boot restore pauses autobackup; good snapshot is never overwritten"
docker rm -f "$P-c" >/dev/null

start d "${ENVS[@]}" -e DEVBOX_AUTO_RESTORE=false
wait_log d "boot restore skipped" 60 || fail "DEVBOX_AUTO_RESTORE=false not honoured"
ex d 'devbox-backup' 2>&1 | grep -q "workspace is empty" || fail "empty workspace was uploaded"
pass "empty workspace is never uploaded without --force"

n=$(ex d 'set -a; . ~/.config/devbox/s3.env; aws --endpoint-url $S3_ENDPOINT s3 ls s3://e2e/e2e/devbox/snapshots/ | wc -l')
(( n <= 3 )) || fail "retention kept $n snapshots (limit 3)"
pass "retention keeps at most DEVBOX_BACKUP_KEEP snapshots ($n)"

ex d 'set -a; . ~/.config/devbox/s3.env; aws --endpoint-url $S3_ENDPOINT s3 cp s3://e2e/e2e/devbox/latest.json - | jq -r .key' | grep -q '\.tar\.gpg$' || fail "snapshot not encrypted"
ex d 'set -a; . ~/.config/devbox/s3.env; k=$(aws --endpoint-url $S3_ENDPOINT s3 cp s3://e2e/e2e/devbox/latest.json - | jq -r .key); aws --endpoint-url $S3_ENDPOINT s3 cp s3://e2e/e2e/devbox/$k - | grep -ac "APP_KEY=secret"' | grep -qx 0 || fail "plaintext secret found in stored snapshot"
pass "stored snapshot is encrypted (no plaintext .env content)"
echo "E2E BACKUP TEST PASSED"
