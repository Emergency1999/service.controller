# Update-Service Checklist

Follow top to bottom. Each step says **who runs it**. The phase numbers refer to
[SKILL.md](SKILL.md) — re-read its rules first, especially "no downtime without a go-ahead"
and "backup before touching anything".

## 1. Identify (Claude, read-only)

- [ ] Current `*_VERSION` pins from `$BASE_DIR/<service>/.env`; note the main app version.
- [ ] Originating template from the first git commit message (fallback: folder-name match /
      ask the user).
- [ ] Read `docker-compose.yml` (every image), `SETUP.md`, `UPDATE.md`, service `CHANGELOG.md`
      copy — whichever exist.

## 2. Template drift check (Claude → User)

- [ ] Compare `templates/<t>/CHANGELOG.md` with the service's copy (entries above the
      service's newest entry = pending); no changelog → structural `diff -u` fallback.
- [ ] Pending template changes → list them and **ask** whether to run
      [update-service-from-template](../update-service-from-template/SKILL.md) first.
      Never silently mix template sync into the upgrade.

## 3. UPDATE.md (Claude)

- [ ] Exists → read and follow it.
- [ ] Missing → research version/changelog sources (official only) and create it per the
      Phase 3 skeleton.

## 4. Research (Claude, read-only)

- [ ] Newest stable tag for **every** image; arch verified when in doubt.
- [ ] Release notes read across the **whole range** current → target; breaking changes and
      required edits captured.
- [ ] Companion bumps classified tag-only vs **procedural** (db major = dump/restore,
      report-and-ask).

## 5. Plan + confirm (Claude → User)

- [ ] Present version table (current → target), breaking changes + concrete edits,
      procedural steps, expected downtime.
- [ ] **Go-ahead received.** No `down` before this point. Deferred bumps noted in `UPDATE.md`.

## 6. Execute (Claude)

- [ ] `./service.sh down`
- [ ] `./service.sh backup last-<current-version>` — before any edit.
- [ ] Bump `.env` versions, apply breaking-change edits, regenerate config where used.
- [ ] `docker compose config --quiet` — clean.
- [ ] `./service.sh pull` then `./service.sh up` (in that order).

## 7. Verify (Claude)

- [ ] `status` — all `Up`, no restart loops (re-check after a minute).
- [ ] `logs` — migrations clean, no error spam.
- [ ] `curl -k --resolve <domain>:443:127.0.0.1 https://<domain>` — app responds.
- [ ] App-specific checks from `UPDATE.md`; UI/API shows the target version.
- [ ] On failure beyond quick fix-forward: `down` →
      `borg restore-fresh last-<old-version>` → `up` → report.

## 8. Finalize (Claude)

- [ ] `UPDATE.md`: new current version, last-checked date, newly learned upgrade rules;
      `SETUP.md` only if documented behavior changed.
- [ ] `./service.sh commit "upgrade-to-<new-version>"` (or a very short message like
      `"versions extracted"` for non-version changes).
- [ ] Service has a template → **ask** whether to run
      [templatize-service](../templatize-service/SKILL.md) now. If yes: its `CHANGELOG.md`
      entry gets one short `note:` bullet per figured-out upgrade fact (renamed vars,
      required settings, version couplings) — nothing beyond what a future upgrade needs.
