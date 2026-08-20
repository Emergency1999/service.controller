# Euro-Office Document Server — setup

## Overview

Euro-Office is a self-hostable document server: it renders and edits `.docx` / `.xlsx` /
`.pptx` / ODF / PDF files server-side and streams the editor into the browser. Paired with
Nextcloud it provides "Nextcloud Office" — in-place collaborative editing of files stored in
Nextcloud.

It is a **fork of ONLYOFFICE Document Server**, maintained independently to fit sovereign-cloud
deployments; the Nextcloud connector app is literally named *Nextcloud Office* and Nextcloud
promotes Euro-Office as the engine behind it. Because of that lineage, ONLYOFFICE knowledge
transfers almost one-to-one — same environment variables, same API, same JWT handshake.

- Official docs: <https://euro-office.github.io/documentation/>
- Docker install: <https://euro-office.github.io/documentation/installation/docker/>
- Nextcloud integration: <https://euro-office.github.io/documentation/integration/nextcloud/>
- Image: `ghcr.io/euro-office/documentserver` (<https://github.com/Euro-Office/DocumentServer>)
- Connector app: <https://github.com/Euro-Office/eurooffice-nextcloud>

The sources this stack was built from are preserved verbatim in
[docs/upstream-compose.yml](docs/upstream-compose.yml), together with a list of every
deviation and its reason.

> **⚠️ The Nextcloud side is blocked until Nextcloud 33+.**
> See [Prerequisites](#prerequisites) — the document server itself runs fine today.

## Architecture

One container. PostgreSQL, RabbitMQ and Redis run *inside* it, started by the entrypoint under
supervisord.

| Container     | Image                                     | Purpose                                    |
| ------------- | ----------------------------------------- | ------------------------------------------ |
| `euro-office` | `ghcr.io/euro-office/documentserver:<pin>` | nginx + docservice + converter. Serves on 80. |

The entrypoint starts the bundled PostgreSQL, RabbitMQ and Redis only while `DB_HOST`,
`AMQP_HOST` and `REDIS_SERVER_HOST` are still `localhost`. Pointing any of them at another host
switches that dependency to an external service — the route the
[onlyoffice template](../.controller/templates/onlyoffice/) takes with separate postgres and
rabbitmq containers. This service deliberately stays on the bundled variant: one container,
nothing to orchestrate.

**What the bundled database holds:** conversion task results and open-editing-session state.
Documents live in Nextcloud, never here. Its data directory (`/var/lib/postgresql`) is *not*
mounted, so a `docker compose up` that recreates the container starts it empty — the entrypoint
re-applies the schema idempotently on every boot. The practical cost is that editing sessions
open at that moment are dropped; saved documents are untouched. This is why persisting it buys
little, and mounting a volume over that path is riskier than it looks (an empty mount hides the
cluster Debian created at image build time).

Resource floor from the docs: **4 GB RAM minimum, 8 GB recommended**, ~10 GB disk.

### Volumes — and the two you must not mount

Only two paths are bind-mounted:

| Host path        | Container path                | Holds                                              |
| ---------------- | ----------------------------- | -------------------------------------------------- |
| `volumes/data`   | `/var/www/euro-office/Data`   | `.private/` — WOPI keypair, secure-link secret, and a generated JWT secret if none is passed in |
| `volumes/fonts`  | `/usr/share/fonts/custom`     | extra fonts you drop in (empty by default)          |

The upstream docs list two further paths as persistent. **Mounting them breaks the
container** — learned the hard way on 2026-08-20:

- `/var/log/euro-office/documentserver` — the image ships `adminpanel/`, `converter/`,
  `docservice/` and `metrics/` subdirectories owned by `ds:ds`. supervisord validates the
  logfile path of *every* program at startup, the disabled `adminpanel` included, so an empty
  bind mount makes it exit with `The directory named as part of the path
  .../adminpanel/out.log does not exist`. The entrypoint's `exec supervisord` then returns,
  the container exits **0**, and `restart: unless-stopped` loops it forever — regenerating
  fonts on every pass, which looks like a busy container rather than a broken one. This
  entrypoint, unlike ONLYOFFICE's, never creates those subdirectories.
- `/var/lib/euro-office/documentserver` — an empty mount hides the image's `App_Data/` tree
  and puts a root-owned directory in its place, which the `ds` (105:107) processes cannot
  populate. It holds the regenerable conversion cache.

`/etc/euro-office/documentserver` is not mounted either: it carries the nginx templates, and
the entrypoint rewrites `local.json` from the environment on every start.

The practical consequence is that **logs live inside the container** and are lost on a
recreate. Read them while it runs:

```bash
./service.sh dslogs             # docservice (the usual suspect)
./service.sh dslogs converter   # conversion failures
./service.sh dslogs nginx       # internal 502s
./service.sh logs               # entrypoint + supervisord stdout
```

## Configuration (`.env`)

| Variable                 | Kind       | Notes                                                                     |
| ------------------------ | ---------- | ------------------------------------------------------------------------- |
| `DOMAIN`                 | user-set   | `euro-office.example.com`. Needs its **own** subdomain — it cannot share the Nextcloud one. |
| `EURO_OFFICE_VERSION`    | pinned     | `v9.3.3` — current stable at 2026-08-20, amd64 + arm64.                   |
| `TIME_ZONE`              | static     | `Europe/Berlin`. Affects log and document timestamps.                     |
| `EURO_OFFICE_JWT_SECRET` | **secret** | Empty in the template — generate one with `openssl rand -hex 32`. Must match Nextcloud's Office settings exactly. |
| `NEXTCLOUD_URL`          | user-set   | `https://nextcloud.example.com`, no trailing slash. Documentation only — the container never reads it. |

The template ships placeholder values. Before the first start: point `DOMAIN` and
`NEXTCLOUD_URL` at the real hosts and fill `EURO_OFFICE_JWT_SECRET` with a freshly generated
secret.

### Version tags

The docs advertise tags like `9.3.1`, but the registry only carries **`v`-prefixed** tags —
`v9.3.3` resolves, `9.3.3` is a 404. Releases: <https://github.com/Euro-Office/DocumentServer/releases>.
Do not switch to `latest`: an unattended pull could cross a major version while documents are open.

### Settings pinned in `docker-compose.yml`

These are already at their safe defaults in the image; they are spelled out because traefik
publishes this server to the internet and a silent upstream default change would be easy to miss.

| Variable                   | Value   | Why                                                                     |
| -------------------------- | ------- | ----------------------------------------------------------------------- |
| `EXAMPLE_ENABLED`          | `false` | The bundled example app is an unauthenticated upload-and-edit playground. |
| `WOPI_ENABLED`             | `false` | The Nextcloud app uses the ONLYOFFICE-style API, not WOPI.               |
| `ALLOW_PRIVATE_IP_ADDRESS` | `false` | SSRF guard: the server refuses to fetch documents from private addresses. |

`ALLOW_PRIVATE_IP_ADDRESS` only needs flipping if Nextcloud is reachable *solely* over a private
address — e.g. if both ever end up on the same docker host and you point Euro-Office at an
internal hostname. With Nextcloud on a public domain, leave it off.

Upload ceiling is the image default: `MAX_FILE_SIZE=104857600` (100 MB) with a matching
`NGINX_CLIENT_MAX_BODY_SIZE=100m`. Raise both together in `environment:` if someone actually
edits documents larger than that.

## First start

### Prerequisites

1. **DNS** — an `A`/`AAAA` record for `euro-office.example.com` pointing at this server, so traefik
   can obtain a certificate.
2. **A running traefik** with the external `traefik` docker network present.
3. **Nextcloud 33 or newer** — *for the integration step only*. The connector app `eurooffice`
   (v11.0.2) declares `<nextcloud min-version="33" max-version="35"/>`, and the official
   integration page states Nextcloud 34+. On an older Nextcloud the app cannot be installed;
   check with `./service.sh occ status` in the Nextcloud service dir. That upgrade is a separate
   matter — the document server can be started, verified and left running until Nextcloud
   catches up.

```bash
cd $BASE_DIR/euro-office
./service.sh up:logs
```

The first start pulls a large image (~2 GB) and takes a few minutes: the entrypoint boots
PostgreSQL, RabbitMQ, Redis and nginx, then regenerates the font cache.

**Expect the very first attempt to fail once.** The image's baked PostgreSQL cluster was shut
down uncleanly when the image was built, so the first boot runs crash recovery, and the
`syncing data directory (fsync)` pass regularly exceeds `pg_ctl`'s 60-second timeout:

```
pg_ctl: server did not start in time
   ...fail!
euro-office-1 exited with code 1 (restarting)
```

The restart policy handles it — the next attempt finds the datadir already synced and starts
Postgres in a couple of seconds. `PGCTLTIMEOUT` cannot help here: the entrypoint starts
Postgres through `service`, which scrubs the environment. It can recur on any *recreate*,
since the datadir comes fresh from the image every time — though a warm host page cache
usually gets recovery done inside the timeout (the recreate right after this was first
diagnosed did not trip it). A plain `start`/`restart` never does.

A healthy boot ends with `Generating js caches, please wait...Done` followed by no further
restarts. If the log instead cycles through the whole startup every ~30 seconds, the container
is restart-looping — see [troubleshooting](#troubleshooting).

Verify the server before touching Nextcloud:

```bash
./service.sh healthcheck    # -> true
```

`/healthcheck` reports false while AMQP is unreachable, so a `true` means the whole internal
stack is up. If it answers over HTTPS, the server and traefik are fine and any remaining problem
is on the Nextcloud side.

## Post-start — connect Nextcloud

Only possible once Nextcloud is on 33+ (see prerequisites).

```bash
./service.sh connect    # prints the URL and secret to paste
```

1. In Nextcloud: **Apps → Office & text → Nextcloud Office** (`eurooffice`), install it.
2. **Administration settings → Office**.
3. **Document server URL**: `https://euro-office.example.com`
4. **Secret key (JWT)**: the value of `EURO_OFFICE_JWT_SECRET`.
5. Save. Nextcloud handshakes with the server; a green check means JWT and routing both work.
6. Open any document in Files to confirm editing works.

From a Nextcloud service directory the equivalent CLI is:

```bash
./service.sh occ app:install eurooffice
```

### Only one office backend at a time

If a Collabora/`richdocuments` backend already serves the same Nextcloud, note that Nextcloud
registers one handler per office mimetype: running both connector apps at once makes which editor
opens a `.docx` a coin flip. Keep exactly one app enabled — the two *servers* can coexist
happily; it is the Nextcloud apps that collide.

```bash
# in the Nextcloud service dir, when switching
./service.sh occ app:disable richdocuments
./service.sh occ app:enable eurooffice
```

## Maintenance

### Upgrades

```bash
# check the current tag: https://github.com/Euro-Office/DocumentServer/releases
sed -i 's/^EURO_OFFICE_VERSION=.*/EURO_OFFICE_VERSION=v<new>/' .env
./service.sh pull
./service.sh up
```

The container rebuilds its configuration from the environment on every start, so an upgrade is
a recreate — no migration step. Rolling back means putting the old tag back. Keep the connector
app in Nextcloud roughly in step with the server major version.

### Backup

`./service.sh borg backup <name>` captures the stack files plus `volumes/`, which is all of
`volumes/data` (a few hundred bytes of `.private/`) and `volumes/fonts` (whatever you put
there). Everything else this service touches — the conversion cache, the internal Postgres,
the logs — lives inside the container and is rebuilt on start. A restore is therefore close to
re-scaffolding with the same `.env`.

Run `./service.sh borg init` once after the first successful start — `docker_up` enrolls the
service in nightly autobackup automatically, and the repo has to exist by then.

### Custom fonts

Drop `.ttf` / `.otf` files into `volumes/fonts/` and restart; the entrypoint rebuilds the font
cache on every boot and the editors pick them up. The directory is empty by default, which is
fine — system fonts are unaffected because the mount lands on `/usr/share/fonts/custom` rather
than over the whole font tree.

## Troubleshooting

| Symptom                                               | Cause                                                                     |
| ----------------------------------------------------- | ------------------------------------------------------------------------- |
| Nextcloud: "Error while downloading the document"      | JWT secret mismatch between `.env` and the Office admin settings           |
| 502 from traefik                                      | `loadbalancer.server.port=80` label lost — the image has no `EXPOSE`, so traefik cannot guess |
| 404 from traefik                                      | container not on the external `traefik` network, or DNS not pointing here  |
| `/healthcheck` returns false                          | bundled RabbitMQ did not come up; check the log for `await_startup`        |
| Container restart-loops, exit code 0, fonts regenerate every ~30s | supervisord could not validate a program's logfile path — a bind mount is hiding the image's log subdirs (see [Volumes](#volumes--and-the-two-you-must-not-mount)) |
| First boot fails with `pg_ctl: server did not start in time` | Expected once per recreate: crash recovery on the image's Postgres datadir outruns the 60s timeout; the automatic restart succeeds |
| 502 with an **nginx**-branded error page               | The request reached the container, so traefik is fine — the internal docservice is down. `./service.sh dslogs` |
| Editor loads then hangs at "Connecting…"              | websocket blocked upstream                                                |
| Nextcloud can't reach the server, "connection refused" | Nextcloud only reachable on a private IP → `ALLOW_PRIVATE_IP_ADDRESS`      |
| App store won't install `eurooffice`                   | Nextcloud older than 33 (see prerequisites)                                |
| Editors show boxes instead of glyphs                   | font cache stale — restart the container                                   |

Routing can be tested independently of DNS:

```bash
curl -k --resolve euro-office.example.com:443:127.0.0.1 https://euro-office.example.com/healthcheck
```
