#!/bin/bash
set -e

SERVICE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
cd $SERVICE_DIR

# CORE
source ../.env
source ../$CORE_DIR_NAME/core.sh

# VARIABLES
set -o allexport
set +o allexport

# HELPERS

set_env_value() {
  local key="$1" value="$2"
  awk -v k="$key" -v v="$value" '
    index($0, k "=") == 1 { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }
  ' .env >.env.tmp
  cat .env.tmp >.env
  rm .env.tmp
}

ensure_admin_key() {
  if [[ -n "$CONVEX_SELF_HOSTED_ADMIN_KEY" ]]; then
    return 0
  fi
  echo "[EVENTPLANNER] Generating CONVEX_SELF_HOSTED_ADMIN_KEY"
  docker compose -p $SERVICE_DIR_NAME up -d --wait eventplanner-convex
  local key
  key=$(docker compose -p $SERVICE_DIR_NAME exec -T eventplanner-convex ./generate_admin_key.sh | tail -n1 | tr -d '\r')
  if [[ -z "$key" ]]; then
    echo "[EVENTPLANNER] Could not generate an admin key" >&2
    return 1
  fi
  set_env_value CONVEX_SELF_HOSTED_ADMIN_KEY "$key"
  export CONVEX_SELF_HOSTED_ADMIN_KEY="$key"
}

# COMMANDS

commands+=([admin-key]=":print the Convex admin key, generate it if empty")
cmd_admin-key() {
  ensure_admin_key
  echo "$CONVEX_SELF_HOSTED_ADMIN_KEY"
}

commands+=([authentik]=":print the authentik provider settings")
cmd_authentik() {
  echo "[EVENTPLANNER] OAuth2/OpenID provider, client type: Public"
  echo "[EVENTPLANNER]   Redirect URIs: https://$DOMAIN/auth/callback"
  echo "[EVENTPLANNER]                  https://$DOMAIN/auth/silent-callback"
  echo "[EVENTPLANNER]   Scopes:        openid, profile, email, offline_access, groups"
  echo "[EVENTPLANNER]   Admin group:   $PUBLIC_AUTHENTIK_ADMIN_GROUP"
}

# ATTACHMENTS

# the app needs the admin key at start, which only a running backend can issue
att_pre-start() {
  ensure_admin_key
}

# MAIN
main "$@"
