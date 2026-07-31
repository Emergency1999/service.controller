---
name: templatize-service
description: 'Turn a running service in $BASE_DIR into a reusable template under .controller/templates/, or refresh an existing template from the live service (version bumps, structural changes). Use when the user says "make a template from <service>", "templatize <service>", "update the <name> template", or similar. Copies only the generic stack files via allowlist — never volumes/, generated/, .git/, or any secret value.'
---

# Turn a Running Service into a Template

## When to Use

A service running in `$BASE_DIR/<service>/` has proven itself and should become (or refresh) a
starter template in [templates/](../../../templates/) so other installs can `./controller.sh
create <name> <template>` it.

Related skills:

- Fresh software with no template and no running instance → [create-service](../create-service/SKILL.md).
- A deployment on *another host* that should move here → [migrate](../migrate/SKILL.md).
- The conventions every template must satisfy → [standardize-service](../standardize-service/SKILL.md)
  (this skill assumes them; read it first).

## Process at a glance

1. **Inventory** the live service (read-only) and build the file **allowlist** from what
   `docker-compose.yml` and `service.sh` actually reference.
2. **New or update?** Check whether `templates/<name>` already exists and branch accordingly.
3. **Copy / merge** the allowlisted files — never a blanket `cp -r` of the service dir.
4. **Sanitize** — empty every secret, replace real domains with `example.com` placeholders,
   keep version pins.
5. **Verify** — mechanical leak scan + `docker compose config` + standardize-service checklist.
6. **Document + hand over** — update the template list in [CLAUDE.md](../../../CLAUDE.md), show
   the `.controller` diff, let the **user** commit.

Execute via the step-by-step [CHECKLIST.md](CHECKLIST.md) — tick it top-to-bottom; the phase
sections below hold the rules each step references.

## Rules of engagement

- **No secrets, no data — the prime directive.** A template ships to every install via
  `./controller.sh update` and lives in a repo on GitHub. Treat every value in the live service
  as radioactive until classified. When unsure whether a value is generic or host-specific,
  empty it and flag it in the final summary (or ask via `AskUserQuestion`).
- **Allowlist, never blanket copy.** `cp -r $BASE_DIR/<service>` would drag along `volumes/`
  (gigabytes of user data), `generated/`, `.git/`, and the real `.env`. Copy individual files
  you inventoried, nothing else.
- **The live service is read-only.** This skill never edits, restarts, or otherwise touches the
  running service. All writes go to `.controller/templates/<name>/` (and the doc line in
  `CLAUDE.md`).
- **Never commit `.controller/` yourself.** Per project convention the user commits the
  controller repo manually. Finish by presenting `git -C $BASE_DIR/.controller status` + diff.
- Production server rules apply (see [CLAUDE.md](../../../CLAUDE.md)): everything here is
  file-scoped to `$BASE_DIR` — no docker commands are needed at all except a read-only
  `docker compose config` check.

## Phase 1 — Inventory the live service

```bash
ls -la $BASE_DIR/<service>/            # note hidden files: .env, .gitignore, extras
cat $BASE_DIR/<service>/docker-compose.yml
cat $BASE_DIR/<service>/.env
cat $BASE_DIR/<service>/service.sh
cat $BASE_DIR/<service>/.gitignore
```

Build the allowlist from what is actually referenced:

**Always in (after sanitizing):**

| File | Notes |
|---|---|
| `docker-compose.yml` | plus `docker-compose.override.yml` if present and generic |
| `.env` | sanitized per Phase 3 — never copied verbatim |
| `service.sh` | custom commands/attachments are the value of a template — keep them |
| `.gitignore` | must contain `volumes` (add `generated` if the service uses it) |

**In when referenced or present (after sanitizing):**

- `Dockerfile` + files its `COPY` lines need (compose `build:` context — cf. pretix).
- Static config files bind-mounted into containers (`uploads.ini`, `pretix.cfg`, …) — find them
  in compose `volumes:` entries that mount a *file*, not a `./volumes/` data dir.
