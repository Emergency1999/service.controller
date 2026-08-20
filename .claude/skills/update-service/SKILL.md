---
name: update-service
description: 'Upgrade an existing running service to newer upstream versions. Use when the user says "update <service>", "upgrade <service>", "bring <service> to the newest version" or similar. Covers a template-drift pre-check, release/breaking-change research via the service''s UPDATE.md, a backed-up down/edit/up cycle, verification, and a final git commit. Creates UPDATE.md when missing.'
---

# Upgrade a Service to a Newer Upstream Version

## When to Use

A service already running in `$BASE_DIR/<service>/` should be upgraded to newer upstream
release(s) — the main app and/or its companion images (db, redis, workers, …).

Related skills:

- Template changed and the service should receive the *structural* changes (not new upstream
  versions) → [update-service-from-template](../update-service-from-template/SKILL.md). This
  skill checks for that situation and offers the hand-off (Phase 2).
- New software with no service dir yet → [create-service](../create-service/SKILL.md).
- After a successful upgrade, refreshing the template with the new version pins →
  [templatize-service](../templatize-service/SKILL.md).

## Process at a glance

1. **Identify** — current versions from `.env`, originating template, existing docs.
2. **Template drift check** — if the template has changes this service never received, notify
   the user and offer to run update-service-from-template *first*.
3. **UPDATE.md** — read it; if missing, research the version/changelog sources and create it.
4. **Research** newest stable versions and the release notes / breaking changes between
   current and target for every image in the stack.
5. **Plan + confirm** — present old→new, breaking changes, needed edits, downtime. Wait for
   the user's go-ahead before any downtime.
6. **Execute** — `down` → `backup last-<current-version>` → apply edits → `pull` → `up`.
7. **Verify** — status, logs, HTTP check, app-specific checks.
8. **Finalize** — update docs, `./service.sh commit "upgrade-to-<new-version>"`.

Execute via the step-by-step [CHECKLIST.md](CHECKLIST.md) — tick it top-to-bottom; the phase
sections below hold the rules and context each step references.

## Rules of engagement

- **No downtime without a go-ahead.** This is the production server; `./service.sh down`
  happens only after the user confirmed the upgrade plan (Phase 5). Everything before that is
  read-only research.
- **Backup before touching anything.** The `backup last-<current-version>` archive is the
  rollback anchor — it is taken *after* `down` (consistent data, containers stopped) and
  *before* any edit.
- **Official sources only, versions pinned.** Same rules as
  [create-service](../create-service/SKILL.md): release info comes from the project's own
  docs/GitHub/image registry; never ship `latest`.
- **Database major upgrades are never automatic.** A postgres/mariadb major bump usually needs
  a dump/restore or upgrade tool, not a tag change. Detect it, explain it, and get explicit
  user confirmation for the extra procedure — or pin the DB at the current major and note it.
- **Production server rules apply** (see [CLAUDE.md](../../../CLAUDE.md)): everything is
  scoped to the service dir; no system-wide commands.

## Phase 1 — Identify

```bash
cd $BASE_DIR/<service>
grep -E '^[A-Za-z_0-9]*VERSION' .env            # current pins
git log --reverse --format=%s | head -1          # "Initial commit from template '<t>'"
ls SETUP.md UPDATE.md CHANGELOG.md docs/ 2>/dev/null
cat docker-compose.yml                           # every image + which var pins it
```

- The originating template is named in the service's **first git commit message**. If that
  commit doesn't follow the pattern (imported/migrated service), match by folder name against
  `templates/`, else ask the user.
- Read `SETUP.md` and `UPDATE.md` if they exist — they carry service quirks and upgrade
  rules from previous rounds.
- Note the **main app version** — it names the backup archive and the commit message.

## Phase 2 — Template drift check

Before upgrading, check whether the template moved ahead of this service:

- **Preferred — CHANGELOG.md delta:** if `templates/<t>/CHANGELOG.md` exists, compare it with
  the service's own copy (present in services created/synced after the changelog mechanism was
  introduced). Entries in the template file **above** the newest entry in the service's copy
  are changes this service never received. No service copy at all → every entry is pending.
- **Fallback — structural diff:** no template changelog → `diff -u` the template files against
  the service counterparts and judge structurally, ignoring the hunks that are *expected* to
  differ (real domain vs `example.com`, filled secrets vs empty placeholders, version pins,
  install-local tweaks).

If pending template changes exist: **list them to the user and ask** whether to run
[update-service-from-template](../update-service-from-template/SKILL.md) first (recommended —
one change set at a time, each with its own backup and commit), or to proceed with the version
upgrade only. Do not silently mix template sync into the upgrade.

## Phase 3 — UPDATE.md (read or create)

`UPDATE.md` in the service root records **where upgrade information comes from**, so future
upgrades skip the source hunt. If it exists, read it and follow it. If missing, research the
sources now (`WebSearch`/`WebFetch`, official only) and create it:

