---
name: standardize-service
description: 'Standardize service templates to match project conventions. Use when converting service templates to use traefik, two-network architecture, .env versioning, and ./volumes mounts.'
---

# Standardize Docker Compose Templates

## When to Use

When adding or updating a service template to align with the project's docker-compose standards (bookstack, default, karakeep, nextcloud patterns).

Also invoked as the standardization phase of [create-service](../create-service/SKILL.md),
[migrate](../migrate/SKILL.md), and [templatize-service](../templatize-service/SKILL.md).

## How to apply

Work through [CHECKLIST.md](CHECKLIST.md) top-to-bottom — it is the tickable execution list
for these rules. The numbered sections below (referenced from the checklist as §0–§9) hold
the detail; read them first.

## Standardization Rules

### 0. Remove Obsolete Keys
- Delete the top-level `version:` key if present (obsolete since Compose v2; upstream examples often still carry it)

### 1. Remove Container Names
- Delete `container_name:` from all service definitions
- Update any references to container names in `links:`, `depends_on:`, or environment variables to use service names instead

### 2. Port Mappings
- Comment out all `ports:` sections
- Keep ports as comments so the port usage remains documented
- Exception: Only uncomment if explicitly needed for traefik or other infrastructure

### 3. Network Architecture
- Define two networks at top level:
  ```yaml
  networks:
    default:
    traefik:
      external: true
  ```
- Add webserver/main service to both networks: `- default` and `- traefik`
- For services only on the `default` network, omit the `networks:` config (default is already implicit)
- Only add explicit `networks:` to services that need `traefik` or custom network membership

### 4. Traefik Labels
- Add traefik labels only to the webserver/main service:
  ```yaml
  labels:
    - "traefik.enable=true"
    - "traefik.http.routers.${COMPOSE_PROJECT_NAME}.rule=Host(`${DOMAIN}`)"
    - "traefik.http.routers.${COMPOSE_PROJECT_NAME}.entrypoints=websecure"
  ```
- Some older templates may have DOMAIN variables like `${PRETIX_DOMAIN}`. Standardize to `${DOMAIN}` for consistency.
- Include service-specific port labels if needed (e.g., karakeep's port 3000)

### 4b. Per-service Traefik file-provider conf (`traefik/` subdir)
For routing or middleware config that compose labels can't express (forwardAuth middlewares,
custom routers, TLS options, etc.), put YAMLs into a `traefik/` subdirectory of the service.
The controller bind-mounts `<service>/traefik/` → `$BASE_DIR/.traefik/<service>/` on `up`, and
the traefik container watches `/etc/traefik/conf/` via its file provider — so files become
available at `/etc/traefik/conf/<service>/<file>.yml`.

- Use this only when labels are insufficient; keep plain host routing in labels.
- Each YAML follows traefik's dynamic-config schema (`http.middlewares`, `http.routers`,
  `http.services`, `tls.options`).
- Reference middlewares from compose labels with the `@file` provider suffix, e.g.
  `traefik.http.routers.${COMPOSE_PROJECT_NAME}.middlewares=authentik@file`.
- Example files live in [`templates/traefik/traefik/`](../../../templates/traefik/traefik/)
  (`authentik.yml`, `dashboard.yml`, `shortcuts.yml`).

### 5. Image Versioning
- Move hardcoded versions to `.env` file
- Update image references to use variables: `image: service:${SERVICE_VERSION}` (do not use a fallback or default value in the compose file)
- The value previously referenced in the compose file should be moved to the `.env` file as the value for the variable.
- If there is no version specified in the original compose file, add the variable to `.env` with an empty value.

### 6. Restart Policy
- Change all `restart:` policies to `restart: unless-stopped`

### 7. Volume Paths
- Change all volume mounts to use `./volumes/` prefix
- Example: `/var/lib/postgresql` → `./volumes/db:/var/lib/postgresql`
- Convert *named volumes* to `./volumes/<name>` bind mounts and delete the then-unused top-level `volumes:` block — data hidden in named volumes lives outside the service dir and is invisible to borg backups

### 8. Environment Variables
- **Inline in `environment:`**: Container-specific configs that are NOT host-specific or private (e.g., internal paths, stack-internal DB URLs, DB passwords for databases hosted within the same stack). Also inline values that can be derived from existing compose variables (e.g., `APP_URL: https://${DOMAIN}`, `HUB_URL: https://${DOMAIN}`).
- **Compose interpolation for secrets**: When a non-primary service needs host-specific or secret values from `.env`, reference them via compose interpolation in `environment:` (e.g., `TOKEN: ${AGENT_TOKEN}`). Prefix variable names in `.env` to clarify which service uses them (e.g., `AGENT_TOKEN`, `AGENT_KEY`). Do NOT use `env_file:` to pass the entire `.env` to a service just for a few variables.
- **Main `.env` file**: For variables used by docker-compose interpolation (`${...}` syntax) such as `DOMAIN`, image versions, `TIME_ZONE`, and host-specific or private/secret values (e.g., `AGENT_TOKEN`, `AGENT_KEY`).
- **Separate `<service>.env` files**: Only create per-service env files (e.g., `agent.env`) when there are **many** host-specific/private variables for a non-primary service that would clutter the shared `.env`. For just a few variables, use compose interpolation instead.
- **`env_file: - .env`**: Only add this to a service if it directly consumes many variables from `.env` at runtime (not via compose interpolation). Prefer explicit `environment:` entries with `${VAR}` references for clarity.
- Do NOT dump all environment variables from all containers into the shared `.env`. If a variable is specific to one container and not host-specific, it belongs inline in `environment:`.
- Rule of thumb: if comments in the original source already group variables per container, that's a signal they should stay inline per container, not be merged into `.env`.

### 9. TIME_ZONE
- Extract timezone settings to `.env` as `TIME_ZONE=Europe/Berlin` or similar
- Update docker-compose to use `${TIME_ZONE}` where already in use

## Example Reference

See the [nextcloud template](../../../templates/nextcloud/) for a complete, standards-compliant example.

## Validation

After standardization:
- `docker compose config --quiet` passes (warnings about empty variables are OK, errors are not)
- No top-level `version:` key and no orphaned named-volume block remain
- No hardcoded image versions remain in docker-compose.yml
- Only the webserver has traefik labels
- Only services on traefik network have explicit `networks:` declaration
- All volumes reference `./volumes/...`
- `.env` file includes all version variables
- Container-specific non-secret configs are inline in `environment:`
- Host-specific/private values are in `.env` via compose interpolation (e.g., `TOKEN: ${AGENT_TOKEN}`); separate `<service>.env` files only when many variables would clutter `.env`
