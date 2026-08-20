#!/bin/bash

CORE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
cd $CORE_DIR
BASE_DIR=$(dirname "$CORE_DIR")
set -e

ensure_git_safe_directory_all() {
  if ! git config --global --get-all safe.directory 2>/dev/null | grep -Fxq '*'; then
    git config --global --add safe.directory '*'
  fi
}

ensure_git_safe_directory_all

source ./version.sh
echo "[CONTROLLER] $CORE_VERSION ($(git rev-parse --short HEAD))"

set -o allexport
source ../.env
set +o allexport

# COMMANDS
declare -A commands=(
  [help]=":Show this help message"
)
cmd_help() {
  print_help "" "commands"
}

# FUNCTIONS
source ./func_help.sh
source ./controller_borg.sh

# MAIN
main() {
  local command="$1"

  if [[ ! " ${!commands[@]} " =~ " $command " ]]; then
    cmd_help
    if ! [[ -z "$command" ]]; then
      echo
      echo "Unknown command: $command"
    fi
    exit 1
  fi

  echo

  cd $BASE_DIR
  shift
  cmd_$command "$@"
}

# COMMANDS
commands+=([create]="<name> <template>:Create a new service using a template")
cmd_create() {
  echo "Creating new service..."
  local service_name="$1"
  local template="$2"
  if [[ -z "$service_name" ]]; then
    echo "Service name is required"
    exit 1
  fi
  if [[ -z "$template" ]]; then
    echo "Using default template"
    template="default"
  fi

  # check if the service already exists
  if [[ -d "$BASE_DIR/$service_name" ]]; then
    echo "Service '$service_name' already exists"
    exit 1
  fi

  local template_dir="$CORE_DIR/templates/$template"
  if [[ ! -d "$template_dir" ]]; then
    echo "Template '$template' does not exist"
    exit 1
  fi

  cp -r "$template_dir" "$BASE_DIR/$service_name"
  chmod +x "$BASE_DIR/$service_name/service.sh"
  echo "Copied template '$template' to '$service_name'"

  cd "$BASE_DIR/$service_name"
  git init -b main >/dev/null
  git add . >/dev/null
  git commit -m "Initial commit from template '$template'" >/dev/null
  echo "Initialized git repository"

  echo "[CONTROLLER] Service '$service_name' created from template '$template'"

  # ask if borg repo should be created
  read -p "Do you want to create a Borg backup repository for this service now? (y/N): " create_borg
  if [[ "$create_borg" == "y" || "$create_borg" == "Y" ]]; then
    ./service.sh borg init
  fi

}

commands+=([import]="<name...>:Import one or more existing services from borg")
cmd_import() {
  if [[ $# -eq 0 ]]; then
    echo "At least one service name is required"
    exit 1
  fi

  local should_up_default="y"
  local should_up_input
  read -p "Do you want to start imported services after import? (Y/n): " should_up_input
  should_up_input="${should_up_input:-$should_up_default}"

  local should_up
  case "$should_up_input" in
  [nN][oO] | [nN])
    should_up=false
    ;;
  *)
    should_up=true
    ;;
  esac

  echo "[CONTROLLER] Importing service..."
  local summary_lines=()
  local imported_count=0
  local failed_count=0
  local skipped_count=0

  for service_name in "$@"; do
    echo "[CONTROLLER] Processing import for '$service_name'..."

    if [[ -d "$BASE_DIR/$service_name" ]]; then
      echo "[CONTROLLER] Service '$service_name' already exists - skipping"
      skipped_count=$((skipped_count + 1))
      summary_lines+=("$service_name: exists")
      continue
    fi

    echo "[CONTROLLER] Looking up latest backup for '$service_name'..."
    export BORG_RSH="$(echo $BORG_RSH | sed "s/~/\/home\/$USER/g")"
    export BORG_REPO="$BORG_REPO_BASE/$service_name"
    export BORG_PASSPHRASE="$BORG_PASSPHRASE"
    name=$(sudo -E borg list --sort-by timestamp --format '{archive}{NL}' | tail -n 1)
    if [ -z "$name" ]; then
      echo "[CONTROLLER] No backups found for service '$service_name'"
      failed_count=$((failed_count + 1))
      summary_lines+=("$service_name: no backup found")
      continue
    fi

    echo "[CONTROLLER] Preparing import directory for '$service_name'..."
    mkdir -p "$BASE_DIR/$service_name"
    cd "$BASE_DIR/$service_name"

    echo "[CONTROLLER] Importing repository for service '$service_name' with backup '$name'"

    if ! sudo -E borg extract --progress "::$name"; then
      echo "[CONTROLLER] Restore failed for service '$service_name'"
      failed_count=$((failed_count + 1))
      summary_lines+=("$service_name: import failed")
      continue
    fi

    echo "[CONTROLLER] Service '$service_name' imported from borg backup"
    imported_count=$((imported_count + 1))

    if $should_up; then
      echo "[CONTROLLER] Starting service '$service_name'..."
      if ! "$BASE_DIR/$service_name/service.sh" up; then
        echo "[CONTROLLER] Failed to start service '$service_name' after import"
        failed_count=$((failed_count + 1))
        summary_lines+=("$service_name: imported but start failed")
      else
        summary_lines+=("$service_name: imported and started")
      fi
    else
      echo "[CONTROLLER] Skipping auto-start for '$service_name'"
      summary_lines+=("$service_name: imported")
    fi
  done

  echo
  echo
  echo "[CONTROLLER] Import summary: imported=$imported_count, skipped=$skipped_count, failed=$failed_count"
  for line in "${summary_lines[@]}"; do
    echo "- $line"
  done
}

