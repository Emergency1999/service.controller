"""OpenArchiver MCP server.

Wraps the OpenArchiver REST API (`/api/v1`) as MCP tools over streamable-HTTP.

Auth (two layers, both server-side from this server's perspective):
- Upstream: `OPENARCHIVER_API_KEY` env var → sent as `X-API-KEY` on every
  outbound call.
- Incoming: the MCP endpoint is mounted at `/mcp-${MCP_URL_TOKEN}/`, where
  `MCP_URL_TOKEN` is a long random secret. The URL path IS the credential
  (capability URL). FastMCP itself returns 404 for any other path, so no
  reverse-proxy auth layer is needed.

Both env vars are required at startup; the server fails fast if either is
missing.
"""

from __future__ import annotations

import base64
import email
import email.policy
import os
import sys
from datetime import datetime, timezone
from typing import Any, Callable, Literal

import html2text
import httpx
from fastmcp import FastMCP

BASE_URL = os.environ.get("OPENARCHIVER_BASE_URL", "http://openarchiver:3000/api/v1")
API_KEY = os.environ.get("OPENARCHIVER_API_KEY")
if not API_KEY:
    sys.exit(
        "FATAL: OPENARCHIVER_API_KEY env var is not set. "
        "Set it in docker-compose.yml (via .env interpolation) and restart."
    )

mcp = FastMCP("openarchiver")
_client = httpx.AsyncClient(
    base_url=BASE_URL,
    timeout=30.0,
    headers={"X-API-KEY": API_KEY},
)

_SLIM_FIELDS = {
    "id",
    "timestamp",
    "sentAt",
    "from",
    "to",
    "cc",
    "bcc",
    "subject",
    "attachments",
    "hasAttachments",
    "ingestionSourceId",
    "userEmail",
}
_SUMMARY_BODY_CAP = 20_000


def _slim_attachment(att: Any) -> Any:
    # Upstream populates `content` with the full Tika-extracted text of each
    # attachment (PDFs become 10–30 kB strings). That dwarfs everything else
    # in a search hit and was the reason `search_emails` responses ballooned
    # into the hundreds of kB — large enough that the Claude.ai SSE client
    # appears to hang. Keep the metadata, drop the body.
    if isinstance(att, dict):
        return {k: v for k, v in att.items() if k != "content"}
    return att


def _slim_hit(hit: dict) -> dict:
    out = {k: v for k, v in hit.items() if k in _SLIM_FIELDS}
    if isinstance(out.get("attachments"), list):
        out["attachments"] = [_slim_attachment(a) for a in out["attachments"]]
    # Surface a human-readable ISO timestamp alongside the Unix-ms one.
    ts = out.get("timestamp")
    if isinstance(ts, (int, float)) and "sentAt" not in out:
        out["sentAt"] = datetime.fromtimestamp(ts / 1000, tz=timezone.utc).isoformat()
    return out


def _coerce_raw_bytes(raw: Any) -> bytes | None:
    if raw is None:
        return None
    if isinstance(raw, dict):
        data = raw.get("data", raw)
        if isinstance(data, list):
            return bytes(data)
        if isinstance(data, str):
            return base64.b64decode(data)
        return None
    if isinstance(raw, list):
        return bytes(raw)
    if isinstance(raw, str):
        return base64.b64decode(raw)
    return None


def _decode_email(payload: dict) -> dict:
    raw_bytes = _coerce_raw_bytes(payload.get("raw"))
    if raw_bytes is None:
        return {"bodyText": None, "bodyHtml": None}
    msg = email.message_from_bytes(raw_bytes, policy=email.policy.default)
    text_part: str | None = None
    html_part: str | None = None
    for part in msg.walk():
        ctype = part.get_content_type()
        if ctype == "text/plain" and text_part is None:
            try:
                text_part = part.get_content()
            except Exception:
                text_part = part.get_payload(decode=True).decode(
                    part.get_content_charset() or "utf-8", errors="replace"
                )
        elif ctype == "text/html" and html_part is None:
            try:
                html_part = part.get_content()
            except Exception:
                html_part = part.get_payload(decode=True).decode(
                    part.get_content_charset() or "utf-8", errors="replace"
                )
    body_text = text_part
    if body_text is None and html_part is not None:
        body_text = html2text.html2text(html_part)
    return {"bodyText": body_text, "bodyHtml": html_part}