- Template sources consumed by `generate <template> <output>` calls in `service.sh` (the output
  under `generated/` stays out; the source template goes in).
- `traefik/` file-provider YAMLs and the extra config of a traefik-role service (`traefik.yml`).
- `SETUP.md` / `docs/` written by [create-service](../create-service/SKILL.md), if generic.
- Anything else in the dir: **ask the user** — unknown files are either host-specific
  (leave out) or a missing part of the stack (copy + sanitize).

**Always out — never in a template:**

- `volumes/` — user data. The single worst thing to leak.
- `generated/` — runtime output; regenerated on every `up`.
- `.git/` — the service's own history.
- Dumps, exports, backups, logs (`*.sql*`, `*.dump`, `*.tar*`, `*.log`).
- Key material (`*.key`, `*.pem`, `*.crt`, `acme.json`, ssh keys).
- `.env` **values** that are secret or host-specific (the variable *names* stay, see Phase 3).

## Phase 2 — New template or update?

```bash
ls $BASE_DIR/.controller/templates/<name> 2>/dev/null
```

**Does not exist → new template.** Create the directory and copy the allowlisted files
one by one (`cp -p` preserves the executable bit on `service.sh`), then sanitize in place.

**Exists → update.** Do **not** overwrite. Diff each allowlisted file against its template
counterpart and merge with Edit:

```bash
diff -u $BASE_DIR/.controller/templates/<name>/docker-compose.yml $BASE_DIR/<name>/docker-compose.yml
diff -u $BASE_DIR/.controller/templates/<name>/.env $BASE_DIR/<name>/.env
# ... one diff per file
```

Sort every hunk into one of three buckets:

1. **Bring over** — structural changes proven in production: new/changed containers, mounts,
   labels, healthchecks, new env *variables* (added with placeholder values), new `service.sh`
   commands/attachments, and version bumps (a main reason to re-run this skill).
2. **Leave behind** — live host-specific state: real domains, filled-in secrets, install-local
   tweaks (an extra middleware only this org uses, a local port uncommented for debugging).
   When a hunk could be either, ask the user rather than guessing.
3. **Preserve in the template** — placeholder values, commented-out optional blocks (SMTP
   sections, opt-in features), and explanatory comments. Never let the live file's absence of
   these "win" the merge — they exist *only* in the template and that is correct.

## Phase 3 — Sanitize

`.env` — keep variable names, order, and comments; classify every **value**:

| Variable looks like | Action |
|---|---|
| `*_VERSION` / `VERSION` | **Keep the live value** — templates ship current pins |
| `TIME_ZONE` / `TIMEZONE*` | Keep (`Europe/Berlin` is fine) |
| `DOMAIN` and `*_DOMAIN` | Replace with `<name>.example.com` |
| `*PASSWORD*`, `*PASSPHRASE*`, `*SECRET*`, `*TOKEN*`, `*KEY*`, `*SALT*`, `*CREDENTIAL*` | Empty: `VAR=` |
| SMTP / mail settings | Empty and move into a commented `#* SMTP settings` block (cf. nextcloud) |
| Emails, IPs, hostnames, org names, anything host-specific | Empty, or an obvious `example` placeholder |
| Unclear | Empty it and flag in the summary |

Other files:

- **`docker-compose.yml`** — real credentials sometimes hide *inline* under `environment:`
  (stack-internal DB passwords are allowed inline per standardize-service §8, but a production
  value must not ship). Replace with `${VAR}` interpolation + an empty `VAR=` in `.env`,
  matching the nextcloud template pattern. Also standardize legacy var names (`EXAMPLE_DOMAIN`
  → `DOMAIN`) per standardize-service §4.
- **`service.sh`** — inspect the `set -o allexport` block and every custom command for embedded
  passwords, tokens, domains, absolute host paths. Genericize (`${DOMAIN}`, `$SERVICE_DIR`)
  or strip.
