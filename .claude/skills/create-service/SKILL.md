---
name: create-service
description: 'Research and set up a completely new service that has no template yet. Use when the user says "set up <software> as a new service", "add <software> to the server", "install <software>" or similar. Covers web research (official docker-compose examples, setup steps), scaffolding via ./controller.sh create, writing a SETUP.md, handoff to standardize-service, and a final how-to-start overview plus debugging support.'
---

# Create a Completely New Service

## When to Use

The user wants to run software on this server that does not exist here yet and has no template in
`templates/`. This is a **fresh install from upstream sources** — if an existing deployment on
another host should be moved over instead, use the [migrate](../migrate/SKILL.md) skill.

Once the new service has proven itself in production,
[templatize-service](../templatize-service/SKILL.md) can turn it into a reusable template —
worth mentioning in the final hand-over when the software seems generally useful. Later
version upgrades are handled by [update-service](../update-service/SKILL.md), which relies on
the `UPDATE.md` this skill writes in Phase 4.

## Process at a glance

1. **Scope** — clarify name, domain, and variant choices with the user; check whether a
   template already covers the service.
2. **Research** the web for the official docker-compose example, required env vars, persistent
   paths, and first-run setup steps. Official sources only, versions pinned.
3. **Scaffold** with `./controller.sh create <name>` (default template).
4. **Draft** `docker-compose.yml`, `.env`, `service.sh`, save the unmodified upstream example
   under `docs/`, and write a `SETUP.md` documentation file into the service dir.
5. **Hand off to [standardize-service](../standardize-service/SKILL.md)** — apply it end-to-end
   so the stack conforms to project conventions, and run its validation checklist.
6. **Final overview** — tell the user exactly what to fill in and how to start. Do **not** start
   the service yourself. End the turn here.
7. **Debug on demand** — when the user reports back, help diagnose with `logs`/`status`.

Execute via the step-by-step [CHECKLIST.md](CHECKLIST.md) — tick it top-to-bottom; the phase
sections below hold the rules and context each step references.

## Rules of engagement

- **Do not start the service yourself.** Secrets and DNS are usually not ready when scaffolding
  finishes; `docker_up` would also auto-enroll the service in nightly autobackup before a borg
  repo exists. The user runs the first `./service.sh up` — you stand by for debugging.
- **Official sources only.** Docker-compose examples come from the project's own docs, its
  GitHub repo, or the image publisher (Docker Hub / ghcr / linuxserver.io). Random blog posts
  are background reading at best — never the basis for the compose file.
- **Pin image versions.** Look up the current stable tag and put it in `.env`. Never ship
  `latest`.
- **Production server rules apply** (see [CLAUDE.md](../../../CLAUDE.md)): no system-wide
  commands. Everything this skill does is scoped to `$BASE_DIR` and the new service dir.
- **Secrets stay out of the controller repo.** Generated secrets go into the service's `.env`;
  values only the user knows are left as clearly marked `# TODO` placeholders.

## Phase 1 — Scope and template check

```bash
ls $BASE_DIR/.controller/templates/
```

If a template already fits, use `./controller.sh create <name> <template>` and skip to Phase 6 —
research is only needed for genuinely new services.

Clarify with the user before researching (use `AskUserQuestion` where helpful):

- **Service name** — simple lowercase folder name, becomes the compose project name.
- **Domain** — the `DOMAIN` value for traefik routing (e.g. `notes.example.com`).
- **Variant choices** the software offers: SQLite vs postgres/mariadb, bundled vs external
  redis, which optional components (workers, cron container, office suite) to include. If
  research later surfaces such a choice, come back and ask rather than guessing.

## Phase 2 — Web research

Use `WebSearch` / `WebFetch`. Typical targets, in order of authority:

1. Official docs "Install with Docker / Docker Compose" page.
2. The project's GitHub repo (`docker-compose.yml` examples, `.env.example`, release notes).
3. The image page on Docker Hub / ghcr (tags, supported architectures, env var reference).

Facts to capture — the compose draft and `SETUP.md` are written from this list:

- **Image(s) + current stable version tag** for every container in the stack.
- **Persistent data paths** inside each container — everything that must survive a recreate
  becomes a `./volumes/...` bind mount. Include DB data dirs.
- **Internal web port** — needed for the traefik loadbalancer port label when it isn't 80.
- **Required env vars** — which are secrets (generate with `openssl rand -hex 32` where the
  format allows), which are host-specific (user fills), which are static config (inline).
- **Database requirements** — engine + supported versions; prefer what upstream recommends.
- **Reverse-proxy requirements** — trusted-proxy settings, `X-Forwarded-*` expectations,
  websocket endpoints, a base/public URL env var that must match `https://$DOMAIN`.
- **First-run setup** — how the initial admin account is created (env var, setup wizard URL,
  CLI command inside the container), plus any one-time init/migration commands.
- **Extra moving parts** — cron/worker containers, healthchecks, upgrade notes.

If the sources conflict or leave a real gap, ask the user — cheap to ask, expensive to redo.

## Phase 3 — Scaffold

```bash
cd $BASE_DIR
printf 'n\n' | ./controller.sh create <name>
```

The `printf 'n'` answers the interactive "create a Borg repository now?" prompt with **no** —
borg init is deferred until after the first successful start (an empty-service backup is
useless, and the prompt would otherwise hang or abort a non-interactive run). `create` copies
the default template, makes `service.sh` executable, and git-inits the service dir with an
initial commit.

