# Euro-Office Document Server

Fork of ONLYOFFICE Document Server (same env vars, API, JWT handshake — ONLYOFFICE knowledge
transfers). Bundled variant: PostgreSQL, RabbitMQ and Redis run *inside* the one container.
Documents live in Nextcloud, never here.

## Links

- Official docs: <https://euro-office.github.io/documentation/>
- Docker install: <https://euro-office.github.io/documentation/installation/docker/>
- Nextcloud integration: <https://euro-office.github.io/documentation/integration/nextcloud/>
- Image: `ghcr.io/euro-office/documentserver` (<https://github.com/Euro-Office/DocumentServer>)
- Connector app: <https://github.com/Euro-Office/eurooffice-nextcloud>
- Unmodified upstream compose + deviation list: [docs/upstream-compose.yml](docs/upstream-compose.yml)

## First run

- Before the first start: point `DOMAIN` and `NEXTCLOUD_URL` at the real hosts and fill
  `EURO_OFFICE_JWT_SECRET` (`openssl rand -hex 32`). The service needs its **own subdomain** —
  it cannot share the Nextcloud one. Resource floor per docs: 4 GB RAM minimum, 8 GB
  recommended.
- **Expect the very first boot after a recreate to fail once**: crash recovery on the image's
  baked Postgres datadir outruns `pg_ctl`'s 60 s timeout (`server did not start in time`,
  exit 1). The restart policy handles it; the second attempt succeeds. A healthy boot ends
  with `Generating js caches, please wait...Done` and no further restarts.
- Verify before touching Nextcloud: `./service.sh healthcheck` → `true` (false while the
  bundled RabbitMQ is still down).
- **Connect Nextcloud** (needs Nextcloud 33+, see quirks): `./service.sh connect` prints URL +
  secret → in Nextcloud install the `eurooffice` app (*Apps → Office & text → Nextcloud
  Office*, or `occ app:install eurooffice`), then *Administration settings → Office*: Document
  server URL `https://<your-domain>`, JWT secret = `EURO_OFFICE_JWT_SECRET`. Green check =
  JWT and routing work; open a document to confirm.

## Quirks

- **Nextcloud 33+ required for the connector** — the `eurooffice` app declares
  `min-version="33"` (docs say 34+). On an older Nextcloud the app cannot be installed
  (check with `./service.sh occ status` in the Nextcloud service dir); the document server
  itself runs fine meanwhile.
- **Do not mount** `/var/log/euro-office/documentserver` or
  `/var/lib/euro-office/documentserver` (upstream docs list them as persistent — learned the
  hard way): an empty log mount hides the `ds:ds` subdirs supervisord validates, making the
  container exit 0 and restart-loop (symptom: fonts regenerate every ~30 s); an empty lib
  mount hides `App_Data/` behind a root-owned dir the `ds` user can't populate. Only
  `volumes/data` (WOPI keys + JWT fallback secret) and `volumes/fonts` are mounted.
- **Logs live inside the container** (lost on recreate): `./service.sh dslogs` (docservice),
  `dslogs converter`, `dslogs nginx`, plus `./service.sh logs` for the entrypoint.
- The internal DB holds only conversion results and open-editing sessions — a recreate starts
  it empty (schema re-applied on boot); open sessions drop, saved documents are untouched. A
  borg restore is therefore close to re-scaffolding with the same `.env`.
- **One office backend at a time in Nextcloud**: `richdocuments` (collabora) and `eurooffice`
  both grab the office mimetypes — keep exactly one *app* enabled
  (`occ app:disable richdocuments` / `app:enable eurooffice`); the two servers can coexist.
- Safety pins in compose, keep them: `EXAMPLE_ENABLED=false` (unauthenticated playground),
  `WOPI_ENABLED=false` (connector uses the ONLYOFFICE-style API),
  `ALLOW_PRIVATE_IP_ADDRESS=false` (SSRF guard — only flip if Nextcloud were reachable solely
  via a private address).
- Upload ceiling: `MAX_FILE_SIZE` (100 MB) and `NGINX_CLIENT_MAX_BODY_SIZE` must be raised
  **together**.
- Troubleshooting, tested via
  `curl -k --resolve <your-domain>:443:127.0.0.1 https://<your-domain>/healthcheck`:
  - Nextcloud "Error while downloading the document" → JWT secret mismatch.
  - 502 from traefik → missing `loadbalancer.server.port=80` label (image has no `EXPOSE`).
  - 502 with an **nginx**-branded page → internal docservice down, `./service.sh dslogs`.
  - Editor hangs at "Connecting…" → websocket blocked upstream.
  - Boxes instead of glyphs → stale font cache, restart (custom fonts: drop into
    `volumes/fonts/`, rebuilt on every boot).
