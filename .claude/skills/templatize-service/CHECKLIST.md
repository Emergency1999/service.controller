# Templatize Checklist

Follow top to bottom. Each step says **who runs it**. The phase numbers refer to
[SKILL.md](SKILL.md) — re-read its rules first, especially "no secrets, no data" and
"allowlist, never blanket copy". All writes go to `.controller/templates/<name>/`; the live
service stays untouched.

## 1. Inventory the live service (Claude, read-only)

- [ ] `ls -la $BASE_DIR/<service>/` — note hidden files, especially `.env` variants
      (`.env.local`, `.env.backup`) which stay out entirely.
- [ ] Read `docker-compose.yml`, `.env`, `service.sh`, `.gitignore`.
- [ ] Build the file allowlist per SKILL.md Phase 1: always-in, in-when-referenced,
      always-out.
- [ ] Unknown files → ask the user (host-specific → leave out, missing stack part → copy +
      sanitize).

## 2. New template or update? (Claude)

- [ ] `ls $BASE_DIR/.controller/templates/<name>` — branch on the result.
- [ ] **New:** create the dir, `cp -p` each allowlisted file individually — never `cp -r` of
      the service dir.
- [ ] **Update:** `diff -u` template vs live for every allowlisted file; sort each hunk into
      bring-over / leave-behind / preserve-in-template (SKILL.md Phase 2). Ambiguous hunks →
      ask the user.
- [ ] **Update:** prepend a `CHANGELOG.md` entry in the template (create the file on first
      update) — date + version heading, one bullet per brought-over hunk, removals named
      explicitly. Very short but delta-complete (update-service-from-template consumes it).

## 3. Sanitize (Claude)

- [ ] `.env`: keep variable names, order, comments; classify every value per the Phase 3
      table — keep version pins and `TIME_ZONE`, domains → `<name>.example.com`, secrets →
      empty, unclear → empty + flag in the summary.
- [ ] `docker-compose.yml`: inline production credentials → `${VAR}` interpolation + empty
      `VAR=` in `.env`; legacy var names standardized.
- [ ] `service.sh`: no embedded passwords, tokens, real domains, or absolute host paths.
- [ ] Config files / `traefik/` YAMLs / `SETUP.md`: real domains, URLs, credentials →
      placeholders or `${VAR}` references.
- [ ] `.gitignore` lists `volumes` (and `generated` if the service uses it).

## 4. Mechanical leak scan (Claude — run even when "sure")

- [ ] Value-grep: every non-empty, non-version value from the live `.env` is absent from the
      template (Phase 4 script) — zero `!! LEAK` lines.
- [ ] Forbidden-file `find` (volumes, generated, .git, keys, certs, dumps, logs) prints
      nothing.
- [ ] `du -sh` of the template — a few KB; MB+ means data slipped in.
- [ ] Grep for the install's real domains, the server's hostname, and the operator's email —
      all absent.

## 5. Validate (Claude)

- [ ] `docker compose config --quiet` in the template dir — errors are failures, empty-var
      warnings are expected.
- [ ] [standardize-service](../standardize-service/SKILL.md) validation passes — fix in the
      *template*; report live-service drift to the user instead of editing the live service.
- [ ] New template: `docker-compose.yml`, `.env`, `service.sh`, `.gitignore` all present and
      `service.sh` kept its executable bit.

## 6. Document + hand over (Claude → User)

- [ ] New template only: add `<name>` to the template list in
      [CLAUDE.md](../../../CLAUDE.md).
- [ ] Show `git -C $BASE_DIR/.controller status` + `diff` (+ untracked file contents for a
      new template).
- [ ] Summarize: files copied, values emptied/replaced, anything flagged "unclear — please
      check".
- [ ] Update only: `CHANGELOG.md` entry present and its bullets match the actually merged
      hunks; mention that services can pull the delta via update-service-from-template.
- [ ] **Stop.** The user reviews and commits `.controller/` manually.