def _addr_match(hit_value: Any, needle: str) -> bool:
    if hit_value is None:
        return False
    needle_lc = needle.lower()
    if isinstance(hit_value, str):
        return needle_lc in hit_value.lower()
    if isinstance(hit_value, list):
        return any(_addr_match(v, needle) for v in hit_value)
    if isinstance(hit_value, dict):
        return any(
            _addr_match(v, needle)
            for v in hit_value.values()
        )
    return False


def _hit_timestamp_ms(hit: dict) -> int | None:
    ts = hit.get("timestamp")
    if isinstance(ts, (int, float)):
        return int(ts)
    return None


def _iso_to_ms(iso: str) -> int:
    # Accepts "2025-01-01", "2025-01-01T12:00:00", "2025-01-01T12:00:00+00:00".
    dt = datetime.fromisoformat(iso)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return int(dt.timestamp() * 1000)


def _build_predicate(
    *,
    from_address: str | None,
    to_address: str | None,
    sent_after: str | None,
    sent_before: str | None,
) -> Callable[[dict], bool]:
    after_ms = _iso_to_ms(sent_after) if sent_after else None
    before_ms = _iso_to_ms(sent_before) if sent_before else None

    def pred(hit: dict) -> bool:
        if from_address and not _addr_match(hit.get("from"), from_address):
            return False
        if to_address and not _addr_match(hit.get("to"), to_address):
            return False
        if after_ms is not None or before_ms is not None:
            ts = _hit_timestamp_ms(hit)
            if ts is None:
                return False
            if after_ms is not None and ts < after_ms:
                return False
            if before_ms is not None and ts > before_ms:
                return False
        return True

    return pred


async def _paged_filter_search(
    *,
    upstream_params: dict[str, Any],
    predicate: Callable[[dict], bool],
    page: int,
    limit: int,
    full: bool,
    upstream_chunk: int = 50,
    max_upstream_pages: int = 20,
) -> dict:
    needed = page * limit
    matched: list[dict] = []
    upstream_total: int | None = None
    pages_scanned = 0
    cap_reached = False

    for upstream_page in range(1, max_upstream_pages + 1):
        params = {
            **upstream_params,
            "page": upstream_page,
            "limit": upstream_chunk,
        }
        resp = await _request("GET", "/search", params=params)
        pages_scanned += 1
        hits = resp.get("hits", []) if isinstance(resp, dict) else []
        if upstream_total is None and isinstance(resp, dict):
            upstream_total = resp.get("total")
        for h in hits:
            if predicate(h):
                matched.append(h)
        if len(hits) < upstream_chunk:
            break
        if len(matched) >= needed:
            # Keep walking only if we suspect more matches; bail once we have
            # enough for the current page.
            break
    else:
        cap_reached = True

    slice_ = matched[(page - 1) * limit : page * limit]
    return {
        "hits": slice_ if full else [_slim_hit(h) for h in slice_],
        "page": page,
        "limit": limit,
        "total_matched_so_far": len(matched),
        "upstream_pages_scanned": pages_scanned,
        "upstream_total": upstream_total,
        "cap_reached": cap_reached,
    }


async def _request(
    method: str,
    path: str,
    *,
    params: dict[str, Any] | None = None,
    json: Any = None,
) -> Any:
    resp = await _client.request(
        method,
        path,
        params=params,
        json=json,
    )
    if resp.status_code >= 400:
        raise RuntimeError(
            f"OpenArchiver {method} {path} -> {resp.status_code}: {resp.text}"
        )
    if resp.status_code == 204 or not resp.content:
        return None
    ctype = resp.headers.get("content-type", "")
    if "application/json" in ctype:
        return resp.json()
    return resp.text


