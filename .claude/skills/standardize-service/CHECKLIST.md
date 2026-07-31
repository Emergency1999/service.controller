# Standardization Checklist

Work through this top-to-bottom on the compose stack being standardized. Every step is
Claude's — file edits only, nothing here starts or stops containers. The §-references point
at the rule sections in [SKILL.md](SKILL.md); read those first, they hold the detail.

## docker-compose.yml

- [ ] §0 — Remove the obsolete top-level `version:` key.
- [ ] §1 — Remove every `container_name:`; update references in `links:`, `depends_on:`, and
      env values to use service names instead.
- [ ] §2 — Comment out all `ports:` sections (keep them as documentation).
- [ ] §3 — Two-network model: top-level `default:` + external `traefik:`; webserver on both;
      services on only `default` get no explicit `networks:` at all.
- [ ] §4 — Traefik labels on the webserver only; router rule on `Host(${DOMAIN})`,
      entrypoint `websecure`; legacy `*_DOMAIN` vars standardized to `DOMAIN`; loadbalancer
      port label added when the internal port isn't 80.
- [ ] §4b — Anything labels can't express (forwardAuth middlewares, custom routers, TLS
      options) moved to `traefik/` file-provider YAMLs, referenced as `<name>@file`.
- [ ] §5 — Every image referenced as `image: x:${X_VERSION}` (no fallback value); the pin
      moved to `.env` (empty value if the source had no pin).
- [ ] §6 — `restart: unless-stopped` on every service.
- [ ] §7 — All volume mounts under `./volumes/`; named volumes converted to bind mounts and
      the then-unused top-level `volumes:` block deleted.

## Environment

- [ ] §8 — Every variable classified: container-specific non-secret → inline `environment:`;
      host-specific/secret → `.env` + `${VAR}` interpolation; `env_file:` only where a service
      directly consumes many `.env` vars at runtime.
- [ ] §9 — Timezone extracted to `.env` as `TIME_ZONE`, referenced as `${TIME_ZONE}` where
      already in use.

## Validation

- [ ] `docker compose config --quiet` passes (empty-variable warnings OK, errors not).
- [ ] Spot-compare against the [nextcloud template](../../../templates/nextcloud/) — the
      standards-compliant reference.
- [ ] Every bullet of the Validation list at the end of [SKILL.md](SKILL.md) holds.
