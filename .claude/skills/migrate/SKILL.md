---
name: migrate
description: 'Migrate an existing service running on another host into this server''s controller-managed layout under $BASE_DIR. Use when the user says "migrate <service> from <host>", "move the old <thing> over", or similar. Covers identification, read-only inventory of the old deployment, schema adaptation, user-run data copy, and start-up verification.'
---

# Migrate an Existing Service into `$BASE_DIR`

## When to Use

The user wants to bring a service that currently runs on another host (docker-compose, plain
docker, systemd, bare files — anything) into this server's controller-managed layout under
`$BASE_DIR`.

No existing deployment to move — just new software to set up from scratch? Use
[create-service](../create-service/SKILL.md) instead.

## Process at a glance

1. **Identify** the service. Pick a template if one fits; otherwise lean on the
   [standardize-service](../standardize-service/SKILL.md) skill for the general shape.
2. **Inventory** the old deployment over SSH using **read-only** commands only.
   Ask clarifying questions whenever the old layout is non-obvious — it may not even be docker.
3. **Plan** the migration in plan mode. Show the proposed new files and the exact commands the
   user will run for data copy.
4. **Scaffold + adapt** new-side files (`./controller.sh create` + edits per template /
   standardize-service). Claude does this.
5. **User-run data migration.** Claude asks the user to execute `rsync`/`scp`/database-dump
   commands. Claude does **not** execute them.
6. **Verify + finalize + start.** Claude sanity-checks the copied data, applies any post-start
   fix-ups (e.g. `trusted_proxies`, runtime config), brings the stack up, and tails logs.

Execute via the step-by-step [CHECKLIST.md](CHECKLIST.md) — tick it top-to-bottom; the phase
sections below hold the rules and context each step references.

## Rules of engagement (read these before doing anything)

### Old system — Claude is read-only

On the source host Claude **only inspects**. Acceptable: `ls`, `cat`, `stat`, `du`, `df`,
`docker ps`, `docker inspect`, `docker exec <c> env`, reading config files, viewing logs.
**Never** stop containers, edit files, `mysqldump`-to-file, kill processes, change DNS, change
firewall, restart anything. The migration must leave the old system byte-for-byte unchanged so it
remains a working rollback.

### Do NOT stop the old stack as part of the migration

The previous incarnation of this skill did `docker compose down` on the source before copying.
**That was wrong.** Migration is now strictly a non-destructive copy. The old stack keeps
serving traffic until DNS is flipped (or until the user manually shuts it down later, on their
own decision and clock). Implications:

- Data is copied **live**. For file trees this is fine; rsync may need a final pass after
  initial bulk transfer to catch deltas.
- Live databases need a logical dump (`mysqldump`, `pg_dump`, etc.), **not** a file-level rsync
  of `/var/lib/mysql` — file copies of an actively-written DB can be inconsistent or corrupt.
- After the new stack comes up but before DNS flips, the **old stack is still authoritative**.
  Any user writes between data-copy and DNS-flip happen only on the old side and will be lost
  unless you do a second sync (or a brief maintenance window) at cutover time.

### Data migration commands — user runs them

Even though `rsync remote:/path local:/path` is read-only on the source side, the user runs all
data-migration commands themselves. Claude provides the exact command, including flags. This
covers `scp`, `rsync`, `ssh root@old 'mysqldump ... | gzip' > dump.sql.gz`, etc. Hands stay on
the user's keyboard for anything that crosses the host boundary with data.

### New system — Claude can act freely

Per the project [CLAUDE.md](../../../CLAUDE.md), docker / borg / git operations scoped to a
service or to `$BASE_DIR` are fine. Claude scaffolds, edits, brings up, and verifies the new
service without further confirmation.

## Phase 1 — Identify the service and pick a template

```bash
ls $BASE_DIR/.controller/templates/
```

If a template fits the service (`nextcloud`, `bookstack`, `wordpress`, `pretix`, …), use it via
`./controller.sh create <name> <template>`. The template gives you a known-good docker-compose,
`.env` shape, and `service.sh` with any service-specific helpers (e.g. `occ` for nextcloud).

