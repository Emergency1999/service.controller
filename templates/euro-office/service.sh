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
set +o allexport

# COMMANDS

commands+=([healthcheck]=":ask the document server whether it is ready")
cmd_healthcheck() {
  echo "[EURO-OFFICE] GET https://$DOMAIN/healthcheck"
  curl -fsS "https://$DOMAIN/healthcheck"
  echo
}

commands+=([connect]=":print the values to enter in Nextcloud's Office settings")
cmd_connect() {
  echo "[EURO-OFFICE] Nextcloud: $NEXTCLOUD_URL"
  echo "[EURO-OFFICE]   Administration settings -> Office"
  echo "[EURO-OFFICE]   Document server URL: https://$DOMAIN"
  echo "[EURO-OFFICE]   Secret key (JWT):    $EURO_OFFICE_JWT_SECRET"
}

commands+=([dslogs]="[program]:tail an in-container log (docservice, converter, metrics, nginx)")
cmd_dslogs() {
  prog="${1:-docservice}"
  if [ "$prog" = "nginx" ]; then
    path="/var/log/euro-office/documentserver/nginx.error.log"
  else
    path="/var/log/euro-office/documentserver/$prog/err.log"
  fi
  # The log directory is deliberately not bind-mounted (see docker-compose.yml),
  # so the logs are only readable while the container is running.
  echo "[EURO-OFFICE] $path"
  docker compose -p $SERVICE_DIR_NAME exec euro-office tail -n 50 "$path"
}

# ATTACHMENTS

# Setup function that is called before the docker up command
# att_setup() {
#   echo "Setting up..."
# }

# Configure function that is called before the docker up, start and restart commands
# att_configure() {
#   echo "Configuring..."
# }

# MAIN
main "$@"
