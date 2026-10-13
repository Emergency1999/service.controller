#!/bin/bash

declare -A version_controller_commands=(
)

if ! declare -f borg_autobackup_services_read >/dev/null; then
  source "$CORE_DIR/borg_commands.sh"
fi

commands+=([version]=":Manage the image versions of all services")
cmd_version() {
  local command="$1"

  if [[ ! " ${!version_controller_commands[@]} " =~ " $command " ]]; then
    print_help "version " "version_controller_commands"
    if ! [[ -z "$command" ]]; then
      echo
      echo "Unknown command: version $command"
    fi
    exit 1
  fi

  shift # remove first argument ("version" command)
  version_controller_$command "$@"
}

# controller_services [name...]: sets $services to the names given, or to all
# services in .backup without any
controller_services() {
  if [[ $# -gt 0 ]]; then
    services=("$@")
    return
  fi
  borg_autobackup_services_read
  services=("${autobackup_services[@]}")
}

version_controller_commands+=([info]="[name...]:Show the images with updates of the services given, or of all in .backup")
version_controller_info() {
  local service output
  local -a services summary_lines=()
  controller_services "$@"

  for service in "${services[@]}"; do
    if [[ ! -s "$BASE_DIR/$service/.version" ]]; then
      summary_lines+=("$service: no .version")
      continue
    fi
    echo "[CONTROLLER] Checking '$service'..."
    if output=$("$BASE_DIR/$service/service.sh" version info 2>&1); then
      output=$(sed -n 's/^\[VERSION\] \(Update available\|Target not found\): /\1: /p' <<<"$output" | paste -sd ';' | sed 's/;/; /g')
      summary_lines+=("$service: ${output:-up to date}")
    else
      summary_lines+=("$service: failed: $(tail -n1 <<<"$output")")
    fi
  done

  echo
  echo "[CONTROLLER] Updates:"
  for line in "${summary_lines[@]}"; do
    echo "- $line"
  done
}

version_controller_commands+=([upgrade]="[-y] [name...]:Upgrade the images of the services given, or of all in .backup; each asks which unless -y, which ends with a summary")
version_controller_upgrade() {
  local service answer="" log
  local -a services summary_lines=()
  if [[ $1 == "-y" ]]; then
    answer="-y"
    shift
  fi
  controller_services "$@"
  log=$(mktemp)

  for service in "${services[@]}"; do
    if [[ ! -s "$BASE_DIR/$service/.version" ]]; then
      summary_lines+=("$service: no .version")
      continue
    fi
    echo
    echo "[CONTROLLER] ######################################## Upgrading service: $service"
    if [[ -z $answer ]]; then
      # asked one by one, the output goes to the terminal as it is
      "$BASE_DIR/$service/service.sh" version upgrade || true
      continue
    fi
    # the last line says how the upgrade ended
    "$BASE_DIR/$service/service.sh" version upgrade -y 2>&1 | tee "$log" || true
    summary_lines+=("$service: $(grep -v '^[[:space:]]*$' "$log" | tail -n1 | sed 's/^\[VERSION\] *//; s/^ *//')")
  done
  rm -f "$log"

  [[ -n $answer ]] || return 0
  echo
  echo "[CONTROLLER] Upgrade summary:"
  for line in "${summary_lines[@]}"; do
    echo "- $line"
  done
}
