# Cloud DevBox v1

A personal cloud development workstation in one Docker image. It runs as a
non-root user on a PaaS that has **no persistent volume**. You reach it from a
browser (code-server) or from desktop VS Code (Remote Tunnels). Work survives
container replacement because it is snapshotted to S3-compatible storage
automatically.

Built and published by GitHub Actions to `ghcr.io/<owner>/cloud-devbox`.

## What's inside

| Area | Tools |
|---|---|
| IDE | code-server (browser VS Code), VS Code CLI for Remote Tunnels |
| Languages | Go, PHP 8.3 + Composer, Node.js 24 + npm/pnpm/Bun, Python 3.12 + pipx |
| Laravel | PHP ext: bcmath, intl, gd, redis, igbinary, opcache, pcntl, pdo_pgsql/mysql/sqlite, zip; local Redis server |
| CLI | git, gh, zsh, tmux, Neovim, jq, yq, psql, mysql, redis-cli, sqlite3, AWS CLI v2 |
| Runtime | supervisord (PID 1, non-root): code-server, Redis, boot restore, autobackup, tunnel |

All downloads are pinned and checked against their sha256 (see `ARG`s at the
top of the `Dockerfile`). The base image is pinned by digest.

## Runtime model

- The image runs as `developer` (UID/GID 10001). Nothing needs root at
  startup or at runtime: there is no `sudo`, `apt`, `chown` or `sshd`.
- `HOME` and `/workspace` are also group-0 writable, so a platform that forces
  an arbitrary UID with GID 0 still works. If HOME is not writable at all, the
  entrypoint falls back to `/tmp/home`.
- The entrypoint writes the code-server config and moves secrets
  (`PASSWORD`, S3 keys, `BACKUP_PASSPHRASE`) into private files. It then
  `exec`s supervisord without them. IDE terminals, extensions and your project
  code never see these variables. `docker exec` sessions still do, because
  Docker gives them the container's original environment.
- Only port `8080` (or `$PORT`) is exposed. TLS is terminated by the PaaS.
- Global installs work without root: `npm i -g` goes to `~/.npm-global`,
  `pipx`/`go install` go to `~/.local/bin` and `~/go/bin`. These live in HOME
  and are **not** backed up. Reinstall them, or keep them in a project.

## Persistence: what survives what

There is no volume, so the container filesystem disappears on redeploy,
restart onto a new instance, or scale-to-zero.

| Data | Where it lives | Survives container replacement? |
|---|---|---|
| Committed code | GitHub | Yes, push often |
| Uncommitted work in `/workspace` | S3 snapshot | Yes, up to the last snapshot |
| `.gitconfig`, zsh history, code-server settings + extensions | S3 snapshot | Yes |
| `gh` login, tunnel login, `~/.ssh` | S3 snapshot, **only if `BACKUP_PASSPHRASE` is set** | Yes, encrypted |
| `node_modules`, `vendor`, `.venv`, caches | Not backed up | Rebuilt with `npm i` / `composer install` |
| Local Redis data | Memory only | No (dev queue/cache only) |
| Databases | Use Skalo Postgres (or another external DB), or SQLite inside `/workspace` | Yes |
| Secrets | PaaS environment variables | Yes |

How the automatic cycle works:

1. **Boot:** if `/workspace` is empty, the latest snapshot is restored in the
   background. code-server is reachable immediately and files appear once the
   restore finishes (`devbox-status` shows progress).
2. **While running:** every `DEVBOX_BACKUP_INTERVAL` seconds (default 900) a
   snapshot is uploaded. Nothing is uploaded if nothing changed.
3. **Shutdown (SIGTERM):** a final snapshot is uploaded before exit.

Safety rules:

- Automatic backup stays paused until the boot restore has succeeded, or has
  confirmed there is nothing to restore. An empty fresh container never
  replaces a good snapshot. An empty workspace is never uploaded without
  `--force`.
- **Data-loss window:** if the container is killed without SIGTERM, or the
  platform's grace period is shorter than the upload, you lose at most the
  changes made since the last snapshot (default 15 minutes). Run
  `devbox-backup` before risky operations and redeploys.

## Deploying on Skalo (or any Docker PaaS)

