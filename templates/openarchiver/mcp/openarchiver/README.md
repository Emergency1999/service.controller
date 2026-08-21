# OpenArchiver MCP server

A small [FastMCP](https://gofastmcp.com/) server that exposes the OpenArchiver
REST API (`/api/v1`) as MCP tools over streamable-HTTP. Runs as a service in
the parent `docker-compose.yml` and is reachable at
`http://localhost:8765/mcp-${MCP_URL_TOKEN}` (capability URL — see Auth
below). For public hosting, see [DEPLOYMENT.md](DEPLOYMENT.md).

## Auth

Two layers, both enforced by the MCP server itself:

1. **Incoming (client → server) — capability URL.** FastMCP mounts the
   endpoint at `/mcp-${MCP_URL_TOKEN}` (no trailing slash — see note
   below), where `MCP_URL_TOKEN` is a long random secret. Any request to a
   different path returns 404 from FastMCP directly — no reverse-proxy
   auth layer is required, and the secret never has to be parsed/forwarded
   by anything else. The URL **is** the credential; anyone with it can use
   the server.

2. **Upstream (server → OpenArchiver).** The OpenArchiver API key is read
   from `OPENARCHIVER_API_KEY` on startup and attached as `X-API-KEY` to
   every outbound call.

Both env vars are required; the server `sys.exit`s on startup if either is
missing. Set them in a `.env` file alongside `docker-compose.yml`:

```
OPENARCHIVER_API_KEY=<your-openarchiver-api-key>
MCP_URL_TOKEN=<openssl rand -hex 24>
```

The compose service references both as `${VAR:?...}`, so the stack fails
fast if either is unset.

### Capability URL — operator notes

- **No trailing slash.** Mount at `/mcp-<token>`, not `/mcp-<token>/`.
  Starlette would otherwise 307-redirect bare-path POSTs to add the slash,
  and Claude.ai's MCP client treats that redirect as an auth failure and
  starts probing OAuth discovery endpoints.
- HTTPS encrypts the URL path in transit, but the token is still visible at
  the endpoints: Claude's stored connector config, any reverse-proxy access
  log that records request paths, terminal history, screenshots. Treat the
  URL the way you'd treat a password. If your reverse proxy is logging
  access (Traefik does by default), disable or redact logging for this
  router.
- **Rotation:** `openssl rand -hex 24` → update `MCP_URL_TOKEN` in `.env` →
  `docker compose up -d openarchiver-mcp` → update the URL in the Claude.ai
  connector. FastMCP remounts at the new path immediately; the old path
  returns 404.
- This auth model is appropriate for a single-user personal deployment.
  One shared token = no per-user revocation; rotation revokes for everyone.
  If shared, migrate to OAuth (FastMCP `BearerAuthProvider` against an OIDC
  provider's JWKS) — out of scope here.

## Start it

From the repo root:

```
docker compose up -d openarchiver-mcp
docker compose logs -f openarchiver-mcp
```

## Smoke test

```
curl -i -H 'Accept: text/event-stream' "http://localhost:8765/mcp-${MCP_URL_TOKEN}"
```

Expect a 200/SSE response. `curl http://localhost:8765/mcp/` (or any wrong
path) should return 404 — that's the capability URL working.

## Register with Claude Code

```
claude mcp add --transport http openarchiver "http://localhost:8765/mcp-${MCP_URL_TOKEN}"
```

No header needed — both credentials live on the server / in the URL. `/mcp`
in a session should list the server and its tools (search, archived-email,
dashboard, ingestion, storage, jobs).

## Tools

**Search & email read**
- `search_emails(keywords, ...)` — full-text search. Slim hits by default
  (id, sentAt, from, to, subject, snippet, hasAttachments); pass `full=True`
  for the upstream shape. Supports `from_address`, `to_address`,
  `sent_after`, `sent_before` post-filters (case-insensitive substring for
  addresses; ISO-8601 strings for dates). Filtered queries page-walk
  upstream up to ~1000 candidates and report `cap_reached` if more exist.
- `find_emails_by_sender(address, ...)` — convenience wrapper for the most
  common case; uses the address itself as the Meilisearch query and
  post-filters by `from`.
- `list_emails_by_source(ingestion_source_id, ..., full=False)` — same slim
  treatment.
- `get_email(id, include_raw=False)` — returns metadata + decoded
  `bodyText` / `bodyHtml`. Raw RFC 5322 buffer is dropped unless
  `include_raw=True`.
- `get_email_summary(id)` — minimal view (`sentAt`, `from`, `to`, `subject`,
  `hasAttachments`, `bodyText` capped at 20 kB) for cheap reads.
- `delete_email(id)` — mutation; needs `ENABLE_DELETION=true`.

**Dashboard**
- `dashboard_stats`, `dashboard_ingestion_history`, `dashboard_ingestion_sources`, `dashboard_recent_syncs`, `dashboard_indexed_insights`

**Ingestion sources (mutations included)**
- `list_ingestion_sources`, `get_ingestion_source`, `create_ingestion_source`, `update_ingestion_source`, `delete_ingestion_source`, `trigger_import`, `pause_sync`, `force_sync`, `unmerge_source`

**Storage**
- `download_file(path)` — 5 MB cap, returns base64.

**Jobs (Super Admin)**
- `list_queues`, `list_jobs_in_queue`

Tools with side effects have "Mutation" in their docstring. `delete_*` tools
additionally require `ENABLE_DELETION=true` on the OpenArchiver backend.

## Config

| env var | default | purpose |
| --- | --- | --- |
| `OPENARCHIVER_API_KEY` | *(required)* | API key sent as `X-API-KEY` on every upstream call. Server refuses to start if unset. |
| `MCP_URL_TOKEN` | *(required)* | Secret in the MCP endpoint's path. The URL `…/mcp-<token>/` is the credential. Generate with `openssl rand -hex 24`. Server refuses to start if unset. |
| `OPENARCHIVER_BASE_URL` | `http://openarchiver:3000/api/v1` | upstream API root |
| `MCP_HOST` | `0.0.0.0` | bind host |
| `MCP_PORT` | `8765` | bind port |