commands+=([remove]="<name...>:Remove one or more existing services")
cmd_remove() {
  if [[ $# -eq 0 ]]; then
    echo "At least one service name is required"
    exit 1
  fi

  local should_stop_default="y"
  local should_stop_input
  read -p "Do you want to stop all services before deletion? (Y/n): " should_stop_input
  should_stop_input="${should_stop_input:-$should_stop_default}"

  local should_stop
  case "$should_stop_input" in
  [nN][oO] | [nN])
    should_stop=false
    ;;
  *)
    should_stop=true
    ;;
  esac

  local should_backup_default="y"
  local should_backup_input
  read -p "Do you want to backup all services before deletion? (Y/n): " should_backup_input
  should_backup_input="${should_backup_input:-$should_backup_default}"

  local should_backup
  case "$should_backup_input" in
  [nN][oO] | [nN])
    should_backup=false
    ;;
  *)
    should_backup=true
    ;;
  esac

  local services_list="$*"
  if $should_stop && $should_backup; then
    echo "Are you sure you want to stop, backup and delete services: $services_list"
  elif $should_stop; then
    echo "Are you sure you want to stop and delete services: $services_list"
    echo "This action is IRREVERSIBLE and could delete all data if not backed up properly - use with backup option to be safer"
  elif $should_backup; then
    echo "Are you sure you want to backup and delete services: $services_list"
    echo "This action could leave unwanted running services if not stopped properly - use with stop option to be safer"
  else
    echo "Are you sure you want to DIRECTLY DELETE services: $services_list"
    echo "This action is IRREVERSIBLE and could delete all data if not backed up properly and leave unwanted running services if not stopped properly - use with stop and backup options to be safer"
  fi
  local confirm_input
  read -p "(y/N): " confirm_input
  local confirm
  case "$confirm_input" in
    [yY][eE][sS] | [yY])
      confirm=true
      ;;
    *)
      confirm=false
      ;;
  esac
  if ! $confirm; then
    echo "Aborting"
    exit 0
  fi

  echo "Removing services..."

  local summary_lines=()
  local removed_count=0
  local skipped_count=0
  local failed_count=0

  for service_name in "$@"; do
    echo "[CONTROLLER] Processing removal for '$service_name'..."

    if [[ ! -d "$BASE_DIR/$service_name" ]]; then
      echo "Service '$service_name' does not exist - skipping"
      skipped_count=$((skipped_count + 1))
      summary_lines+=("$service_name: did not exist")
      continue
    fi

    local did_stop=false
    local did_backup=false

    if $should_stop; then
      echo "[CONTROLLER] Stopping '$service_name'..."
      if ! "$BASE_DIR/$service_name/service.sh" down; then
        echo "[CONTROLLER] Failed to stop '$service_name' - skipping deletion"
        failed_count=$((failed_count + 1))
        summary_lines+=("$service_name: stop failed")
        continue
      fi
      did_stop=true
    fi

    if $should_backup; then
      local backup_name="${HOSTNAME}_$(date +"%Y-%m-%d_%H-%M-%S")_remove"
      echo "[CONTROLLER] Backing up '$service_name' as '$backup_name'..."
      if ! "$BASE_DIR/$service_name/service.sh" backup "$backup_name"; then
        echo "[CONTROLLER] Failed to backup '$service_name' - skipping deletion"
        failed_count=$((failed_count + 1))
        if $did_stop; then
          summary_lines+=("$service_name: stopped but backup failed")
        else
          summary_lines+=("$service_name: backup failed")
        fi
        continue
      fi
      did_backup=true
    fi

    echo "[CONTROLLER] Removing '$service_name'..."
    if sudo rm -rf "$BASE_DIR/$service_name"; then
      echo "Service '$service_name' removed"
      removed_count=$((removed_count + 1))
      if $did_stop && $did_backup; then
        summary_lines+=("$service_name: stopped, backed up and deleted")
      elif $did_stop; then
        summary_lines+=("$service_name: stopped and deleted")
      elif $did_backup; then
        summary_lines+=("$service_name: backed up and deleted")
      else
        summary_lines+=("$service_name: deleted")
      fi
    else
      echo "[CONTROLLER] Failed to remove service '$service_name'"
      failed_count=$((failed_count + 1))
      if $did_stop && $did_backup; then
        summary_lines+=("$service_name: stopped and backed up, but delete failed")
      elif $did_stop; then
        summary_lines+=("$service_name: stopped, but delete failed")
      elif $did_backup; then
        summary_lines+=("$service_name: backed up, but delete failed")
      else
        summary_lines+=("$service_name: delete failed")
      fi
    fi
  done

  echo
  echo
  echo "[CONTROLLER] Remove summary: removed=$removed_count, skipped=$skipped_count, failed=$failed_count"
  for line in "${summary_lines[@]}"; do
    echo "- $line"
  done
}

