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

commands+=([users]="[<command>]:manage users, grants and tokens (interactive console if no command)")
cmd_users() {
  local action_file rc=0 apply=0 commit=0 message=""

  # users.py edits auth.env; `up` and `git commit` stay here, where those functions live.
  # It reports back through this file instead of shelling out to service.sh again.
  action_file=$(mktemp)
  UA_ACTION_FILE="$action_file" python3 $SERVICE_DIR/users.py "$@" || rc=$?

  if [[ -s $action_file ]]; then
    while IFS="=" read -r key value; do
      case "$key" in
        apply) apply="$value" ;;
        commit) commit="$value" ;;
        message) message="$value" ;;
      esac
    done <"$action_file"
  fi
  rm -f "$action_file"

  [[ $rc -ne 0 ]] && return $rc

  if [[ $apply == 1 ]]; then
    echo
    cmd_docker up
  fi
  if [[ $commit == 1 ]]; then
    echo
    cmd_git commit "${message:-update users}"
  fi
  return 0
}

commands+=([ntfy]="<command>:run the ntfy CLI inside the container (user, access, token, ...)")
cmd_ntfy() {
  # check if ntfy is running
  docker compose ps ntfy &>/dev/null || { echo "ntfy is not running"; return 1; }

  docker compose exec ntfy ntfy "$@"
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
