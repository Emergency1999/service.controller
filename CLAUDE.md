# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## ⚠️ Production environment

This is the **production environment server**. Be very sure not to break things. **Never run
system-wide commands** (package installs, systemctl, firewall changes, reboots, anything under
`/etc`, anything that touches another user's files) without **explicit user instruction**. When in
doubt, ask first. Docker / borg / git operations scoped to a service or to `$BASE_DIR` are fine.

## Local Claude Code settings

[.claude/settings.json](.claude/settings.json) ships with the repo and is shared across all installs.
Put **local-only** changes (extra allow/deny rules, env vars, hooks) into `.claude/settings.local.json`
in `$BASE_DIR` — it is gitignored and won't conflict on `./controller.sh update`.

### How `CLAUDE.md` and `.claude/` reach `$BASE_DIR`

Both are **symlinks** created by [init.sh](init.sh) / [update.sh](update.sh):

- `$BASE_DIR/CLAUDE.md` → `$BASE_DIR/.controller/CLAUDE.md` (this file)
- `$BASE_DIR/.claude` → `$BASE_DIR/.controller/.claude`

That way Claude Code at `$BASE_DIR` automatically picks up the project doc, the shared
`settings.json`, the project commands in `.claude/commands/`, and the skills in `.claude/skills/`
straight from the controller repo. A `./controller.sh update` (which `git pull`s `.controller/` and
re-runs [update.sh](update.sh)) propagates any changes to all installs — no manual sync.

## Repository layout

`$BASE_DIR` (the outer dir, where this `CLAUDE.md` is symlinked) is **not** a git repo. It contains
the cloned controller repo at `.controller/` (this directory — remote
`github.com:Vereine-Vereint/service.controller.git`) plus one service subfolder per running service.

Code changes that ship to all installs go inside `.controller/`. The outer `controller.sh` and
`.env` are install-local and aren't versioned by the controller repo. Each service folder is its own
small git repo.

## Architecture

Two-layer bash dispatch on top of `docker compose` and `borgbackup`:

### Top-level controller (services-wide)

The outer `controller.sh` is a thin shim that sources the outer `.env` then
[controller.sh](controller.sh). Handles operations that span all services:
`create <name> <template>`, `import <name...>`, `remove <name...>`, `rename <old> <new>`,
`update`. Also exposes controller-scoped `borg` subcommands via
[controller_borg.sh](controller_borg.sh) — `borg change-passphrase`, `borg autobackup-now`
(iterates every service in `$BASE_DIR/.backup` with 5 retry rounds), `borg list-repos`
(enumerates every repo under `$BORG_REPO_BASE`, flagging orphans), `borg delete-repo <name>`
(wipes a repo after listing recent archives and asking the operator to retype the name).

### Per-service controller

Each service directory has its own `service.sh` that sources `../.controller/core.sh`
(see [../test/service.sh](../test/service.sh)). [core.sh](core.sh) wires in three
subcommand modules:

- [docker.sh](docker.sh) — `up`, `down`, `start`, `stop`, `restart`, `pull`,
  `build`, `logs`, `status`, `exec`, `delete-volumes`. All operate on `docker compose -p $SERVICE_DIR_NAME`.
- [borg.sh](borg.sh) + [borg_commands.sh](borg_commands.sh)
   — `init`, `backup`, `restore-fresh`, `restore-diff`, `export`, `list`, `prune`, `compact`, `break-lock`,
  plus `autobackup-enable/disable/now`. Each service has its own borg repo at `$BORG_REPO_BASE/<service>`.
- [git.sh](git.sh) — `git commit <message>` (commits + creates a borg backup).

### Cross-cutting concepts

- **Command chaining with `:`** — `./service.sh up:logs` runs `up` then `logs`. Implemented in
  [core.sh](core.sh) `main()` and recursively in `cmd_docker`, `cmd_git`.
- **Global subcommands** — modules register top-level aliases via `add_global_subcommand`, so
  `./service.sh up` dispatches to `cmd_docker up`. Names must not collide across modules (enforced at load).
- **Attachment hooks** — services may define bash functions `att_setup`, `att_configure`, `att_pre-start`,
  `att_post-start`, `att_pre-stop`, `att_post-stop`, `att_post-setup`, `att_post-configure`, `att_pull`,
  `att_remove`. Called by `docker_up/down/start/stop/restart/pull` via `exec_attachment` in
  [func_exec.sh](func_exec.sh).
- **Autobackup state** — list of services enrolled in nightly cron backup lives in `$BASE_DIR/.backup`
  (one service name per line). `docker_up` auto-enables, `docker_down` auto-disables. Legacy
  `BORG_AUTOBACKUP_SERVICES` env var is auto-migrated on first read.
- **Restore preserves `.git`** — `borg restore-*` moves `.git` to `$BASE_DIR/.tmp/<service>/.git` before
  wiping and restores it after, so service-level git history survives a fresh restore. Pass `--clean-git`
  to skip the move-aside dance and let the backup's `.git` win.
- **Traefik per-service conf** — if a service has a `traefik/` subdirectory containing file-provider
  YAMLs (middlewares, routers, services beyond what compose labels can express),
  [traefik_link.sh](traefik_link.sh) bind-mounts it onto `$BASE_DIR/.traefik/<service>/` on
  `docker_up` and unmounts on `docker_down`. The traefik service mounts `$BASE_DIR/.traefik/` into
  `/etc/traefik/conf/` (watched by traefik's file provider, see
  [templates/traefik/traefik.yml](templates/traefik/traefik.yml)), so files appear at
  `/etc/traefik/conf/<service>/<file>.yml`. Uses `sudo mount --bind` rather than symlinks because
  Docker bind mounts don't follow symlinks across mount boundaries. Mounts are non-persistent across
  reboot, but the next `up` re-establishes them idempotently. Simple host-rule routing should still
  use compose labels — the `traefik/` subdir is for middlewares (e.g. authentik forwardAuth) and
  conf that labels can't express.
- **Template generation** — [func_generate.sh](func_generate.sh) `generate <template> <output>`
  expands `${VAR}` references using `envsubst`; used by services that need dynamic config files written
  into `generated/` before container start.
- **Version banner** — `[CORE] $CORE_VERSION ($(git rev-parse --short HEAD))` is printed on every run.
  Bump [version.sh](version.sh) when releasing.

## Common workflows

```bash
# Run the controller (outer)
./controller.sh help
./controller.sh create <name> [template]   # template defaults to "default"
./controller.sh import <name...>           # restore service(s) from latest borg backup
./controller.sh remove <name...>           # prompts for stop+backup before deleting
./controller.sh rename <old> <new>         # moves service folder + borg repo, prompts to stop+start
./controller.sh borg list-repos            # list all borg repos (incl. orphaned)
./controller.sh borg delete-repo <name>    # wipe a borg repo after confirmation
./controller.sh update                     # git pull .controller/ + run update.sh

# Run a service (inside e.g. test/)
./test/service.sh help
./test/service.sh up
./test/service.sh logs
./test/service.sh up:logs                  # chain
./test/service.sh borg backup <name>
./test/service.sh borg restore-fresh latest

# Debug a service script in VSCode: use the bashdb launch config in .vscode/launch.json
# (pointed at test/service.sh; change `program` to debug other services).
```

There is no build, lint, or automated test harness — validation is manual (the dev sandbox uses a
`test/` dummy service).

## Service templates

[templates/](templates/) holds starter docker-compose stacks
(default, traefik, bookstack, euro-office, karakeep, nextcloud, onlyoffice, openslides, pretix, wishlist, wordpress, zammad).
`create` copies a template into a new service dir, `chmod +x service.sh`, and inits a git repo.

To research and set up brand-new software that has no template yet, use the
[create-service skill](.claude/skills/create-service/SKILL.md) — it researches official
docker-compose sources, scaffolds via `create`, writes a `SETUP.md`, and hands off to
standardize-service.

To turn a proven running service into a new template — or refresh an existing template from the
live service (version bumps, structural changes) — use the
[templatize-service skill](.claude/skills/templatize-service/SKILL.md). It copies only the
allowlisted generic files and strips all secrets and data (never `volumes/`, `generated/`, `.git/`,
or real `.env` values).

When adding or editing a template, follow the conventions in
[.claude/skills/standardize-service/SKILL.md](.claude/skills/standardize-service/SKILL.md):
no `container_name`, ports commented out, two-network model (`default` + external `traefik`), traefik labels
only on the webserver, image versions in `.env`, `restart: unless-stopped`, volumes under `./volumes/`,
`env_file` only when actually needed.

## Conventions

- Bash with `set -e` at script entry; modules toggle `set +e` only around commands whose failure must be
  handled explicitly (e.g. borg restore rollback, autobackup retry loop).
- Logging prefixes: `[CONTROLLER]`, `[CORE]`, `[BORG]`, `[CRON]`. Match the existing prefix for new output.
- All borg commands run under `sudo -E` (need root to read all service files); `BORG_RSH` has `~`
  expanded to `/home/$USER` because sudo strips `$HOME`.
- Per-service `.env` is loaded with `set -o allexport` so values become available to `docker compose`.
- The outer `.env` contains a real `BORG_PASSPHRASE` — never commit changes that move it into the
  `.controller/` repo or templates.
