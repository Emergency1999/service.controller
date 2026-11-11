# Changelog

## 2026-11-11 — Nextcloud WebDAV whitelist
- parsers/s02-enrich/zz-nextcloud-webdav.yaml: new, whitelist parser that drops successful (status < 400) requests under `/remote.php/dav/` and `/remote.php/webdav/`: a Nextcloud desktop client sync sends them in one burst and `crowdsecurity/http-crawl-non_statics` banned the user (alko, 2026-11-11)
- docker-compose.yml: crowdsec mounts that file read-only to `/etc/crowdsec/parsers/s02-enrich/`

## 2026-11-09 — OnlyOffice asset whitelist
- parsers/s02-enrich/zz-onlyoffice-assets.yaml: new, whitelist parser that drops successful (status < 400) requests under OnlyOffice's versioned asset prefix (`/<version>-<32 hex>/`, fonts, dictionaries, plugins.json): opening a document loads them in one burst and `crowdsecurity/http-crawl-non_statics` banned the user (akadis, 2026-11-09)
- docker-compose.yml: crowdsec mounts that file read-only to `/etc/crowdsec/parsers/s02-enrich/`

## 2026-11-09 — Zammad attachment whitelist
- parsers/s02-enrich/zz-zammad-attachments.yaml: new, whitelist parser that drops successful (status < 400) requests to `/api/v1/ticket_attachment/`: a Zammad ticket view loads its inline attachments in one burst and `crowdsecurity/http-crawl-non_statics` banned the user (akadis, 2026-11-09)
- docker-compose.yml: crowdsec mounts that file read-only to `/etc/crowdsec/parsers/s02-enrich/`

## 2026-11-09 — bouncer self-response whitelist
- parsers/s02-enrich/zz-traefik-bouncer-self-403.yaml: new, whitelist parser that drops access-log lines with `DownstreamStatus` 403 and `OriginStatus` 0 (answered by traefik itself, i.e. the bouncer), so `LePresidente/http-generic-403-bf` no longer re-bans a banned client that retries
- docker-compose.yml: crowdsec mounts that file read-only to `/etc/crowdsec/parsers/s02-enrich/`
- note: after the sync, `up` recreates only crowdsec; check with `cscli metrics show whitelists`

## 2026-11-09 — CrowdSec bouncer
- docker-compose.yml: new container `crowdsec` (image `${CS_REPO}@${CS_CURRENT}`, collection `crowdsecurity/traefik`, environment `BOUNCER_KEY_traefik`, `ENROLL_KEY`, `ENROLL_INSTANCE_NAME` from the `CROWDSEC_*` values in `.env`, docker socket read-only, `./acquis.d` mounted to `/etc/crowdsec/acquis.d`, volumes `./volumes/crowdsec/config` and `./volumes/crowdsec/data`, healthcheck `cscli lapi status`), on the `default` network only
- docker-compose.yml: top-level network `default:` added, traefik joins `default` as well (reaches the LAPI as `http://crowdsec:8080`)
- docker-compose.yml: traefik environment `CROWDSEC_BOUNCER_KEY`; container labels `crowdsec.enable=true`, `crowdsec.labels.type=traefik`; `logging` json-file max-size 100m, max-file 3
- docker-compose.yml: image `traefik:${TRAEFIK_VERSION}` → `${TR_REPO}@${TR_CURRENT}`
- .version: new (`TR` traefik target `v3`, `CS` crowdsecurity/crowdsec target `v1.*.*`); on a host that already has `.version` with `TR`, only the `CS` lines are new
- .env: removed `TRAEFIK_VERSION`; new `CROWDSEC_BOUNCER_KEY`, `CROWDSEC_ENROLL_KEY`, `CROWDSEC_ENROLL_INSTANCE_NAME` (empty placeholders)
- .gitignore: `.version-history.tsv`
- acquis.d/traefik.yaml: new, docker acquisition by container labels
- traefik.yml: `experimental.plugins.bouncer` (github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin v1.8.1) with `abortOnPluginFailure: true`
- traefik.yml: `accessLog` json to stdout with header `User-Agent` kept (replaces the commented accessLog block; the commented `log` block stays)
- traefik.yml: `entryPoints.websecure.http.middlewares: [crowdsec@file]`
- traefik/crowdsec.yml: new, middleware `crowdsec` (plugin bouncer, stream mode, `updateMaxFailure: -1`, LAPI `http://crowdsec:8080`, key from env `CROWDSEC_BOUNCER_KEY`)
- note: traefik needs internet at start (plugin download, `abortOnPluginFailure` needs traefik >= v3.3); with `CROWDSEC_ENROLL_KEY` set, crowdsec needs CAPI reachable at start
