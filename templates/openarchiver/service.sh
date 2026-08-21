#!/bin/bash
set -e

SERVICE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
cd $SERVICE_DIR

# CORE
source ../.env
source ../$CORE_DIR_NAME/core.sh

# VARIABLES
set -o allexport
# set variables for docker or other services here
# BORG_AUTOBACKUP_AUTO_ENABLE=1 # set to 0 to disable enabling/disabling autobackup on docker up/down
set +o allexport

# COMMANDS

# Hit the upstream OpenArchiver REST API from inside the MCP container.
# Uses the API key & base URL already in the MCP container's env (via httpx,
# since the slim image has no curl), so this is the exact surface the MCP
# server sees.
commands+=([oa-get]="<path>:GET against OpenArchiver REST API from inside the MCP container")
cmd_oa-get() {
  local path="$1"
  if [[ -z "$path" ]]; then
    echo "Usage: ./service.sh oa-get <path>" >&2
    echo "  e.g. ./service.sh oa-get /dashboard/stats" >&2
    echo "       ./service.sh oa-get '/search?keywords=invoice&page=1&limit=5'" >&2
    return 1
  fi
  docker compose -p $SERVICE_DIR_NAME exec -T -e DEBUG_PATH="$path" \
    openarchiver-mcp python -c '
import os, time, httpx
path = os.environ["DEBUG_PATH"]
url = os.environ["OPENARCHIVER_BASE_URL"].rstrip("/") + path
t0 = time.monotonic()
try:
    r = httpx.get(url, headers={"X-API-KEY": os.environ["OPENARCHIVER_API_KEY"]}, timeout=30.0)
    body = r.text
    print(body[:4000])
    print(f"--- HTTP {r.status_code} bytes={len(r.content)} elapsed={time.monotonic()-t0:.2f}s")
except httpx.TimeoutException as e:
    print(f"TIMEOUT after {time.monotonic()-t0:.2f}s: {e}")
except Exception as e:
    print(f"ERROR {type(e).__name__}: {e}")
'
}

# Run a Python snippet inside the MCP container to call a tool function
# directly. Bypasses the MCP transport, so this isolates "is the tool logic
# itself OK?" from "is the transport stalling?".
commands+=([mcp-call]="<tool-name> [kwargs-json]:Invoke an MCP tool function directly (no transport) inside the MCP container")
cmd_mcp-call() {
  local tool="$1"; shift || true
  local kwargs="$1"
  [[ -z "$kwargs" ]] && kwargs='{}'
  if [[ -z "$tool" ]]; then
    echo "Usage: ./service.sh mcp-call <tool-name> [kwargs-json]" >&2
    echo "  e.g. ./service.sh mcp-call dashboard_stats" >&2
    echo "       ./service.sh mcp-call search_emails '{\"keywords\":\"invoice\",\"limit\":3}'" >&2
    return 1
  fi
  docker compose -p $SERVICE_DIR_NAME exec -T \
    -e DEBUG_TOOL="$tool" -e DEBUG_KWARGS="$kwargs" \
    openarchiver-mcp python -c '
import asyncio, json, os, time, server
tool = os.environ["DEBUG_TOOL"]
kwargs = json.loads(os.environ.get("DEBUG_KWARGS") or "{}")
fn = getattr(server, tool)
t0 = time.monotonic()
try:
    result = asyncio.run(asyncio.wait_for(fn(**kwargs), timeout=45))
    body = json.dumps(result, default=str, indent=2)
    print(body[:4000])
    if len(body) > 4000:
        print(f"... [truncated, total {len(body)} bytes]")
except asyncio.TimeoutError:
    print("TIMEOUT after 45s")
except Exception as e:
    print(f"ERROR {type(e).__name__}: {e}")
print(f"--- elapsed {time.monotonic()-t0:.2f}s")
'
}

# ATTACHMENTS