commands+=([rename]="<old> <new>:Rename a service (moves folder and borg repo)")
cmd_rename() {
  local old_name="$1"
  local new_name="$2"

  if [[ -z "$old_name" || -z "$new_name" ]]; then
    echo "Usage: rename <old> <new>"
    exit 1
  fi
  if [[ "$old_name" == "$new_name" ]]; then
    echo "[CONTROLLER] Old and new name are identical"
    exit 1
  fi
  if [[ "$new_name" == */* || "$new_name" == .* ]]; then
    echo "[CONTROLLER] New name must be a simple folder name (no slashes, no leading dot)"
    exit 1
  fi
  if [[ ! -d "$BASE_DIR/$old_name" ]]; then
    echo "[CONTROLLER] Service '$old_name' does not exist"
    exit 1
  fi
  if [[ -e "$BASE_DIR/$new_name" ]]; then
    echo "[CONTROLLER] '$new_name' already exists at $BASE_DIR"
    exit 1
  fi

  local should_stop_input
  read -p "Stop service '$old_name' before rename? (Y/n): " should_stop_input
  should_stop_input="${should_stop_input:-y}"
  local should_stop=true
  case "$should_stop_input" in
  [nN][oO] | [nN])
    should_stop=false
    ;;
  esac

  local should_start=false
  if $should_stop; then
    local should_start_input
    read -p "Start service '$new_name' after rename? (Y/n): " should_start_input
    should_start_input="${should_start_input:-y}"
    should_start=true
    case "$should_start_input" in
    [nN][oO] | [nN])
      should_start=false
      ;;
    esac
  fi

  echo
  echo "About to rename '$old_name' -> '$new_name':"
  echo "  - move folder $BASE_DIR/$old_name -> $BASE_DIR/$new_name"
  echo "  - move borg repo $BORG_REPO_BASE/$old_name -> $BORG_REPO_BASE/$new_name"
  $should_stop && echo "  - service will be stopped first (clears autobackup entry + traefik mount)"
  $should_start && echo "  - service will be restarted under new name (re-enrolls autobackup + traefik mount)"
  if ! $should_stop; then
    echo "  - WARNING: skipping stop leaves $BASE_DIR/.backup pointing at '$old_name'"
    echo "             and the traefik bind-mount at $BASE_DIR/.traefik/$old_name attached."
    echo "             Both reset cleanly on the next './$new_name/service.sh down' + 'up'."
  fi
  local confirm_input
  read -p "Proceed? (y/N): " confirm_input
  case "$confirm_input" in
  [yY][eE][sS] | [yY]) ;;
  *)
    echo "Aborting"
    exit 0
    ;;
  esac

  if $should_stop; then
    echo "[CONTROLLER] Stopping '$old_name'..."
    if ! "$BASE_DIR/$old_name/service.sh" down; then
      echo "[CONTROLLER] Failed to stop '$old_name' - aborting rename"
      exit 1
    fi
  fi

  echo "[CONTROLLER] Moving folder $old_name -> $new_name..."
  if ! sudo mv "$BASE_DIR/$old_name" "$BASE_DIR/$new_name"; then
    echo "[CONTROLLER] Folder move failed - aborting (nothing else changed yet)"
    exit 1
  fi

  echo "[CONTROLLER] Moving borg repo $old_name -> $new_name..."
  if borg_controller_move_repo "$old_name" "$new_name"; then
    echo "[CONTROLLER] Borg repo moved successfully"
  else
    echo "[CONTROLLER] WARNING: borg repo move failed."
    echo "             Folder rename DID succeed. You should manually move the"
    echo "             repo at $BORG_REPO_BASE/$old_name to $BORG_REPO_BASE/$new_name"
    echo "             or future backups will go to a fresh repo at the new name."
  fi

  if $should_start; then
    echo "[CONTROLLER] Starting '$new_name'..."
    if ! "$BASE_DIR/$new_name/service.sh" up; then
      echo "[CONTROLLER] WARNING: failed to start '$new_name' under new name"
    fi
  fi

  echo
  echo "[CONTROLLER] Rename complete: '$old_name' -> '$new_name'"
}

commands+=([update]=":Update the controller to the latest version")
cmd_update() {
  echo "Updating controller..."
  cd $CORE_DIR
  git pull --rebase origin main
  echo "Controller updated to latest version"
  source update.sh
  echo "Controller update process completed"
}

main "$@"
