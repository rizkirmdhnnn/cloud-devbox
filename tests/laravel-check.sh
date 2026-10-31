#!/usr/bin/env bash
# Laravel stack check inside the devbox image: tests/laravel-check.sh IMAGE
# New project, migrations, database + Redis queues with a worker, scheduler,
# Vite build, and HTTP preview through code-server's /proxy/<port>/.
set -Eeuo pipefail
IMG="${1:?usage: tests/laravel-check.sh IMAGE}"
NAME="devbox-laravel-$$"
fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --name "$NAME" -e PASSWORD=x "$IMG" >/dev/null
for _ in $(seq 1 60); do docker exec "$NAME" devbox-healthcheck 2>/dev/null && break; sleep 2; done

docker exec -i "$NAME" bash -s <<'SH' || fail "laravel lifecycle"
set -Eeuo pipefail
ok() { echo "ok   $*"; }
cd /workspace/projects
composer create-project laravel/laravel app --no-interaction --quiet
cd app
ok "composer create-project ($(php artisan --version))"

php artisan migrate --force --no-interaction >/dev/null
ok "migrations (sqlite)"

mkdir -p app/Jobs
cat > app/Jobs/Ping.php <<'PHP'
<?php
namespace App\Jobs;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Queue\Queueable;
class Ping implements ShouldQueue {
    use Queueable;
    public function __construct(public string $tag) {}
    public function handle(): void { file_put_contents(storage_path("ping-{$this->tag}.txt"), "processed"); }
}
PHP

php artisan tinker --execute='App\Jobs\Ping::dispatch("db");' >/dev/null
timeout 30 php artisan queue:work database --once --stop-when-empty >/dev/null
test -f storage/ping-db.txt
ok "database queue: dispatch + worker"

redis-cli ping | grep -q PONG
php -r 'exit(extension_loaded("redis") ? 0 : 1);'
sed -i 's/^REDIS_CLIENT=.*/REDIS_CLIENT=phpredis/' .env
php artisan tinker --execute='Illuminate\Support\Facades\Queue::connection("redis")->push(new App\Jobs\Ping("redis"));' >/dev/null
nohup php artisan queue:work redis --sleep=1 > /tmp/worker.log 2>&1 &
W=$!
for _ in $(seq 1 20); do test -f storage/ping-redis.txt && break; sleep 1; done
test -f storage/ping-redis.txt
kill -TERM "$W"; for _ in $(seq 1 10); do kill -0 "$W" 2>/dev/null || break; sleep 1; done
! kill -0 "$W" 2>/dev/null
ok "redis queue (phpredis): long-running worker processed job and stopped on SIGTERM"

php artisan tinker --execute='Cache::store("redis")->put("k","v",60); echo Cache::store("redis")->get("k");' | grep -q v
ok "redis cache store"

php artisan schedule:list >/dev/null
php artisan schedule:run >/dev/null
ok "scheduler (schedule:list / schedule:run)"

npm install --silent --no-fund --no-audit >/dev/null 2>&1
npm run build >/dev/null 2>&1
ok "npm install + vite build"

nohup php artisan serve --host=127.0.0.1 --port=8000 > /tmp/serve.log 2>&1 &
for _ in $(seq 1 20); do curl -fs -o /dev/null http://127.0.0.1:8000/ && break; sleep 1; done
test "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/)" = 200
ok "php artisan serve on :8000"
SH

code=$(docker exec "$NAME" bash -c 'c=$(mktemp); curl -s -c "$c" -o /dev/null --data-urlencode password=x http://127.0.0.1:8080/login; curl -s -b "$c" -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/proxy/8000/')
[[ "$code" == 200 ]] || fail "code-server /proxy/8000/ returned $code"
echo "ok   preview via code-server /proxy/8000/ (authenticated)"
anon=$(docker exec "$NAME" curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/proxy/8000/)
[[ "$anon" != 200 ]] || fail "preview reachable without login"
echo "ok   preview requires code-server login ($anon without session)"
docker stats --no-stream --format 'memory in use: {{.MemUsage}}' "$NAME"
echo "LARAVEL CHECK PASSED"