```markdown
# Update info — <service>

## Version sources
| Image | Pinned by | Releases / changelog | Breaking changes |
|---|---|---|---|
| ghcr.io/paperless-ngx/paperless-ngx | PAPERLESS_VERSION | https://github.com/paperless-ngx/paperless-ngx/releases | release notes "Breaking changes" section |
| postgres | POSTGRES_VERSION | https://www.postgresql.org/support/versioning/ | major bump = dump/restore |

## Version scheme / upgrade rules
- <e.g. "semver; sequential major upgrades required", "app X supports postgres <= 17">

## Post-upgrade checks
- <e.g. "log in, upload a test document, check /admin for pending migrations">

## Status
- Current main version: <x.y.z> — last checked: <YYYY-MM-DD>
```

Keep it short — a table row per image, only rules that actually constrain upgrades. Absolute
dates only.

## Phase 4 — Research target versions and breaking changes

For **every** image in the stack:

1. Find the newest stable tag (releases page / registry tags). Verify the tag exists for this
   host's architecture when in doubt (`docker manifest inspect <image>:<tag>`).
2. Read the release notes **between current and target** — not just the latest entry. Capture:
   - breaking changes and required config/env changes,
   - sequential-upgrade requirements (some apps require stepping through majors),
   - deprecations that affect this compose setup,
   - companion-version coupling (new app version requires newer/older db, redis, …).
3. Classify each companion bump: **tag-only** (redis minor, app patch) vs **procedural**
   (postgres/mariadb major → dump/restore; report-and-ask, never automatic — offer to keep
   the current major instead).

## Phase 5 — Present the plan and confirm

Present to the user, then **wait for the go-ahead** (use `AskUserQuestion` where helpful):

1. Version table: image, current → target.
2. Breaking changes and the concrete edits they require (compose/`.env`/config files).
3. Anything procedural (db major upgrade, sequential steps, manual migration commands).
4. Expected downtime (roughly: pull time + migration time).

If the user defers some bumps (e.g. "app yes, postgres major no"), pin accordingly and note
the deferral in `UPDATE.md`.

## Phase 6 — Execute

```bash
cd $BASE_DIR/<service>
./service.sh down
./service.sh backup last-<current-version>       # e.g. last-2.20 — the rollback anchor
```

Then apply the changes:

- Bump the `*_VERSION` values in `.env`.
- Apply the breaking-change edits from Phase 4 (compose changes, new/renamed env vars, config
  files — regenerate via `generate` where the service uses it).
- Validate: `docker compose config --quiet` (errors are failures).

```bash
./service.sh pull
./service.sh up
```

`down`/`up` auto-toggle nightly autobackup enrollment — no manual handling needed.

## Phase 7 — Verify

- `./service.sh status` — all containers `Up`, no restart loops (re-check after a minute).
- `./service.sh logs` — startup migrations completed, no error spam.
- HTTP check independent of DNS:
  `curl -k --resolve <domain>:443:127.0.0.1 https://<domain>` — expect the app, not 404/502.
- Run the app-specific post-upgrade checks from `UPDATE.md` (and any the release notes added).
- Version visible in the UI/API matches the target.

**If verification fails** and fixing forward doesn't work: roll back —

```bash
./service.sh down
./service.sh borg restore-fresh last-<old-version>   # .git survives the restore
./service.sh up
```

then report what failed and leave the analysis to a calmer moment.

## Phase 8 — Finalize

1. Update `UPDATE.md`: current version + last-checked date; add any upgrade rule this round
   discovered (e.g. "2.21 renamed VAR_X → VAR_Y"). Update `SETUP.md` only if behavior or
   configuration documented there changed.
2. Commit — the message is the new version, or a very short description when the change was
   not (only) a version bump:

   ```bash
   ./service.sh commit "upgrade-to-<new-version>"
   # or e.g.: ./service.sh commit "versions extracted"
   ```

   `commit` also creates a fresh borg backup, so the post-upgrade state is archived too.
3. If the service originates from a template, mention that
   [templatize-service](../templatize-service/SKILL.md) can bring the new version pins back
   into the template — worth doing after the upgrade has proven itself.

## Pitfalls

- **Only the latest release notes read.** Breaking changes hide in the skipped releases
  between current and target — read the whole range.
- **Companion images forgotten.** An upgrade that bumps only the app leaves postgres/redis
  aging forever; check all images every round (and treat db majors as procedural).
- **Backup after editing.** The `last-<version>` archive must capture the *pre-upgrade* state;
  take it immediately after `down`, before any edit.
- **DB major treated as tag bump.** Postgres refuses to start on old data files after a major
  bump — that's the designed failure. Dump/restore (or pin the major) instead.
- **`up` before `pull`.** Compose would start old images and migrations may run twice; pull
  first, then up.
- **Verification skipped because "it started".** Migrations can fail while containers stay
  `Up`; always check logs and the HTTP response, not only `status`.
- **First-boot-sticky secrets regenerated.** Never "refresh" secret values during an upgrade —
  existing data was encrypted/signed with them.
