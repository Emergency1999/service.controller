# New-Service Checklist

Follow top to bottom. Each step says **who runs it**. Re-read [SKILL.md](SKILL.md) for the
rules behind these steps — especially "do not start the service yourself" and "official
sources only, versions pinned".

## 0. Scope (Claude + User)

- [ ] `ls $BASE_DIR/.controller/templates/` — if a template fits, use it and jump to step 5.
- [ ] Confirm with the user: service name (lowercase folder name), domain, and any variant
      choices (DB engine, optional components). Use `AskUserQuestion` when there are real
      options to pick.

## 1. Research (Claude)

- [ ] Find the official docker-compose example (docs → GitHub repo → image publisher page).
- [ ] Note every image and its current stable version tag.
- [ ] List all persistent data paths per container (including DB data dirs).
- [ ] Note the internal web port of the main/webserver container.
- [ ] Collect required env vars; classify: secret (generate), user-supplied (TODO), static
      config (inline later).
- [ ] Capture reverse-proxy requirements (base URL var, trusted proxies, websockets).
- [ ] Capture first-run setup steps (admin account, init commands, setup wizard).
- [ ] Anything ambiguous → ask the user now, not after scaffolding.

## 2. Scaffold (Claude)

- [ ] `cd $BASE_DIR && printf 'n\n' | ./controller.sh create <name>` — the piped `n` declines
      borg init (deferred to step 6).

## 3. Draft files (Claude)

- [ ] `docs/upstream-compose.yml` — unmodified upstream example + source URL/date header.
- [ ] `docker-compose.yml` — first draft from the upstream example.
- [ ] `.env` — `DOMAIN`, pinned versions, generated secrets (`openssl rand -hex 32`),
      `TIME_ZONE`, `# TODO` markers for user-only values.
- [ ] `service.sh` — only extend when needed (`att_configure` + `generate`, custom CLI cmds).
- [ ] `SETUP.md` — overview, architecture, configuration table, first start, post-start,
      maintenance.

## 4. Standardize (Claude)

- [ ] Apply [standardize-service](../standardize-service/SKILL.md) end-to-end, including its
      validation checklist. Named volumes → `./volumes/...` bind mounts.
- [ ] `cd $BASE_DIR/<name> && docker compose config --quiet` — syntax/interpolation check.

## 5. Hand-over (Claude → User)

- [ ] Present: what was created, open `.env` TODOs, DNS record needed, how to start
      (`./service.sh up:logs`), first-run setup steps, `https://<domain>`.
- [ ] **Stop here.** Do not run `./service.sh up`. End the turn.

## 6. First start + finalize (User, Claude assists)

- [ ] User fills `.env` TODOs, sets DNS, runs `./service.sh up:logs`.
- [ ] On problems: Claude debugs via `status`/`logs` (see SKILL.md Phase 7), fixes files,
      user (or Claude, in-service ops are fine now) re-runs `up`.
- [ ] After first successful start: `./service.sh borg init`.
- [ ] With user approval: `./service.sh git commit "initial <name> setup"` (commits + first
      borg backup).
- [ ] Update `SETUP.md` with anything non-obvious learned during debugging.