1. Create an app from a **Docker image**: `ghcr.io/<owner>/cloud-devbox:latest`.
   Prefer a release tag (`:1.0.0`) or `sha-xxxxxxx` for a stable workstation.
2. Private GHCR package: give the platform registry credentials. Username is
   your GitHub username. Password is a **classic PAT with only `read:packages`**.
   Never give it a token with write access.
3. HTTP port **8080**, HTTPS on, health check `GET /healthz`.
4. **Exactly one instance. Disable autoscaling and scale-to-zero.** A devbox
   is stateful: two instances would show two different workspaces, and
   scale-to-zero deletes the filesystem. It also cannot see Tunnel traffic,
   so the box could be stopped while you work over a Tunnel.
5. Set environment variables and secrets (see `.env.example`):
   - Required: `PASSWORD` (or `HASHED_PASSWORD`).
   - Backup: `S3_ENDPOINT`, `S3_BUCKET`, `S3_PREFIX`, `AWS_ACCESS_KEY_ID`,
     `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION`, `BACKUP_PASSPHRASE`.
   - Use a dedicated S3 bucket or prefix with a key limited to it. Add a bucket
     lifecycle rule as a second retention guard.
6. Set the shutdown grace period as high as the platform allows (60s or more)
   so the final backup can finish.

To use a hashed password (code-server accepts argon2):

```bash
echo -n 'your-password' | npx argon2-cli -e   # set the output as HASHED_PASSWORD
```

## Access

**Browser:** open the app URL and log in with the password. Login attempts
are rate limited by code-server.

**Desktop VS Code (Remote Tunnels, no inbound port needed):**

```bash
devbox-tunnel login     # in a code-server terminal; prints a GitHub device code
```

Open the printed URL, enter the code, and approve. The tunnel then starts
under the supervisor as `TUNNEL_NAME` (default `cloud-devbox`). On your
Mac/Windows/Linux VS Code, install **Remote - Tunnels** and run **Remote-Tunnels:
Connect to Tunnel…**. Port forwarding works there: `localhost:8000` on your
laptop reaches `php artisan serve` in the devbox.

- With `BACKUP_PASSPHRASE` set, the tunnel login is included in the encrypted
  snapshot, so a recreated container reconnects on its own.
- Without it, run `devbox-tunnel login` again after each redeploy.
- `devbox-tunnel status` shows the state, `devbox-tunnel logout` removes it.

**SSH:** not provided. It needs TCP ingress, and an sshd is not worth running
in a non-root container when Tunnels cover the use case.

## Laravel workflow

```bash
cd /workspace/projects
composer create-project laravel/laravel app && cd app
php artisan migrate
composer run dev        # serve + queue:listen + logs + vite, in one terminal (use tmux to keep it running)
```

- **Database.** SQLite (the Laravel default) works out of the box and lives in
  the snapshot. For Postgres use a managed database such as Skalo Serverless
  Postgres: put its `DB_*` values in the project `.env`. That file is part of
  the encrypted snapshot.
- **Queue / cache / session on Redis.** Local Redis runs on `127.0.0.1:6379`
  (`REDIS_CLIENT=phpredis`). Set `QUEUE_CONNECTION=redis` and/or
  `CACHE_STORE=redis`. Redis data is ephemeral. Use the `database` queue
  driver if pending jobs must survive a redeploy.
- **Workers and scheduler.** Run `php artisan queue:work` and
  `php artisan schedule:work` in tmux windows (`tmux new -s app`). Workers stop
  cleanly on SIGTERM.
- **Preview in the browser without a Tunnel.** code-server proxies
  `https://<app>/proxy/8000/`. It requires the code-server login, so the
  preview is private. Laravel generates absolute URLs, so set
  `APP_URL=https://<app>/proxy/8000` and `ASSET_URL=https://<app>/proxy/8000`,
  and use `npm run build` (or `npm run build -- --watch`) instead of the Vite
  dev server. Vite HMR works best over the Tunnel port forward.
- **Wildcard subdomains.** If the platform supports wildcard DNS and TLS, set
  `PROXY_DOMAIN=dev.example.com` to get `8000.dev.example.com`.

## Backup and restore commands

