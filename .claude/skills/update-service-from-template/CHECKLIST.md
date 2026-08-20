# Update-Service-From-Template Checklist

Follow top to bottom. Each step says **who runs it**. The phase numbers refer to
[SKILL.md](SKILL.md) — re-read its rules first, especially "never clobber service-local
state" and "one change set at a time". The template is read-only; all edits go to the
service dir.

## 1. Identify the template (Claude, read-only)

- [ ] Template name from the service's first git commit message (fallback: folder-name
      match / ask the user).
- [ ] Template dir exists under `$BASE_DIR/.controller/templates/<t>/` — otherwise this
      skill does not apply; say so and stop.

## 2. Find the delta (Claude, read-only)

- [ ] Template `CHANGELOG.md` exists → pending = entries above the newest entry of the
      service's copy (no copy → all entries pending). Spot-check bullets against the
      template files.
- [ ] No template changelog → structural `diff -u` per template file
      (`docker-compose.yml`, `.env`, `service.sh`, `.gitignore`, config files, `traefik/`).

## 3. Sort and merge (Claude → User for ambiguity)

- [ ] Each change bucketed: **bring over** (structure, new env *variables* with empty/
      generated values) / **do not touch** (real domain, secrets, local tweaks) /
      **report, don't execute** (version pins → hand to
      [update-service](../update-service/SKILL.md)).
- [ ] Ambiguous hunks → ask the user, never guess.
- [ ] Nothing absent-in-template deleted unless a changelog bullet explicitly says removed.

## 4. Apply + validate (Claude)

- [ ] Bring-over edits applied; new secret vars generated or `# TODO`-flagged.
- [ ] `docker compose config --quiet` — clean.
- [ ] Template `CHANGELOG.md` copied over the service's copy (marks state synced).

## 5. Restart safely (Claude)

- [ ] `./service.sh backup pre-template-sync` — before recreating anything.
- [ ] `./service.sh up` (full `down` first only when the change requires it).
- [ ] Verify: `status` (no restart loops), `logs` (clean startup), `curl -k --resolve`
      check when routing/labels changed.
- [ ] On failure: `down` → `borg restore-fresh pre-template-sync` → `up` → report.

## 6. Commit + hand over (Claude)

- [ ] `./service.sh commit "template sync: <very short summary>"`.
- [ ] Summarize: brought over, left untouched, `# TODO`s to fill, and version-pin pointer to
      update-service if applicable.
