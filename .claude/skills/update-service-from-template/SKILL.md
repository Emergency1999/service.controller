---
name: update-service-from-template
description: 'Sync changes from a template in .controller/templates/ into an existing service created from it. Use when the user says "sync <service> with its template", "apply template changes to <service>", or when update-service found unapplied template changes. Reads the template''s CHANGELOG.md to find the delta (structural diff as fallback), merges without clobbering secrets/domains/local tweaks, restarts with a backup, and commits.'
---

# Sync Template Changes into a Service

## When to Use

The template a service was created from has moved ahead (new containers, mounts, labels, env
variables, `service.sh` commands — typically brought in via
[templatize-service](../templatize-service/SKILL.md) from another install's proven changes),
and the running service should receive those changes.

This is the **reverse direction** of templatize-service. Related skills:

- Newer *upstream versions* (image tags, breaking changes) →
  [update-service](../update-service/SKILL.md). That skill calls this one when it detects
  template drift; version bumps found in the template are *reported* here but executed there,
  with its research and backup discipline.
- The conventions both template and service must satisfy →
  [standardize-service](../standardize-service/SKILL.md).

## Process at a glance

1. **Identify** the originating template.
2. **Find the delta** — template `CHANGELOG.md` vs the service's copy; structural diff as
   fallback.
3. **Sort and merge** — bring structural changes over without clobbering service-local values.
4. **Apply + validate** — edits, `docker compose config`, sync the changelog copy.
5. **Restart safely** — backup, `up`, verify.
6. **Commit** with a very short message.

Execute via the step-by-step [CHECKLIST.md](CHECKLIST.md) — tick it top-to-bottom; the phase
sections below hold the rules each step references.

## Rules of engagement

- **The template is read-only here.** All edits go to the service dir. Template problems found
  along the way are reported, and fixed via templatize-service in a separate step if the user
  wants.
- **Never clobber service-local state.** Real secrets, the real `DOMAIN`, filled-in SMTP
  settings, and deliberate install-local tweaks stay untouched. A template placeholder never
  overwrites a live value.
- **Backup before restart.** The stack gets a borg backup before containers are recreated with
  the changed config.
- **One change set at a time.** Don't mix upstream version upgrades into a template sync — the
  commit history and the rollback archives stay meaningful when each skill does its own cycle.
- **Production server rules apply** (see [CLAUDE.md](../../../CLAUDE.md)): everything is
  scoped to the service dir (plus read access to `templates/`).

## Phase 1 — Identify the template

```bash
cd $BASE_DIR/<service>
git log --reverse --format=%s | head -1     # "Initial commit from template '<t>'"
ls $BASE_DIR/.controller/templates/<t>/
```

No pattern match (imported/migrated service) → match by folder name against `templates/`,
else ask the user. If no template fits, this skill does not apply — say so and stop.

## Phase 2 — Find the delta

**Preferred — CHANGELOG.md:** [templatize-service](../templatize-service/SKILL.md) appends a
short entry to `templates/<t>/CHANGELOG.md` on every template update. The service carries its
own copy (placed by `create`, refreshed by this skill in Phase 4), which marks the last-synced
state:

```bash
diff -u $BASE_DIR/<service>/CHANGELOG.md $BASE_DIR/.controller/templates/<t>/CHANGELOG.md
```

Entries present in the template file **above** the newest entry of the service's copy are the
pending changes — work strictly from their bullets so nothing is missed. No service copy at
all → every entry is pending. Spot-check the newest bullets against the actual template files
(the changelog is the map, the files are the territory). Bullets prefixed `note:` carry
upgrade knowledge (renamed vars, version couplings) rather than an edit to apply — read them
before syncing and pass them on when handing over to
[update-service](../update-service/SKILL.md).

**Fallback — structural diff** (template has no `CHANGELOG.md` yet, or the changelog looks
incomplete):

```bash
for f in docker-compose.yml .env service.sh .gitignore; do
  diff -u $BASE_DIR/.controller/templates/<t>/$f $BASE_DIR/<service>/$f
done
# plus any config files / traefik/ YAMLs the template ships
```

## Phase 3 — Sort and merge

Sort every pending change / hunk into one of three buckets (mirror of templatize-service
Phase 2):

1. **Bring over** — structural template improvements: new/changed containers, mounts, labels,
   healthchecks, new env *variables* (added with **empty** values — the user fills real
   secrets; generate values per the template's comments where they say to), new `service.sh`
   commands/attachments, new config files, `.gitignore` additions.
2. **Do not touch** — service-local state that legitimately differs from the template: real
   `DOMAIN` and secret values, filled SMTP blocks, install-local tweaks (extra middleware, a
   port uncommented for debugging). Template placeholders never win over live values.
3. **Report, don't execute** — version pins that are newer in the template than in the
   service. These belong to [update-service](../update-service/SKILL.md) (release-note
   research, proper backup naming); tell the user and offer that skill as the follow-up.

Ambiguous hunks — could be a template improvement or a local tweak — go to the user
(`AskUserQuestion`), not to a guess.

## Phase 4 — Apply and validate

- Edit the service files per the bring-over bucket.
- New env variables that need a secret: generate (`openssl rand -hex 32`) when the format
  allows, else add empty with a `# TODO` and list it in the hand-over.
- `docker compose config --quiet` in the service dir — errors are failures.
- Copy the template's `CHANGELOG.md` over the service's copy — this marks the service as
  synced up to the newest entry:

  ```bash
  cp $BASE_DIR/.controller/templates/<t>/CHANGELOG.md $BASE_DIR/<service>/CHANGELOG.md
  ```

## Phase 5 — Restart safely

```bash
cd $BASE_DIR/<service>
./service.sh backup pre-template-sync
./service.sh up          # compose recreates only what changed
```

A full `./service.sh down` first is needed only when the change requires it (e.g. network
changes, renamed services). Then verify:

- `./service.sh status` — all `Up`, no restart loops.
- `./service.sh logs` — clean startup.
- `curl -k --resolve <domain>:443:127.0.0.1 https://<domain>` when routing/labels changed.

Rollback if broken: `./service.sh down` → `./service.sh borg restore-fresh pre-template-sync`
→ `./service.sh up`, then report.

## Phase 6 — Commit and hand over

```bash
./service.sh commit "template sync: <very short summary>"   # e.g. "template sync: healthchecks"
```

(`commit` also creates a post-sync borg backup.) Then summarize for the user: what was
brought over, what was deliberately left untouched, any `# TODO` values to fill, and — if the
template had newer version pins — the pointer to run
[update-service](../update-service/SKILL.md) next.

## Pitfalls

- **Placeholder clobbers live value.** Blindly copying template files resets `DOMAIN=` to
  `example.com` and empties real secrets — the single worst failure of this skill. Merge hunks,
  never whole files (`CHANGELOG.md` is the one whole-file copy, and only in Phase 4).
- **Changelog trusted blindly.** An entry written carelessly may summarize away a detail;
  spot-check bullets against the template files before editing.
- **Version bumps smuggled in.** A template `PAPERLESS_VERSION` bump looks like a one-line
  bring-over but skips all release-note research — bucket 3, hand to update-service.
- **Changelog copy forgotten.** Without the Phase 4 `cp`, the next run sees the same entries
  as pending again and re-applies stale diffs.
- **Deleted-in-template ≠ delete-in-service.** Something absent from the template (a commented
  optional block the service enabled, an extra local file) is usually a local decision, not a
  deletion instruction. Only delete when a changelog bullet explicitly says removed.
- **`up` without backup.** Recreating containers with changed mounts/config can destroy state;
  `backup pre-template-sync` first, always.
