#!/usr/bin/env bash
# Runtime smoke test for a built image: tests/smoke.sh IMAGE
# Verifies non-root runtime, writable HOME/workspace, services, health, shutdown.
set -Eeuo pipefail
IMG="${1:?usage: tests/smoke.sh IMAGE}"
NAME="devbox-smoke-$$"
PORT="${SMOKE_PORT:-18080}"
fail() { echo "FAIL: $*" >&2; docker logs "$NAME" 2>&1 | tail -40 >&2 || true; exit 1; }
pass() { echo "ok   $*"; }
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

[[ "$(docker image inspect "$IMG" --format '{{.Config.User}}')" == "10001:10001" ]] || fail "image USER is not 10001:10001"
pass "image USER 10001:10001"

docker run --rm --entrypoint bash "$IMG" -c '
  set -e
  [[ "$(id -u):$(id -g)" == "10001:10001" ]]
  touch "$HOME/.probe" /workspace/.probe /tmp/.probe
  git config --global user.name smoke
  mkdir -p "$HOME/.vscode/cli" "$HOME/.config/gh" "$HOME/.local/bin"
  npm install -g --silent is-number >/dev/null
  for t in go php composer node pnpm bun python3 pipx git gh zsh tmux nvim aws code code-server redis-server psql mysql sqlite3 supervisord; do
    command -v "$t" >/dev/null || { echo "missing $t"; exit 1; }
  done
  for e in bcmath intl gd redis pcntl pdo_pgsql pdo_mysql pdo_sqlite zip; do
    php -m | grep -qix "$e" || { echo "missing php ext $e"; exit 1; }
  done' || fail "toolchain / writable paths"
pass "uid, writable HOME/workspace/tmp, git config, npm -g, toolchain, php extensions"

docker run --rm --user 12345:0 -e PASSWORD=x --entrypoint bash "$IMG" -c \
  'touch "$HOME/.probe" && touch /workspace/.probe' || fail "arbitrary uid with gid 0 cannot write HOME/workspace"
pass "arbitrary uid (12345:0) can write HOME and workspace"

docker run --rm "$IMG" >/dev/null 2>&1 && fail "container started without PASSWORD"
pass "refuses to start without PASSWORD"

PW='s3cr"et pa:ss #{x} $HOME'
docker run -d --name "$NAME" --cap-drop ALL --security-opt no-new-privileges \
  -p "127.0.0.1:${PORT}:8080" -e PASSWORD="$PW" "$IMG" >/dev/null
for _ in $(seq 1 60); do
  curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1 && break; sleep 2
done
curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null || fail "healthz not reachable"
pass "code-server healthz"

code=$(curl -s -o /dev/null -w '%{http_code}' --data-urlencode "password=$PW" "http://127.0.0.1:${PORT}/login")
[[ "$code" == "302" ]] || fail "login with correct password returned $code"
pass "login with special-character password"

docker exec "$NAME" bash -c '[[ "$(cat /proc/1/comm)" == supervisord ]]' || fail "PID 1 is not supervisord"
docker exec "$NAME" bash -c '! ps -eo uid= | tr -d " " | grep -vqx 10001' || fail "a process runs as a non-developer user"
cs_pid=$(docker exec "$NAME" pgrep -o -f /usr/lib/code-server)
docker exec "$NAME" bash -c "! tr '\0' '\n' < /proc/$cs_pid/environ | grep -q '^PASSWORD='" || fail "PASSWORD visible to code-server processes"
docker exec "$NAME" bash -c "! tr '\0' '\n' < /proc/1/environ | grep -q '^PASSWORD='" || fail "PASSWORD visible in /proc/1/environ"
docker logs "$NAME" 2>&1 | grep -qF "$PW" && fail "password printed in logs"
pass "supervisord PID 1, all processes non-root, password not in env or logs"

for _ in $(seq 1 10); do docker exec "$NAME" redis-cli ping 2>/dev/null | grep -q PONG && break; sleep 1; done
docker exec "$NAME" redis-cli ping | grep -q PONG || fail "redis not running"
pass "redis-server"

for _ in $(seq 1 30); do
  [[ "$(docker inspect "$NAME" --format '{{.State.Health.Status}}')" == healthy ]] && break; sleep 3
done
[[ "$(docker inspect "$NAME" --format '{{.State.Health.Status}}')" == healthy ]] || fail "docker health is not healthy"
pass "docker HEALTHCHECK healthy"

start=$(date +%s)
docker stop -t 30 "$NAME" >/dev/null
took=$(( $(date +%s) - start ))
(( took < 30 )) || fail "shutdown took ${took}s (SIGTERM not handled)"
pass "graceful shutdown in ${took}s"
echo "SMOKE TEST PASSED"