- **Config files / `traefik/` YAMLs / `SETUP.md`** — replace real domains, URLs, and any
  credentials with `example.com` placeholders or `${VAR}` references (use the `generate`
  mechanism when the value must be substituted at runtime).
- **`.gitignore`** — ensure `volumes` is listed (and `generated` if used); this also protects
  the controller repo itself from ever tracking data.

## Phase 4 — Mechanical leak scan

Judgment already happened in Phase 3; this phase is a dumb backstop. All three checks must
come back clean:

```bash
# 1. No live secret value survives — every non-empty, non-version value from the real .env
#    must be absent from the template (expected hits: version pins, TIME_ZONE only)
cd $BASE_DIR
grep -E '^[A-Za-z_0-9]+=..*' <service>/.env | while IFS='=' read -r var val; do
  case "$var" in *VERSION*|TIME_ZONE|TIMEZONE*) continue ;; esac
  grep -rFn -- "$val" .controller/templates/<name>/ && echo "!! LEAK: $var"
done

# 2. No forbidden files
find .controller/templates/<name> \( -name volumes -o -name generated -o -name .git \
  -o -name '*.key' -o -name '*.pem' -o -name 'acme.json' -o -name '*.sql*' \
  -o -name '*.dump' -o -name '*.log' \) -print   # must print nothing

# 3. Size sanity — a template is a few KB; MB+ means data slipped in
du -sh .controller/templates/<name>
```

Additionally grep the template for the install's real domains (every `Host(` value and
`*DOMAIN*` value in live `.env` files), the server's hostname, and the operator's email — all
must be absent.

## Phase 5 — Validate

- `cd $BASE_DIR/.controller/templates/<name> && docker compose config --quiet` — syntax check
  only; warnings about empty variables are expected, errors are not.
- Run the [standardize-service](../standardize-service/SKILL.md) validation checklist — a
  template made from a conforming live service should pass as-is; fix in the *template* if not
  (and tell the user the live service drifted from conventions rather than editing it).
- For a **new** template: confirm the four core files exist (`docker-compose.yml`, `.env`,
  `service.sh`, `.gitignore`) and `service.sh` kept its executable bit.

## Phase 6 — Document and hand over

1. **New template only:** add `<name>` to the template list in the "Service templates" section
   of [CLAUDE.md](../../../CLAUDE.md) (and any other place templates are enumerated).
2. Show the user what changed:
   ```bash
   git -C $BASE_DIR/.controller status
   git -C $BASE_DIR/.controller diff       # plus untracked file contents for a new template
   ```
3. Summarize explicitly: which files went in, which values were emptied or replaced, and
   anything flagged as "unclear — please check".
4. **Stop.** The user reviews and commits `.controller/` manually; a later
   `./controller.sh update` on other installs distributes the template.

## Pitfalls

- **`cp -r` of the service dir.** The classic mistake — one command leaks the entire `volumes/`
  data set and the real `.env` into a GitHub-hosted repo. Allowlist only, always.
- **Secrets outside `.env`.** Inline `environment:` values in compose, the allexport block in
  `service.sh`, traefik YAMLs (forwardAuth addresses, basic-auth hashes), and app config files
  all carry credentials in the wild. Phase 4's value-grep catches what Phase 3 missed — run it
  even when "sure".
- **Update clobbers placeholders.** Blindly copying files over an existing template resets
  `DOMAIN=` placeholders to the real domain and deletes commented optional blocks. The
  three-bucket merge in Phase 2 exists precisely for this.
- **Emptied var that the stack needs at build/parse time.** After emptying values, only
  `docker compose config` proves the file still parses — run it.
- **Hidden files skipped.** `ls` without `-a` misses `.env` variants (`.env.local`,
  `.env.backup`) that may contain older real secrets. Inventory with `ls -la` and leave such
  variants out entirely.
- **Version pins accidentally "sanitized".** Versions are the one live value templates *want*
  (`NEXTCLOUD_VERSION=32.0.8`, not `NEXTCLOUD_VERSION=`) — emptying them ships a broken
  template; `latest` is equally wrong.
