---
name: migrate-versioncontrol
description: 'Migrate an existing, running service to image versioning by digest (.version). Use when the user says "migrate <service> to versioncontrol", "pin the images of <service>", "put <server> under version control" or similar. Covers the fixed per-service schema (version running, version add, up, status, commit, version upgrade), choosing targets, the edge cases met on the production servers, and recording the state in chats/services/.'
---

# Migrate a Service to `.version` Pinning

## When to Use

A service under `$BASE_DIR/<service>/` runs with tag-based images and should get a `.version` file
that pins every image by digest (see "Image versions", "Wildcard targets" and "Protected backups"
in [CLAUDE.md](../../../CLAUDE.md)). Upgrading to newer upstream releases with research and
changelogs is [update-service](../update-service/SKILL.md), not this skill.

## Rules

- **Production.** Run only the commands of the schema below. Any extra command, read-only or not,
  needs the user's OK first. Allowed without asking: `git status --short` in the service and
  `./service.sh status` after an `up`. Never read `.env`; `.version` may be read and edited.
- **Stop and ask** on any exit code other than 0, any output that differs from the expectation,
  and any case below whose handling says so. No retry, no fix, no restore on your own.
- **Skip, never touch:** a service without a borg backup location (status `NO-BACKUP`); the same
  repo used as prod and dev with two tags (status `conflict`); only locally built images (status
  `no-images`).
- **Short names** for `version add`: up to 4 capital letters/digits without asking, longer only
  with the user's OK. Follow the names in use: `NC` nextcloud, `MDB` mariadb, `DB` the database of
  an app, `PG` postgres, `RD` redis, `VK` valkey, `ES` elasticsearch, `BS` bookstack, `TR` traefik,
  `AK` authentik, `MS` meilisearch, `TIKA` apache/tika, `NGX` nginx.
- **No extra backup** before `version add` + `up`: pinning the running digest changes nothing.
- **Compose image lines** are edited by hand only where the user allowed it.
- `version upgrade` always with `-y` (no terminal over ssh). Its old name `auto-upgrade` appears
  in older logs and runbooks and still works.

## Before the first service on a server

1. Banner of any `./service.sh` call: `[CORE] <version> (<commit>)`. If the controller has no
   `version` command or is behind the released one, ask, then `./controller.sh update`. A server
   with a second base dir (`dronedreams-services` on voyager and destiny) has its own controller
   to update.
2. `jq --version` must work (`version upgrade` and the Docker Hub client need it). If missing, stop:
   installing it is a system-wide change the user does.
3. Run commands that restart or back up a service under `flock /tmp/versioncontrol.lock` so two
   services on one server are never worked on at once.

Remote work from the workstation goes through `logs/run-remote.sh <server> <service> <label>
<dir> '<command>'` (log under `logs/<server>/<service>/`); `logs/version-add.sh` turns a
`version running` log into the `version add` calls. Subagent briefs: `logs/pipeline.md`
(schema), `logs/targets.md` (targets).

## Schema per service

1. `git status --short` — expected empty. Anything listed: stop and report; the user commits or
   decides. Exception: only ` M .gitignore` adding `.version-history.tsv` (written by `version
   running`/`search`) is fine.
2. `./service.sh version running` — one block per container with image and `running hash:
   sha256:…`.
3. Per running image: `./service.sh version add <NAME> <repo> <running tag> <running hash>`.
   Expected `[VERSION] Added <NAME> to .version` and `[VERSION] Replaced in docker-compose.yml`.
   Leave out locally built images (no registry, `tags: unknown` after a `curl: (22) … 404`); they
   are noted as `not pinned (build …)`. An image that runs as `repo@sha256:…` alone is pinned
   already; one that runs as `repo:tag@sha256:…` is not.
4. `./service.sh up` — containers recreated, no image download of note.
5. `./service.sh status` right away, and again after `sleep 180`. Healthy and stable: the same
   containers as in step 2, all `Up`, none `Restarting`, `unhealthy` or `health: starting`, images
   shown as `<repo>@<running hash>`, no uptime clearly below 3 minutes.
6. `git status --short` — expected ` M .gitignore`, ` M docker-compose.yml`, `?? .version`.
7. `./service.sh commit versioncontrol` — git commit plus borg backup `+commit: versioncontrol`,
   ending in `[BORG] Backup finished`. A borg warning about a file changed while read is fine at
   exit 0.
8. `./service.sh version upgrade -y` — ends with `[VERSION] Upgraded <service>`, `[VERSION]
   <service> is up to date`, or a rollback (`was rolled back` / `failed and so did the rollback`).
9. `./service.sh status` — whatever step 8 printed.

## Targets

`version add` sets the running tag as target. Change it only:

- **From the same service on another server** (nextcloud → nextcloud), never from the same repo in
  another service, never across a major version. Everything else goes into
  `chats/services/review.md` for the user.
- `latest` is accepted. Databases (postgres, mariadb, mysql, redis, valkey) follow only their
  major and never cross it automatically: `10.6` → `10`, `8.4.11` → `8`, `alpine3.19` → `alpine`,
  `13-alpine3.19` → `13-alpine`.
- **Images without a registry client** (everything not on Docker Hub, e.g. ghcr.io): "latest"
  means a wildcard keeping the tag's form, `*.*.*` or `v*.*.*`, never the tag `latest` (its
  version stays unreadable, as with paperless). Without a client the wildcard is found by counting
  up, so it stops at a gap in the numbering: authentik `2025.8.6` never reaches `2025.10`, and a
  tag with two numbers (`2026.8`) matches nothing. Such cases go to review.
