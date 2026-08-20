# Update info — paperless

## Version sources

| Image | Pinned by | Releases / changelog | Breaking changes |
|---|---|---|---|
| ghcr.io/paperless-ngx/paperless-ngx | `PAPERLESS_VERSION` | https://github.com/paperless-ngx/paperless-ngx/releases | release notes "Breaking changes" section; majors get a migration guide, e.g. https://docs.paperless-ngx.com/migration-v3/ |
| docker.io/library/postgres | `POSTGRES_VERSION` | https://www.postgresql.org/support/versioning/ | major bump = dump/restore, never a tag change |
| docker.io/library/redis | `REDIS_VERSION` | https://github.com/redis/redis/releases | major bump only; cache-only use, data is disposable |
| docker.io/gotenberg/gotenberg | `GOTENBERG_VERSION` | https://github.com/gotenberg/gotenberg/releases | CLI flags occasionally deprecated — verify the flags in `command:` still exist |
| docker.io/apache/tika | `TIKA_VERSION` | https://hub.docker.com/r/apache/tika/tags | stateless; use full `x.y.z.w` stable tags, never `*-SNAPSHOT` / `-beta` |

## Version scheme / upgrade rules

- **paperless-ngx majors require a specific stepping-stone version.** v3 could only be entered
  from **2.20.15**. Check the migration guide for the required predecessor before any major bump.
- **`PAPERLESS_DBENGINE` must be set explicitly** (since v3). Its default is `sqlite` — omitting
  it on a PostgreSQL stack silently starts against an empty database and looks like data loss.
- **`PAPERLESS_SECRET_KEY` is required** (since v3) and must never be rotated during an
  upgrade — existing sessions and tokens are signed with it.
- Postgres and Redis are pinned to **major-only floating tags** (`17`, `8`), so `pull` picks up
  patch releases automatically. A major bump is a deliberate, procedural decision.
- Gotenberg's `command:` flags (`--chromium-disable-javascript`, `--chromium-allow-list`) are
  verified per upgrade with:
  `docker run --rm --entrypoint gotenberg gotenberg/gotenberg:<tag> --help`
- Tika's Docker Hub tag list is ordered by date, so SNAPSHOT/beta tags appear above the newest
  stable — pick the newest plain `x.y.z.w`.
- v3 needs a CPU with **SSE4.2 / x86-64-v2** (NumPy 2.4 baseline). On older hardware set
  `PAPERLESS_TRAIN_TASK_CRON=disable`.
- Document/thumbnail encryption was removed in v3 — run `decrypt_documents` *before* upgrading
  if any document has `storage_type = 'encrypted'`.

## Post-upgrade checks

- `./service.sh status` — all five containers `Up`, webserver `healthy`, no restart loops.
- `./service.sh logs` — migrations applied, search index rebuild finished, no error spam.
- Document count unchanged — the fastest proof the app is on the real database and not a
  fresh SQLite one:
  `docker exec <project>-db-1 psql -U paperless -d paperless -t -c "select count(*) from documents_document;"`
- Version check:
  `docker exec <project>-webserver-1 python3 -c "from paperless.version import __full_version_str__ as v; print(v)"`
- HTTPS: `curl -k --resolve ${DOMAIN}:443:127.0.0.1 https://${DOMAIN}/`
- Full-text search returns hits (proves the index was rebuilt, not just created empty).
  `documents.index` was removed in v3 — probe through the API instead:
  ```
  docker exec <project>-webserver-1 python3 manage.py shell -c "
  from django.test import Client; from django.contrib.auth.models import User
  c = Client(); c.force_login(User.objects.filter(is_superuser=True).first())
  print(c.get('/api/documents/', {'query': 'rechnung'}).json()['count'])"
  ```
- **OIDC login works.** `PAPERLESS_DISABLE_REGULAR_LOGIN=True` makes the identity provider the
  *only* way into the UI, and OIDC-provisioned superusers have no usable password. Test that a
  CSRF-valid POST to `/accounts/oidc/<provider_id>/login/` 302s to the provider.
  - If it fails with `invalid_client`, add `"token_auth_method": "client_secret_basic"` to the
    provider `settings` block in `PAPERLESS_SOCIALACCOUNT_PROVIDERS`.
  - Locked out? Recovery never needs the UI: `./service.sh createsuperuser`, plus
    `PAPERLESS_DISABLE_REGULAR_LOGIN=False` temporarily.

## Known upgrade notes

- **2.20.15 → 3.0.5** — search backend Whoosh → tantivy (index rebuilds automatically on first
  boot; no manual reindex). Checksums MD5 → SHA256. Task history is cleared. Duplicates are
  accepted by default; `PAPERLESS_CONSUMER_DELETE_DUPLICATES=true` restores the 2.x rejection.
  Search syntax changed: `note:` → `notes.note:`, `custom_field:` → `custom_fields.value:`.
  Settings removed/renamed in v3: `CONSUMER_POLLING` → `CONSUMER_POLLING_INTERVAL`,
  `CONSUMER_INOTIFY_DELAY` → `CONSUMER_STABILITY_DELAY`, `OCR_SKIP_ARCHIVE_FILE` →
  `ARCHIVE_FILE_GENERATION`, `CONSUMER_BARCODE_SCANNER` removed.

## Status

- Template pins: paperless **3.0.5**, postgres **17**, redis **8**, gotenberg **8.36.0**,
  tika **3.3.1.0** — last checked: 2026-08-20
- Deferred: **postgres 18** (released 2025-09-25). Staying on 17 (EOL 2029-11-08); a major
  bump needs a dump/restore cycle, not a tag change.