If no template fits, fall back to `default` and follow
[standardize-service](../standardize-service/SKILL.md) end-to-end to shape the stack:
two-network model, traefik labels only on the webserver, versions in `.env`, `restart:
unless-stopped`, volumes under `./volumes/`, no `container_name`, etc.

## Phase 2 — Inventory the old deployment (read-only)

A docker-compose source is the easy case. Probe with:

```bash
ssh root@OLD 'ls -la ~; docker ps --format "{{.Names}}\t{{.Image}}\t{{.Status}}"'
ssh root@OLD 'cat <service-dir>/docker-compose.yml; cat <env-file>'
ssh root@OLD 'du -sh <service-dir>/volumes/*'
ssh root@OLD 'docker exec <container> env'   # finds runtime env that may not be in compose
```

But the old deployment may **not** be docker. It could be:

- Bare service files under `/opt/<name>/` with a systemd unit.
- A non-controller docker layout (e.g. portainer-managed stack, raw `docker run`).
- A whole VM running multiple services tangled together.

When unclear, **stop and ask**. Useful clarifying questions:

- "Where does the data live on disk?"
- "Which env vars or config files are required to start it cleanly from scratch?"
- "Is there a database, and if so, what engine and how is it backed up today?"
- "Are there secrets only in memory or only in `docker inspect`, not in any file?"
- "Anything bound to the host (cron, host networking, files outside the service dir)?"

Don't guess about layout — wrong assumptions here cascade into broken new-side files. Cheap to
ask, expensive to redo.

## Phase 3 — Plan and adapt new-side files

Enter plan mode. Write the plan with:

- A short context section: where data lives now, where it's going, total size.
- Source-side inventory table (containers, image versions, env file locations, volume sizes).
- Proposed new `docker-compose.yml`, `.env`, and `service.sh` contents, conforming to the
  template and to [standardize-service](../standardize-service/SKILL.md).
- The exact `rsync`/`scp`/`mysqldump` commands the user will run, with explanations.
- Verification checklist for after start-up.

Common adaptations vs. the source:

- Rename env vars to template conventions: `NEXTCLOUD_DOMAIN → DOMAIN`,
  `MARIADB_VERSION → MARIA_DB_VERSION`, etc. The new templates use generic names so the same
  compose snippets work across services.
- Drop `BORG_*` from the per-service `.env` — they live in `$BASE_DIR/.env` now and are
  inherited.
- Drop `container_name:`, comment out unneeded `ports:`, switch volumes to `./volumes/...`, and
  swap host-mode for the two-network model (`default` + external `traefik`).
- Add traefik labels to the webserver only. If the old setup used a host-port reverse-proxy on
  some non-webserver container (e.g. a signaling backend), put traefik labels on that container
  and drop the host port mapping — unless the protocol is UDP (TURN, WebRTC), in which case
  keep the host port.

After plan approval, Claude scaffolds + edits:

```bash
cd $BASE_DIR
printf 'n\n' | ./controller.sh create <name> <template>   # creates $BASE_DIR/<name>, git init
```

The piped answer handles `create`'s interactive "init a Borg repository now?" prompt, which
would otherwise hang or abort a non-interactive run. Pipe `y` instead of `n` if the plan
decided to init borg now; default is `n` — defer until after the first successful start.

Then Claude edits `$BASE_DIR/<name>/docker-compose.yml`, `.env`, `service.sh` to match the plan.

## Phase 4 — User-run data migration

Hand the user the exact commands. Examples by source type:

**File tree** (data dir, attachments, configs):

```bash
rsync -aHAX --numeric-ids --info=progress2 \
  root@OLD:/path/to/data/ \
  $BASE_DIR/<name>/volumes/data/
```

`--numeric-ids` is essential when containers run as a specific uid (e.g. `www-data` = 33,
`mysql` = 999) — local user/group names may differ but numeric uids do not.

**Running database** (preferred for any live DB):

