---
name: migrate-traefik-conf
description: 'Migrate a server from the legacy single-folder traefik conf model (traefik-*/conf/) to the new per-service traefik/ subdirectory model that uses the bind-mounted $BASE_DIR/.traefik/ shared directory. Use when a server still has its traefik file-provider YAMLs collected under traefik-<name>/conf/.'
---

# Migrate Traefik Conf to Per-Service `traefik/` Subdirs

## When to Use

A server still uses the **legacy layout** if its traefik service directory (named `traefik-*`,
e.g. `traefik-alko`) has:

- A `conf/` subdirectory containing YAML files, **and**
- A `docker-compose.yml` that mounts `./conf/:/etc/traefik/conf/`.

The **new layout** instead:

- Mounts `../.traefik/:/etc/traefik/conf/` in the traefik service's compose file (the controller
  populates `$BASE_DIR/.traefik/<service>/` via [traefik_link.sh](../../../traefik_link.sh) bind mounts).
- Lives in per-service `traefik/` subdirectories — each service owns the YAMLs that configure
  its own routers/middlewares.
- Uses `${TRAEFIK_VERSION}` from the traefik service's `.env` instead of a hardcoded image tag.

See [standardize-service](../standardize-service/SKILL.md) section 4b for the conceptual model.

## How to apply

Follow the step-by-step checklist in [CHECKLIST.md](CHECKLIST.md). The sections below give the
**rules** the checklist references — read them first, then execute the checklist top-to-bottom.

### Safe migration ordering

Traefik watches `conf/` live, so the checklist is deliberately **copy-first, delete-last** —
the legacy `conf/` stays in place until the mount swap is validated. If validation fails,
reverting the single mount line in the compose file and restarting traefik restores the
pre-migration state with zero loss.

## Concepts (read before acting)

- The traefik service directory is named `traefik-*` and varies per install (e.g. `traefik-alko`,
  `traefik-foo`). Detect it with `ls -d traefik-*` from `$BASE_DIR`. Treat it as `$TRAEFIK_DIR`.
- The bind-mount machinery is already wired into the controller (see
  [traefik_link.sh](../../../traefik_link.sh)). You do **not** need to create `$BASE_DIR/.traefik/`
  manually — it appears the first time a service with a `traefik/` subdir is brought up.
- A file in `$TRAEFIK_DIR/conf/` and a file in `<other-service>/traefik/<file>.yml` end up at
  the **same path inside the container** (`/etc/traefik/conf/...`) — only the host-side mount
  source differs. With the new layout, files surface as
  `/etc/traefik/conf/<service-dir-name>/<file>.yml`. This means `@file` references inside YAMLs
  (e.g. `middlewares: - authentik@file`) keep working unchanged.
- Services that reference each other across the traefik network (e.g. `pretix-pretix@docker`,
  `errorpage-service`) must already be on the `traefik` external network. Migration does **not**
  change network membership.

## Mapping conf files to owning services

Each YAML in `$TRAEFIK_DIR/conf/` must be moved to **one** service's `traefik/` subdir. Read each
file and classify by its content:

| Content pattern | Owning service |
| --- | --- |
| Defines a middleware that other services *consume* via `@file` (e.g. authentik forwardAuth, an oauth proxy) | The service that **provides** the middleware (e.g. `authentik/`). |
| Configures the traefik dashboard / API router | The traefik service itself → `$TRAEFIK_DIR/traefik/`. |
| Generic URL shortcuts / cross-service redirects with no single owning app | The traefik service itself → `$TRAEFIK_DIR/traefik/`. |
| Routers / middlewares that target a specific app's container (e.g. `service: pretix-pretix@docker`, rate-limits on a ticket route) | That app's service dir (e.g. `pretix/traefik/`). |
| A redirect tied to a single product feature of one app | That app's service dir. |

If a file mixes responsibilities (e.g. dashboard config + an unrelated redirect), **split it**
into two files in their respective owning directories rather than copying the whole file twice.

When unsure for a given file, stop and ask the user — wrong placement still works at runtime
(everything lands under `/etc/traefik/conf/`) but defeats the point of the per-service layout.

## docker-compose.yml diff in the traefik service

Two changes:

1. Replace the conf bind mount:
   ```diff
   -      - ./conf/:/etc/traefik/conf/
   +      - ../.traefik/:/etc/traefik/conf/
   ```
2. (Optional but recommended) Move the image tag to `.env`:
   ```diff
   -    image: traefik:v3.6
   +    image: traefik:${TRAEFIK_VERSION}
   ```
   …and add `TRAEFIK_VERSION=v3.6` (or whatever the existing tag was) to `$TRAEFIK_DIR/.env`.

Do **not** touch `traefik.yml` — that file's purpose and location are unchanged.

## Notes / gotchas

- The bind mounts created by `traefik_link.sh` do **not** survive a host reboot — the next
  `./service.sh up` re-creates them. No action required, but if you reboot mid-migration the
  traefik container may briefly see fewer conf files until each service is brought back up.
- File-provider hot reload: traefik watches `/etc/traefik/conf/` recursively and reloads on
  change, so once the mounts are in place you typically don't need to restart the traefik
  container itself for subsequent edits — but the *initial* migration restart is needed because
  the underlying mount source changed.
- Cross-references (`@file`) are global within traefik — a middleware defined in any file under
  `/etc/traefik/conf/` is visible to any router. So you can keep authentik's middleware in
  `authentik/traefik/authentik.yml` and reference it as `authentik@file` from a router defined
  in a totally different service's compose labels.
- If a conf file is template syntax (Go templating, e.g. the `shortcuts.yml`-style files with
  `{{- range ... }}`), it stays template syntax after the move — traefik's file provider
  handles templating regardless of which subdir the file lives in.