- **Stale or missing major tags:** `linuxserver/mariadb:10` fails with `manifest.v1+prettyjws not
  supported`, `elasticsearch` has no tag `8`, zammad's `6`/`6.5` stopped moving. Use the wildcard
  of the major instead: `10.*.*`, `8.*.*`, `6.*.*`.
- Per target: `./service.sh version search <NAME> "<tag>"` first; it must print `hash: sha256:…`
  (exit 1 with a hash and `tags: unknown` is fine). Then `sed -i "s|^<NAME>_TARGET=.*|<NAME>_TARGET=<tag>|" .version`,
  then always `version upgrade -y` and `status`. The changed target is not committed separately:
  the next upgrade that upgrades commits it; until then note it as uncommitted.

## Edge cases met

- **Repo with `docker.io/` prefix** (`docker.io/library/postgres:16-alpine` in authentik,
  paperless, immich, netbox): `version add` with the repo as it runs, so the compose line is
  replaced; then strip the prefix in `.version`
  (`sed -i -e "s|_REPO=docker.io/library/|_REPO=|" -e "s|_REPO=docker.io/|_REPO=|" .version`)
  and run `version upgrade -y`. If it is up to date, the change stays uncommitted (note it).
- **`No image of <repo> found in docker-compose.yml`**: the compose line uses a variable
  (`${AUTHENTIK_IMAGE:-ghcr.io/goauthentik/server}:…`, zammad `${IMAGE_REPO}:${VERSION}`). Stop and
  ask; with the OK replace the line by `image: ${<NAME>_REPO}@${<NAME>_CURRENT}` with `sed`, show
  `grep -n image: docker-compose.yml`, then go on with `up`.
- **`Permission denied`** writing in the service dir (`sed: couldn't open temporary file`,
  `.version-history.tsv`): stop. After the user fixed it, remove a half-added block
  (`sed -i "/^<NAME>_/d" .version`), run `version running` again and repeat the `version add`.
- **Restart after `up`** (euro-office: uptime 2 min at the 3-min check) or **a container that did
  not run before** (nextcloud on mayfly: `nextcloud-fulltextsearch-live`): stop before the commit;
  state `pinned, not committed`.
- **`health: starting` at the 3-min check** (termix guacd): ask for a later `status`; go on once
  it is `healthy`. guacd needs almost the 300 s `version upgrade` waits, so an upgrade can roll
  back for that alone; `--ignore-health` only with the user's OK.
- **Containers without a health state** (zammad, webshop, db containers): `version upgrade`
  counts a running one as healthy. Note "only the start of the containers was checked".
- **Borg repository missing** (traefik-falcon: `Repository … does not exist`): the commit is made
  but its backup fails, and `version upgrade` aborts with `The borg repository is not reachable`.
  Stop. Once the repository exists: `BORG_WARNINGS_OK=1 ./service.sh borg backup "+commit:
  versioncontrol"`, then `version upgrade -y`.
- **Borg repository shared with another server** (authentik-proxy on destiny and voyager): the
  backup of the commit fails because `+commit: versioncontrol` exists already. Do not run
  `version upgrade`; state `pinned, backup failed`.
- **Target tag gone from the registry** (`bitnami/elasticsearch:8.12.2`,
  `minio/minio:RELEASE.…`: `not found in the registry` right after the first check):
  `version upgrade` aborts before changing anything. Report; the user decides the new repo/tag.
- **Image moved to another repo** (zammad: `bitnami/elasticsearch` → `elasticsearch`, only with
  the user's OK for the compose block: data path `/usr/share/elasticsearch/data`, environment as
  upstream; upstream asks for a chown of the data dir, on akadis it ran without one): set
  `<NAME>_REPO` to the new repo and empty `<NAME>_CURRENT` in `.version`, run `./service.sh
  down:up` (not `up`; it fills `CURRENT`), check `status` after 3 min, then `version upgrade -y`.
- **Private Docker Hub repos** (connectaregensburg/*): `version running` prints `curl: (22) …
  404` and `tags: unknown`; the digest is still found. Fine.
- **Locally built images in the stack** (bambuddy): the pull step of `version upgrade` fails with
  `pull access denied`. With the user's OK add `pull_policy: never` to those services. The upgrade
  then rebuilds them, and a rollback restores files only, not built images: report the state of
  every container after it.
- **Upgrade fails and rolls back** (openslides 4.2 → 4.3 on alko and akadis: new database layout,
  `postgres_password` secret, `relation "version" does not exist`): check `status` shows the old
  digests, state `pinned, auto-upgrade failed` with the reason. Do not retry; every further upgrade
  fails the same way until the user migrated by hand.
- **Containers of the project without a line in the compose file** (it-tools-example): leave out,
  note them.

## Record

In `chats/services/<server>.md`, per service:

```
- **<service>** — running — versioncontrol migration status: <status>
  - <NAME> <repo> - pinned, target <target>
  - <repo> - not pinned (build <Dockerfile>)
  - note: …
```

Statuses: `finished`, `pinned, targets in review`, `pinned, not committed`, `pinned, backup
failed`, `pinned, auto-upgrade failed`, `conflict`, `no-images`, `NO-BACKUP`. Notes say what an
upgrade moved (from → to version, backup name `+upgrade-from-…`), what was only start-checked, and
any uncommitted change as a `note:` containing "uncommitted". Then run `python3
logs/services-csv.py`.
