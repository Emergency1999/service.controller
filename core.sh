set -o allexport

BASE_DIR=$(dirname $SERVICE_DIR)
source $BASE_DIR/.env
SERVICE_DIR_NAME=$(basename $SERVICE_DIR)
BORG_REPO="$BORG_REPO_BASE/$SERVICE_DIR_NAME"
CORE_DIR="$BASE_DIR/$CORE_DIR_NAME"
BORG_AUTOBACKUP_AUTO_ENABLE=${BORG_AUTOBACKUP_AUTO_ENABLE:-1}

ensure_git_safe_directory_all() {
  if ! git config --global --get-all safe.directory 2>/dev/null | grep -Fxq '*'; then
    git config --global --add safe.directory '*'
  fi
}

ensure_git_safe_directory_all

source $CORE_DIR/version.sh
echo "[CORE] $CORE_VERSION ($(cd $CORE_DIR && git rev-parse --short HEAD))"

set +o allexport

# check if uncommitted changes exist in service
if [[ -n $(git status --porcelain) ]]; then
  echo "[CORE] Uncommitted changes exist in $SERVICE_DIR_NAME!"
fi

echo

# COMMANDS
declare -A commands=(
  [help]=":Show this help message"
)
cmd_help() {
  print_help "" "commands"
}

# GLOBAL SUB-COMMANDS
declare -A global_subcommands=(
)

add_global_subcommand() {
  local service="$1"
  local command="$2"

  if [[ " ${!global_subcommands[@]} " =~ " $command " ]]; then
    echo "[CORE] Unable to register global subcommand: following exist:"
    echo "       $command for service ${global_subcommands[$command]}"
    echo "       $command for service $service"
    exit 1
  fi
  global_subcommands[$command]="$service"
}

source $CORE_DIR/borg.sh
source $CORE_DIR/docker.sh
source $CORE_DIR/git.sh
source $CORE_DIR/versions/versions.sh
source $CORE_DIR/traefik_link.sh

# FUNCTIONS
source $CORE_DIR/func_help.sh
source $CORE_DIR/func_exec.sh
source $CORE_DIR/func_generate.sh

load_env() {
  set -o allexport
  source $SERVICE_DIR/.env
  if [[ -s $SERVICE_DIR/.version ]]; then
    source $SERVICE_DIR/.version
  fi
  set +o allexport
}

# MAIN
main() {
  local command="$1"

  # load .env
  load_env

  # check if ":" is in the command
  if [[ $command == *":"* ]]; then
    # split the string by ":"
    IFS=":" read -ra command_parts <<<"$command"

    for command_part in "${command_parts[@]}"; do
      main $command_part
    done
    return 0
  fi

  if [[ ! " ${!commands[@]} " =~ " $command " ]]; then

    # check if command is a global sub-command
    if [[ " ${!global_subcommands[@]} " =~ " $command " ]]; then
      local service="${global_subcommands[$command]}"
      shift
      cmd_$service $command "$@"
      return 0
    fi

    cmd_help
    if ! [[ -z "$command" ]]; then
      echo
      echo "Unknown command: $command"
    fi
    exit 1
  fi

  shift
  cmd_$command "$@"
}