# OpenArchiver's SvelteKit frontend has three issues for our use case that get
# baked into the production bundle (content-hashed JS chunks under
# /app/packages/frontend/build/...). Patch them all in-place after every
# container start so the fix survives image pulls / recreates.
#
# Issue 1 — cookie `samesite=strict`:
#   The accessToken cookie is set via `document.cookie = ...; samesite=strict`,
#   so the browser won't send it on cross-site top-level navigations (clicks
#   from claude.ai land you on /signin). Lax allows top-level GET nav while
#   keeping CSRF protection.
#
# Issue 2 — /dashboard/+layout.server.ts redirect drops the URL:
#   When `locals.user` is null, it bounces to "/signin" without remembering
#   where the user was trying to go. Patch the destructure to include `url`
#   and append "?redirect=<encoded current path>" so the login form can send
#   the user back.
#
# Issue 3 — /signin always goes to /dashboard after login:
#   The success handler hard-codes `goto("/dashboard")`. Patch it to honor a
#   safe `?redirect=` query param (relative path only — no //, no http://).
att_post-start() {
  local cid
  cid=$(docker compose -p $SERVICE_DIR_NAME ps -q openarchiver)
  if [[ -z "$cid" ]]; then
    echo "[OPENARCHIVER] container not running, skipping bundle patches" >&2
    return 0
  fi

  # ---- Issue 1: samesite=strict -> samesite=lax ----
  local files
  files=$(docker exec "$cid" sh -c 'grep -rlF "samesite=strict" /app/packages/frontend/build/client/_app/immutable/chunks 2>/dev/null' || true)
  if [[ -z "$files" ]]; then
    echo "[OPENARCHIVER] cookie patch: nothing to do (already lax or upstream changed)"
  else
    echo "$files" | while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      docker exec "$cid" sed -i 's/samesite=strict/samesite=lax/g' "$f"
      echo "[OPENARCHIVER] cookie patch: $f"
    done
  fi

  # ---- Issue 2: dashboard layout drops the URL on bounce to /signin ----
  # Match `({ locals }) => { ... if (!locals.user) { ... redirect(302, "/signin")` and
  # rewrite to carry the current path as ?redirect=<encoded>.
  local layout_files
  layout_files=$(docker exec "$cid" sh -c 'grep -rl "if (!locals.user)" /app/packages/frontend/build/server/chunks 2>/dev/null | grep -v "\.map$"' || true)
  if [[ -z "$layout_files" ]]; then
    echo "[OPENARCHIVER] layout-redirect patch: no matching server chunk found"
  else
    echo "$layout_files" | while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      # Skip if already patched.
      if docker exec "$cid" grep -qF '"/signin?redirect="' "$f"; then
        echo "[OPENARCHIVER] layout-redirect patch: already patched in $f"
        continue
      fi
      docker exec "$cid" sed -i \
        -e 's|const load = async ({ locals }) => {|const load = async ({ locals, url }) => {|' \
        -e 's|throw redirect(302, "/signin");|throw redirect(302, "/signin?redirect=" + encodeURIComponent(url.pathname + url.search));|' \
        "$f"
      echo "[OPENARCHIVER] layout-redirect patch: $f"
    done
  fi

  # ---- Issue 3: /signin should honor ?redirect= after successful login ----
  # The minified login handler ends with `<store>.login(<a>,<b>),<goto>("/dashboard")`.
  # Rewrite the goto target to read a safe `redirect` query param.
  local login_files
  login_files=$(docker exec "$cid" sh -c 'grep -rlE "\.login\([a-zA-Z_]+\.accessToken,[a-zA-Z_]+\.user\),[a-zA-Z_]+\(\"/dashboard\"\)" /app/packages/frontend/build/client/_app/immutable 2>/dev/null | grep -v "\.map$"' || true)
  if [[ -z "$login_files" ]]; then
    echo "[OPENARCHIVER] login-redirect patch: no matching client chunk found (already patched or upstream changed)"
  else
    echo "$login_files" | while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      # The replacement uses an IIFE so we can validate the redirect target
      # client-side: only same-origin relative paths starting with a single
      # `/` are accepted, defending against ?redirect=//evil.com or full URLs.
      docker exec "$cid" sed -i -E \
        's|(\.login\([a-zA-Z_]+\.accessToken,[a-zA-Z_]+\.user\),[a-zA-Z_]+)\("/dashboard"\)|\1((function(){var r=new URLSearchParams(location.search).get("redirect");return r\&\&r.charAt(0)=="/"\&\&r.charAt(1)!="/"?r:"/dashboard";})())|' \
        "$f"
      echo "[OPENARCHIVER] login-redirect patch: $f"
    done
  fi
}

# MAIN
main "$@"