# --------------------------------------------------------------------------- #
# Search
# --------------------------------------------------------------------------- #


@mcp.tool
async def search_emails(
    keywords: str,
    page: int = 1,
    limit: int = 10,
    matching_strategy: Literal["last", "all", "frequency"] = "last",
    from_address: str | None = None,
    to_address: str | None = None,
    sent_after: str | None = None,
    sent_before: str | None = None,
    full: bool = False,
) -> Any:
    """Full-text search across indexed archived emails (Meilisearch-backed).

    By default returns a SLIM projection of each hit (id, sentAt, from, to,
    subject, snippet, hasAttachments) to keep responses small. Pass
    `full=True` to get the upstream hit shape unchanged.

    OpenArchiver's `/search` does not support filters upstream, so
    `from_address` / `to_address` / `sent_after` / `sent_before` are applied
    by this server *after* fetching upstream pages. When any filter is set,
    pagination is computed against the filtered list (the server walks up to
    ~20 upstream pages of 50 hits = 1000 candidates and reports
    `cap_reached: true` if more candidates exist). Address filters are
    case-insensitive substring matches; date filters compare ISO-8601 strings
    against `sentAt`.

    Requires `search:archive` permission.
    """
    has_filter = any(
        v is not None
        for v in (from_address, to_address, sent_after, sent_before)
    )
    if not has_filter:
        resp = await _request(
            "GET",
            "/search",
            params={
                "keywords": keywords,
                "page": page,
                "limit": limit,
                "matchingStrategy": matching_strategy,
            },
        )
        if not full and isinstance(resp, dict) and "hits" in resp:
            resp = {**resp, "hits": [_slim_hit(h) for h in resp["hits"]]}
        return resp

    return await _paged_filter_search(
        upstream_params={
            "keywords": keywords,
            "matchingStrategy": matching_strategy,
        },
        predicate=_build_predicate(
            from_address=from_address,
            to_address=to_address,
            sent_after=sent_after,
            sent_before=sent_before,
        ),
        page=page,
        limit=limit,
        full=full,
    )


@mcp.tool
async def find_emails_by_sender(
    address: str,
    keywords: str | None = None,
    page: int = 1,
    limit: int = 10,
    sent_after: str | None = None,
    sent_before: str | None = None,
    full: bool = False,
) -> Any:
    """Find archived emails from a specific sender address.

    Convenience wrapper around `search_emails`. Uses `address` as the
    Meilisearch query if no `keywords` are given (much faster than scanning
    the whole index), then post-filters by `from` containing `address`
    (case-insensitive substring).

    Returns slim hits by default; pass `full=True` for upstream hit shape.
    """
    return await _paged_filter_search(
        upstream_params={
            "keywords": keywords if keywords is not None else address,
            "matchingStrategy": "last",
        },
        predicate=_build_predicate(
            from_address=address,
            to_address=None,
            sent_after=sent_after,
            sent_before=sent_before,
        ),
        page=page,
        limit=limit,
        full=full,
    )


# --------------------------------------------------------------------------- #
# Archived email
# --------------------------------------------------------------------------- #


@mcp.tool
async def list_emails_by_source(
    ingestion_source_id: str,
    page: int = 1,
    limit: int = 10,
    full: bool = False,
) -> Any:
    """Paginated list of archived emails for a given ingestion source.

    Slim-projects each hit by default; pass `full=True` for upstream shape.
    Requires `read:archive` permission.
    """
    resp = await _request(
        "GET",
        f"/archived-emails/ingestion-source/{ingestion_source_id}",
        params={"page": page, "limit": limit},
    )
    if not full and isinstance(resp, dict):
        for key in ("hits", "items", "data", "emails"):
            if key in resp and isinstance(resp[key], list):
                resp = {**resp, key: [_slim_hit(h) for h in resp[key]]}
                break
    return resp


