# Update info — euro-office

## Version sources

| Image | Pinned by | Releases / changelog | Breaking changes |
|---|---|---|---|
| ghcr.io/euro-office/documentserver | `EURO_OFFICE_VERSION` | <https://github.com/Euro-Office/DocumentServer/releases> | release notes; ONLYOFFICE upstream changes usually apply too |

## Version scheme / upgrade rules

- **Tags are `v`-prefixed**: `v9.3.3` resolves, `9.3.3` is a 404 (the docs advertise the bare
  form). Never `latest` — an unattended pull could cross a major while documents are open.
- An upgrade is a plain recreate (config is rebuilt from the environment on every start, no
  migration step); rollback = put the old tag back. Open editing sessions drop on recreate.
- Keep the `eurooffice` Nextcloud connector app roughly in step with the server's major
  version.

## Post-upgrade checks

- First boot after the recreate may fail once (`pg_ctl` timeout — expected, see SETUP.md);
  then `./service.sh healthcheck` → `true`.
- With Nextcloud connected: open a document, edit, save.

## Status

- Current main version: v9.3.3 — last checked: 2026-08-20