## Phase 4 — Draft service files and documentation

All inside `$BASE_DIR/<name>/`:

- **`docs/upstream-compose.yml`** — the *unmodified* upstream example, with a comment header
  naming the source URL and retrieval date. This is the reference the adapted stack can always
  be diffed against.
- **`docker-compose.yml`** — first draft based on the upstream example. Don't polish it here;
  Phase 5 does the convention work.
- **`.env`** — `DOMAIN`, pinned image version variables, generated secrets, `TIME_ZONE`, and
  `# TODO` placeholders for values only the user can supply (SMTP credentials, API keys, …).
- **`service.sh`** — extend beyond the template only when the service needs it: an
  `att_configure` that runs `generate <template> <output>` for dynamic config files, or a
  custom command wrapping the app's CLI (pattern: `occ` in the nextcloud template).
- **`UPDATE.md`** — the version-source info file consumed by
  [update-service](../update-service/SKILL.md) (skeleton in its Phase 3): per image the
  releases/changelog/breaking-changes URLs, version scheme and upgrade rules, app-specific
  post-upgrade checks, and a footer with current main version + today's date. All of this
  falls out of the Phase 2 research — write it down now so upgrades never re-hunt sources.
- **`SETUP.md`** — short and **service-specific only**. Generic knowledge lives elsewhere and
  is not repeated here: `.env` comments describe the variables, `UPDATE.md` covers upgrades,
  `docker-compose.yml` shows the architecture, and the standard borg/traefik flows are
  documented in the controller repo. Three sections, each dropped when empty:
  - **Links** — official documentation, the source of the compose example, admin guide.
  - **First run** — how the initial admin account is created (env var, setup wizard URL, or
    CLI command inside the container) and any one-time init/migration commands.
  - **Quirks** — non-obvious requirements unique to this service (e.g. a trusted-proxy
    setting, a worker that must be scaled, backup/restore needs beyond the standard borg
    flow) — typically grown later during debugging rather than filled on day one.

## Phase 5 — Hand off to standardize-service

Apply [standardize-service](../standardize-service/SKILL.md) **end-to-end** to the drafted
stack: no `container_name`, ports commented out, two-network model with traefik labels only on
the webserver, versions in `.env`, `restart: unless-stopped`, everything under `./volumes/`,
env vars placed per its rules. Convert upstream *named volumes* to `./volumes/<name>` bind
mounts. Finish with that skill's validation checklist and a `docker compose config` syntax
check:

```bash
cd $BASE_DIR/<name> && docker compose config --quiet
```

## Phase 6 — Final overview, then stop

Present the user a concise hand-over and **end the turn** — do not run `up` yourself:

1. **What was created** — service dir, files, where `SETUP.md` lives.
2. **What they must do before first start** — `.env` TODOs (list them explicitly), DNS record
   for `$DOMAIN` pointing at this server.
3. **How to start:**
   ```bash
   cd $BASE_DIR/<name>
   ./service.sh up:logs        # starts the stack, then tails logs
   ./service.sh status
   ```
4. **First-run setup** — the admin-account/wizard steps researched in Phase 2, and the URL:
   `https://<domain>`.
5. **After the first successful start** — init backups and commit (commit only with the user's
   go-ahead):
   ```bash
   ./service.sh borg init
   ./service.sh git commit "initial <name> setup"    # commits + creates first borg backup
   ```

## Phase 7 — Debugging support

When the user reports problems, work the stack top-down:

- `./service.sh status` / `./service.sh logs` — crash loops, missing env vars, migration
  errors on first boot.
- **404 from traefik** — service not on the external `traefik` network, missing/typoed router
  labels, or DNS not pointing here yet (`curl -k --resolve <domain>:443:127.0.0.1 https://<domain>`
  tests routing independent of DNS).
- **502 from traefik** — wrong internal port in the loadbalancer label, or the app only
  listening on localhost inside the container.
- **App loads but misbehaves** — redirect loops and mixed-content usually mean the public/base
  URL env var doesn't match `https://$DOMAIN` or trusted-proxy config is missing.
- **Permission errors on `./volumes/...`** — check which uid the container runs as and `chown`
  the host dir accordingly.
- Fixes to compose/`.env` are applied directly, then `./service.sh up` again (compose
  recreates what changed). Update `SETUP.md` when a fix reveals a non-obvious requirement.

## Pitfalls

- **Interactive prompt in `create`.** Without `printf 'n\n' |` the borg question blocks (or
  kills the run via `set -e` on EOF). Always pipe the answer.
- **`latest` or missing arch.** Verify the pinned tag exists for this host's architecture
  (`docker manifest inspect <image>:<tag>` if unsure) — some projects only publish amd64.
- **Named volumes hide the data path.** Upstream examples love `dbdata:`-style named volumes;
  each one must become an explicit `./volumes/...` bind mount or borg backups will miss the
  data entirely.
- **Non-80 internal ports.** If the app serves on e.g. 3000 internally, traefik needs
  `traefik.http.services.${COMPOSE_PROJECT_NAME}.loadbalancer.server.port=3000` — a plain
  router label alone yields 502s.
- **First-boot secrets are sticky.** Many apps bake `SECRET_KEY`/DB passwords into their data
  dir on first start. Generate real values *before* the first `up`, not after.
- **Setup wizards behind traefik.** Some apps expose an unauthenticated setup wizard on first
  start. Mention in the overview that the user should complete setup promptly after `up`, or
  gate it if the software supports it.