@mcp.tool
async def get_email(id: str, include_raw: bool = False) -> Any:
    """Fetch full details for a single archived email.

    By default decodes the RFC 5322 body and strips the (~140 kB) raw byte
    buffer from the response. The returned object has the upstream metadata
    fields plus `bodyText` and `bodyHtml`. Pass `include_raw=True` to keep
    the original `raw` field for forensics / signature verification.

    Requires `read:archive` permission.
    """
    payload = await _request("GET", f"/archived-emails/{id}")
    if not isinstance(payload, dict):
        return payload
    decoded = _decode_email(payload)
    out = dict(payload)
    if not include_raw:
        out.pop("raw", None)
    out["bodyText"] = decoded["bodyText"]
    out["bodyHtml"] = decoded["bodyHtml"]
    return out


@mcp.tool
async def get_email_summary(id: str) -> dict:
    """Minimal email view: headers + decoded text body, capped at 20 kB.

    Returns `{id, sentAt, from, to, subject, hasAttachments, bodyText,
    truncated}`. Use this when you only need to read or summarize the
    message — much smaller than `get_email`.
    """
    payload = await _request("GET", f"/archived-emails/{id}")
    if not isinstance(payload, dict):
        return {"id": id, "error": "unexpected response shape"}
    decoded = _decode_email(payload)
    body = decoded["bodyText"]
    truncated = False
    if isinstance(body, str) and len(body) > _SUMMARY_BODY_CAP:
        body = body[:_SUMMARY_BODY_CAP] + "\n…[truncated]"
        truncated = True
    return {
        "id": payload.get("id", id),
        "sentAt": payload.get("sentAt"),
        "from": payload.get("from") or payload.get("senderEmail"),
        "to": payload.get("to") or payload.get("recipients"),
        "subject": payload.get("subject"),
        "hasAttachments": payload.get("hasAttachments"),
        "bodyText": body,
        "truncated": truncated,
    }


@mcp.tool
async def delete_email(id: str) -> Any:
    """Mutation: permanently delete an archived email.

    Requires `delete:archive` permission, `ENABLE_DELETION=true` on the
    OpenArchiver backend, and the email must not be on legal hold.
    """
    return await _request("DELETE", f"/archived-emails/{id}")


# --------------------------------------------------------------------------- #
# Dashboard
# --------------------------------------------------------------------------- #


@mcp.tool
async def dashboard_stats() -> Any:
    """High-level metrics: total archived emails, storage used, failed
    ingestions in the past week.

    Requires `read:dashboard` permission.
    """
    return await _request("GET", "/dashboard/stats")


@mcp.tool
async def dashboard_ingestion_history() -> Any:
    """Time-series of email ingestion counts over the last 30 days."""
    return await _request("GET", "/dashboard/ingestion-history")


@mcp.tool
async def dashboard_ingestion_sources() -> Any:
    """Summary list of ingestion sources: id, name, provider, status,
    storage usage."""
    return await _request("GET", "/dashboard/ingestion-sources")


@mcp.tool
async def dashboard_recent_syncs() -> Any:
    """Most recent sync sessions across all ingestion sources."""
    return await _request("GET", "/dashboard/recent-syncs")


@mcp.tool
async def dashboard_indexed_insights() -> Any:
    """Top-sender statistics from the search index."""
    return await _request("GET", "/dashboard/indexed-insights")


# --------------------------------------------------------------------------- #
# Ingestion sources
# --------------------------------------------------------------------------- #


@mcp.tool
async def list_ingestion_sources() -> Any:
    """List all accessible ingestion sources (credentials redacted)."""
    return await _request("GET", "/ingestion-sources")


@mcp.tool
async def get_ingestion_source(id: str) -> Any:
    """Fetch a single ingestion source by ID."""
    return await _request("GET", f"/ingestion-sources/{id}")


@mcp.tool
async def create_ingestion_source(payload: dict) -> Any:
    """Mutation: create a new ingestion source and validate the connection.

    `payload` must match the OpenArchiver ingestion-source schema (provider,
    name, credentials, etc.).
    """
    return await _request("POST", "/ingestion-sources", json=payload)


