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

commands+=([createsuperuser]=":Creates a superuser for the Paperless instance")
cmd_createsuperuser() {
  docker compose run --rm webserver createsuperuser
}

commands+=([refreshcollation]=":Refreshes the database collation version")
cmd_refreshcollation() {
  docker compose exec db psql -U paperless -d paperless -c "ALTER DATABASE paperless REFRESH COLLATION VERSION;"
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