```bash
# Dump on old side, pipe into new container on this side
ssh root@OLD 'docker exec <old-db-container> mysqldump --single-transaction --quick \
    -u root -p"$MYSQL_ROOT_PASSWORD" --all-databases' \
  | docker exec -i <name>-<db-container>-1 mysql -u root -p"$MYSQL_ROOT_PASSWORD"
```

**Stopped database (only if user explicitly chooses to stop for a moment):** rsync
`/var/lib/mysql` with `--numeric-ids`. Default is dump — only use this if the user opts in.

**Env / secret files:** plain `scp`. Note that the new `.env` should be a *rewrite* of the old
one, not a verbatim copy — rename vars to template conventions.

**Tell the user when to ping back.** Ask them to message when the data copy finishes. The
scaffold and file edits (Phase 3) are Claude's and don't depend on the copy — keep working on
them while the long rsync runs.

## Phase 5 — Verify, finalize, start

Once the user reports the copy is done, Claude (no further confirmation needed for in-service
operations):

1. **Sanity-check copied data:**
   ```bash
   du -sh $BASE_DIR/<name>/volumes/*
   ls -la $BASE_DIR/<name>/volumes/<critical-dir> | head -10   # verify numeric uid/gid
   ```

2. **Bring it up:**
   ```bash
   cd $BASE_DIR/<name>
   ./service.sh up
   ./service.sh logs        # tail briefly
   ./service.sh status
   ```

3. **Apply post-start fix-ups** that the upstream image won't redo when config already exists.
   Example for nextcloud: `trusted_proxies` references the *old* reverse-proxy IP and won't be
   re-derived from env on subsequent boots — set it explicitly:
   ```bash
   ./service.sh occ config:system:set trusted_proxies 0 --value="172.16.0.0/12"
   ```
   Look for analogous gotchas: hard-coded internal URLs, instance UUIDs tied to a hostname,
   service registrations pointing at the old host.

4. **Smoke-test via traefik** (the existing traefik service usually already holds a wildcard
   cert covering the service's domain, so this works before DNS flips):
   ```bash
   curl -ksI https://<domain> | head -5
   curl -ksI https://<domain>/<known-endpoint>
   ```
   If DNS still points at the old host, resolve locally:
   `curl -k --resolve <domain>:443:127.0.0.1 https://<domain>`.

5. **Hand back to the user** with:
   - Any UI-side admin changes that need to happen (e.g. updating a HPB URL in NC Talk admin).
   - The DNS flip when they're ready to cut over.
   - The commit + first borg backup — a single command, because `git commit` automatically
     creates a borg backup named `commit: <message>` (see [git.sh](../../../git.sh)):
     ```bash
     ./service.sh git commit "<concrete description of the migration>"
     ```
   Wait for explicit user approval before committing — never commit a service repo unprompted.

## Pitfalls

- **Wildcard certs hide DNS state.** If traefik already has `*.example.com`, `curl https://new.example.com`
  works from this host regardless of where DNS points. That's a routing test, not a cutover test.
  Always check from a client outside this server before declaring cutover done.
- **Auto-upgrade on start.** If `.env` says `IMAGE_VERSION=32` and the running source was on 32.0.5,
  the new stack may pull 32.latest on first `up`. Usually fine, occasionally invokes a DB schema
  upgrade. Inspect logs on first start; pin a specific minor (`32.0.5`) if you need byte-for-byte
  parity until later.
- **Numeric uid drift.** `--numeric-ids` is non-negotiable for containerized services. Without it,
  data may rsync as `nobody:nogroup` and the container's process won't be able to write it.
- **Live DB file copies.** Never rsync `/var/lib/mysql` or `/var/lib/postgresql/data` from a
  *running* DB. Use a logical dump (`mysqldump --single-transaction`, `pg_dump`). The old skill
  iteration only worked because we (wrongly) stopped the DB first.
- **Old stack restarts itself.** If the old host has `restart: unless-stopped` and reboots, the
  old stack comes back up. After DNS flip, point users at the new instance and (with the user's
  go-ahead) have them disable the old stack so a reboot doesn't bring zombies back online.