@mcp.tool
async def update_ingestion_source(id: str, payload: dict) -> Any:
    """Mutation: update an existing ingestion source's configuration."""
    return await _request("PUT", f"/ingestion-sources/{id}", json=payload)


@mcp.tool
async def delete_ingestion_source(id: str) -> Any:
    """Mutation: permanently delete an ingestion source (requires
    `ENABLE_DELETION=true`)."""
    return await _request("DELETE", f"/ingestion-sources/{id}")


@mcp.tool
async def trigger_import(id: str) -> Any:
    """Mutation: enqueue a historical email import for the given source."""
    return await _request("POST", f"/ingestion-sources/{id}/import")


@mcp.tool
async def pause_sync(id: str) -> Any:
    """Mutation: pause continuous synchronization for the given source."""
    return await _request("POST", f"/ingestion-sources/{id}/pause")


@mcp.tool
async def force_sync(id: str) -> Any:
    """Mutation: trigger an immediate out-of-schedule sync."""
    return await _request("POST", f"/ingestion-sources/{id}/sync")


@mcp.tool
async def unmerge_source(id: str) -> Any:
    """Mutation: detach a child ingestion source from its merge group."""
    return await _request("POST", f"/ingestion-sources/{id}/unmerge")


# --------------------------------------------------------------------------- #
# Storage
# --------------------------------------------------------------------------- #


_MAX_DOWNLOAD_BYTES = 5 * 1024 * 1024


@mcp.tool
async def download_file(path: str) -> dict:
    """Download a file from OpenArchiver's storage backend (local or S3).

    Requires `read:archive`. The relative storage path is sanitized against
    directory traversal. Files larger than 5 MB are refused — fetch them
    directly via the REST API instead.
    """
    resp = await _client.get(
        "/storage/download",
        params={"path": path},
    )
    if resp.status_code >= 400:
        raise RuntimeError(
            f"OpenArchiver GET /storage/download -> {resp.status_code}: {resp.text}"
        )
    if len(resp.content) > _MAX_DOWNLOAD_BYTES:
        raise ValueError(
            f"File is {len(resp.content)} bytes (>5 MB). Fetch directly via "
            f"the REST API instead of through MCP."
        )
    return {
        "path": path,
        "size": len(resp.content),
        "content_type": resp.headers.get("content-type", "application/octet-stream"),
        "content_base64": base64.b64encode(resp.content).decode("ascii"),
    }


# --------------------------------------------------------------------------- #
# Jobs (Super Admin)
# --------------------------------------------------------------------------- #


@mcp.tool
async def list_queues() -> Any:
    """List all BullMQ job queues with counts per status. Requires Super
    Admin (`manage:all`) permission."""
    return await _request("GET", "/jobs/queues")


@mcp.tool
async def list_jobs_in_queue(
    queue_name: Literal["ingestion", "indexing"],
    status: str | None = None,
    page: int = 1,
    limit: int = 10,
) -> Any:
    """Paginated list of jobs in a queue, optionally filtered by status.

    Requires Super Admin (`manage:all`) permission.
    """
    params: dict[str, Any] = {"page": page, "limit": limit}
    if status is not None:
        params["status"] = status
    return await _request("GET", f"/jobs/queues/{queue_name}", params=params)


if __name__ == "__main__":
    token = os.environ.get("MCP_URL_TOKEN")
    if not token:
        sys.exit(
            "FATAL: MCP_URL_TOKEN env var is not set. Generate one with "
            "`openssl rand -hex 24` and set it in .env. The MCP endpoint is "
            "served only at /mcp-<token>/ — the token IS the credential."
        )
    mcp.run(
        transport="streamable-http",
        host=os.environ.get("MCP_HOST", "0.0.0.0"),
        port=int(os.environ.get("MCP_PORT", "8765")),
        # No trailing slash: Claude.ai (and MCP clients in general) POST to
        # the bare path. Starlette would otherwise 307-redirect from
        # `/mcp-<token>` to `/mcp-<token>/`, which the MCP client treats as
        # auth failure and falls back to OAuth discovery.
        path=f"/mcp-{token}",
    )
