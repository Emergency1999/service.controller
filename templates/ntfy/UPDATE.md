# Update info — ntfy

## Version sources

| Image | Pinned by | Releases / changelog | Breaking changes |
|---|---|---|---|
| binwiederhier/ntfy | `NTFY_TARGET` / `NTFY_CURRENT` (`.version`) | <https://docs.ntfy.sh/releases/> · <https://github.com/binwiederhier/ntfy/releases> | release notes carry a "**Breaking**" bullet when there is one; config deprecations show up in <https://docs.ntfy.sh/config/> |

## Version scheme / upgrade rules

- Semver `v2.x.y`, single image, no database or sidecar to coordinate. `NTFY_TARGET` is the
  wildcard `v2.*.*`, so `./service.sh version upgrade` follows 2.x patch and minor releases
  but never crosses into a v3 major on its own.
- **Cache and user database migrate automatically on start** — no manual migration step.
  The one documented floor: caches written by ntfy **older than v1.10.0** (Nov 2021) can no
  longer be migrated since v2.27.0. Irrelevant for a fresh install, but it
  means a restored ancient backup would need an intermediate version or a wiped `cache.db`.
- **Config is env vars, the changelog talks YAML.** A renamed or new option appears in the
  release notes as `some-option`; translate it to `NTFY_SOME_OPTION` in `docker-compose.yml`.
  Removed options are ignored rather than fatal, so check the logs for warnings after a bump.
- The published `v2` and `latest` tags move — this install pins by digest, so an upgrade is
  always an explicit `version upgrade`.

## Post-upgrade checks

- `./service.sh status` — container `Up` and `healthy` (the healthcheck polls `/v1/health`).
- `./service.sh logs` — `Listening on :80[http]`, no config warnings about unknown options.
- Version actually installed: `./service.sh ntfy --version`
- Auth survived the bump: `./service.sh ntfy user list` still shows the admin, and
  `./service.sh ntfy access` the expected ACL.
- End-to-end through traefik, with a token from `./service.sh ntfy token add`:
  ```bash
  curl -k --resolve ntfy.example.com:443:127.0.0.1 \
       -H "Authorization: Bearer tk_..." -d "upgrade test" https://ntfy.example.com/<topic>
  ```
  Anonymous publishing must fail with 403 — that proves `deny-all` is still in effect.
- Web app: log in, subscribe to a topic, confirm the browser notification prompt still works
  (web push keys unchanged).

## Status

- Current main version: **v2.34.0** — last checked: 2026-10-27