```bash
devbox-status                 # services, boot-restore state, last backup
devbox-backup                 # snapshot now (skips if unchanged)
devbox-backup --force         # snapshot even if unchanged / workspace empty / restore failed
devbox-restore --list         # list snapshots
devbox-restore                # restore latest into an EMPTY workspace
devbox-restore --force snapshots/20261031T070000Z.tar.gpg
                              # merge over a non-empty workspace (safety copy kept in ~/.cache/devbox)
svc status                    # supervisorctl: status/start/stop/restart code-server|redis|tunnel|autobackup
```

Snapshot format: `s3://$S3_BUCKET/$S3_PREFIX/snapshots/<UTC>.tar[.gpg]`, plus
a `latest.json` pointer that records the sha256. Restores verify the checksum
and extract into a staging directory first. Archive members with `..` or
absolute paths are rejected.

## CI/CD

`.github/workflows/publish-ghcr.yml`:

| Event | What happens |
|---|---|
| Pull request | Build amd64 + smoke test + vulnerability report. Nothing is published. |
| Push to `main` | Same checks, then publish `:main`, `:latest`, `:sha-xxxxxxx` (amd64) |
| Tag `v1.2.3` | Same checks, then publish `:1.2.3`, `:1.2`, `:sha-…` for **amd64 + arm64** |
| Manual run | `arm64` input adds the arm64 build |

- The workflow uses the built-in `GITHUB_TOKEN` (`packages: write` only on the
  build job). No personal tokens are stored in GitHub.
- Actions are pinned to commit SHAs.
- The workflow publishes images only. Redeploy on the PaaS (or enable its
  image auto-update) to roll out.

```bash
git tag v1.0.0 && git push origin v1.0.0   # release a pinned, multi-arch image
```

## Local build and tests

```bash
docker buildx build --platform linux/amd64 -t cloud-devbox:dev --load .
tests/smoke.sh cloud-devbox:dev            # non-root, services, health, shutdown
tests/e2e-backup.sh cloud-devbox:dev       # disposable S3: auto restore/backup, encryption, guards
tests/laravel-check.sh cloud-devbox:dev    # Laravel: migrations, db + redis queues, scheduler, vite, preview
```

## Updating pinned versions

Each tool has a version `ARG` plus one sha256 `ARG` per architecture in the
`Dockerfile`. Update them together. Where to find the values:

- **Go:** `https://go.dev/dl/?mode=json`
- **Node:** `SHASUMS256.txt`
- **VS Code CLI:** `https://update.code.visualstudio.com/api/update/cli-alpine-x64/stable/latest` (`sha256hash`)
- **code-server, AWS CLI:** download and run `sha256sum`
- **Composer:** `https://getcomposer.org/download/<v>/composer.phar.sha256sum`

## Troubleshooting

| Symptom | Check |
|---|---|
| Container exits immediately | Logs say `set PASSWORD or HASHED_PASSWORD` |
| Browser shows a blank or broken editor | The platform proxy must allow **WebSocket** upgrades and long idle connections |
| Workspace is empty after redeploy | `devbox-status`. `restore: running` means it is still restoring. `failed` means S3 settings or `BACKUP_PASSPHRASE` changed; fix them and run `devbox-restore`. |
| `refusing to overwrite the latest snapshot` | Boot restore failed. Run `devbox-restore`, or `devbox-backup --force` if the current workspace is the one to keep. |
| S3 errors like `SignatureDoesNotMatch` or `InvalidRequest` | Check `AWS_DEFAULT_REGION` and try `S3_FORCE_PATH_STYLE=true/false` |
| Tunnel not running | `devbox-tunnel status`. Run `devbox-tunnel login` once per container (or once ever, with `BACKUP_PASSPHRASE`). |
| Process logs | All services log to the container stdout (PaaS log viewer) |

## Limitations

- Single instance only. No Docker-in-Docker, privileged mode or systemd.
- Work since the last snapshot is lost on a hard kill (see the data-loss window).
- Local Redis is ephemeral. Run databases that matter outside the container.
- Platform features this depends on and must be verified per platform:
  WebSocket support, fixed single instance with scale-to-zero disabled,
  shutdown grace period, and outbound internet access.
