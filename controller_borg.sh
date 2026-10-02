#!/bin/bash

declare -A borg_controller_commands=(
)

if ! declare -f borg_autobackup_services_read >/dev/null; then
  source "$CORE_DIR/borg_commands.sh"
fi

# TODO borg import

commands+=([borg]=":Manage global Borg Services operations")
cmd_borg() {
  local command="$1"

  if [[ ! " ${!borg_controller_commands[@]} " =~ " $command " ]]; then
    print_help "borg " "borg_controller_commands"
    if ! [[ -z "$command" ]]; then
      echo
      echo "Unknown command: borg $command"
    fi
    exit 1
  fi

  BORG_RSH="$(echo $BORG_RSH | sed "s/~/\/home\/$USER/g")"

  cd $SERVICE_DIR
  shift # remove first argument ("borg" command)
  borg_controller_$command "$@"
}


borg_controller_commands+=([change-passphrase]="<name> <old-passphrase>:Change the passphrase of the <name> repository to the new passphrase")
borg_controller_change-passphrase() {
  local name="$1"
  local old_passphrase="$2"

  if [ -z "$name" ]; then
    echo "[CONTROLLER] Repository name is required"
    exit 1
  fi
  if [ -z "$old_passphrase" ]; then
    echo "[CONTROLLER] Old passphrase is required"
    exit 1
  fi

  echo "[CONTROLLER] Changing passphrase for repository '$name'..."
  export BORG_REPO="$BORG_REPO_BASE/$name"

  export BORG_NEW_PASSPHRASE="$BORG_PASSPHRASE" 
  export BORG_PASSPHRASE="$old_passphrase"
  sudo -E borg key change-passphrase
  export BORG_PASSPHRASE="$BORG_NEW_PASSPHRASE"
  echo "[CONTROLLER] Passphrase changed successfully for repository '$name'"
}

borg_controller_commands+=([autobackup-now]=":Create a new backup for all enabled services immediately")
borg_controller_autobackup-now() {
  echo "[CONTROLLER] Creating a new backup for all enabled services..."
  local tstart=$(date +%s)
  local service
  local attempt
  local max_attempts=5
  local total_services
  local succeeded_services=0
  local failed_services=0
  local -a pending_services=()
  local -a next_pending_services=()
  local -a summary_lines=()

  if ! borg_autobackup_services_read; then
    echo "[CONTROLLER] Failed to read autobackup service list"
    return 1
  fi

  if [[ ${#autobackup_services[@]} -eq 0 ]]; then
    echo "[CONTROLLER] No services configured for autobackup"
    return 0
  fi

  total_services=${#autobackup_services[@]}
  pending_services=("${autobackup_services[@]}")

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if [[ ${#pending_services[@]} -eq 0 ]]; then
      break
    fi

    echo
    echo "[CONTROLLER] Retry round $attempt/$max_attempts (pending: ${#pending_services[@]})"

    next_pending_services=()
    for service in "${pending_services[@]}"; do
      echo
      echo "[CONTROLLER] ######################################## Backing up service: $service (attempt $attempt)"

      set +e
      "$BASE_DIR/$service/service.sh" borg autobackup-now
      local backup_rc=$?
      set -e

      if [[ $backup_rc -ne 0 ]]; then
        echo "[CONTROLLER] ######################################## Error backing up service: $service (attempt $attempt)"
        next_pending_services+=("$service")
      else
        echo "[CONTROLLER] ######################################## Finished service  : $service"
        summary_lines+=("$service: backed up (attempt $attempt)")
        succeeded_services=$((succeeded_services + 1))
      fi
    done

    pending_services=("${next_pending_services[@]}")
  done

  for service in "${pending_services[@]}"; do
    summary_lines+=("$service: failed after $max_attempts attempts")
    failed_services=$((failed_services + 1))
  done

  echo
  echo "[CONTROLLER] Autobackup summary: total=$total_services, succeeded=$succeeded_services, failed=$failed_services"
  for service in "${summary_lines[@]}"; do
    echo "- $service"
  done

  if [ ! -z "$BORG_GENERAL_SUCCESS_URL" ]; then
    echo "[CONTROLLER] $(date) Sending uptime message..."
    local status="up"
    if [[ $failed_services -gt 0 ]]; then
      status="down"
    fi
    curl -X GET \
      -G "$BORG_GENERAL_SUCCESS_URL" \
      --data-urlencode "status=$status" \
      --data-urlencode "msg=succeeded=$succeeded_services, failed=$(IFS=,; echo "${pending_services[*]}")" \
      --data-urlencode "ping=$(($(date +%s) - tstart))"
  fi

  if [[ $failed_services -gt 0 ]]; then
    return 1
  fi

  return 0
}

# Populates globals describing $BORG_REPO_BASE:
#   BORG_BASE_IS_REMOTE (true/false)
#   BORG_BASE_SSH_HOST, BORG_BASE_SSH_PORT, BORG_BASE_SSH_PATH (if remote)
#   BORG_BASE_LOCAL_PATH (if local)
# Returns 0 on success, 1 if BORG_REPO_BASE is unset or unparseable.
borg_controller_parse_base() {
  BORG_BASE_IS_REMOTE=false
  BORG_BASE_SSH_HOST=""
  BORG_BASE_SSH_PORT=""
  BORG_BASE_SSH_PATH=""
  BORG_BASE_LOCAL_PATH=""

  if [[ -z "$BORG_REPO_BASE" ]]; then
    echo "[CONTROLLER] BORG_REPO_BASE is not set in $BASE_DIR/.env"
    return 1
  fi

  if [[ "$BORG_REPO_BASE" =~ ^ssh://([^/]+)(/.+)$ ]]; then
    BORG_BASE_IS_REMOTE=true
    local hostpart="${BASH_REMATCH[1]}"
    local path="${BASH_REMATCH[2]}"
    if [[ "$hostpart" =~ ^(.+):([0-9]+)$ ]]; then
      BORG_BASE_SSH_HOST="${BASH_REMATCH[1]}"
      BORG_BASE_SSH_PORT="${BASH_REMATCH[2]}"
    else
      BORG_BASE_SSH_HOST="$hostpart"
    fi
    # borg convention: /./path means relative to remote $HOME
    if [[ "$path" =~ ^/\./ ]]; then
      BORG_BASE_SSH_PATH=".${path#/.}"
    else
      BORG_BASE_SSH_PATH="$path"
    fi
  elif [[ "$BORG_REPO_BASE" == /* ]]; then
    BORG_BASE_LOCAL_PATH="$BORG_REPO_BASE"
  else
    echo "[CONTROLLER] Unsupported BORG_REPO_BASE format: $BORG_REPO_BASE"
    echo "             Expected ssh://user@host[:port]/path or absolute local path"
    return 1
  fi
  return 0
}

# Invoke a command on the remote via the configured BORG_RSH.
# $1: command string to execute remotely
borg_controller_ssh() {
  local cmd="$1"
  local port_arg=""
  [[ -n "$BORG_BASE_SSH_PORT" ]] && port_arg="-p $BORG_BASE_SSH_PORT"
  # shellcheck disable=SC2086
  $BORG_RSH $port_arg "$BORG_BASE_SSH_HOST" "$cmd"
}

# Move a borg repo from <old> to <new> under $BORG_REPO_BASE.
# Returns 0 on success, 1 on failure.
borg_controller_move_repo() {
  local old_name="$1"
  local new_name="$2"

  if ! borg_controller_parse_base; then
    return 1
  fi

  local src dst
  if $BORG_BASE_IS_REMOTE; then
    src="$BORG_BASE_SSH_PATH/$old_name"
    dst="$BORG_BASE_SSH_PATH/$new_name"
    # Hetzner storagebox restricted shell: use `stat` (exit 0 = exists) for existence checks.
    if ! borg_controller_ssh "stat '$src'" >/dev/null 2>&1; then
      echo "[CONTROLLER] Remote borg repo '$src' not found - nothing to move"
      return 1
    fi
    if borg_controller_ssh "stat '$dst'" >/dev/null 2>&1; then
      echo "[CONTROLLER] Remote path '$dst' already exists - refusing to overwrite"
      return 1
    fi
    borg_controller_ssh "mv '$src' '$dst'"
  else
    src="$BORG_BASE_LOCAL_PATH/$old_name"
    dst="$BORG_BASE_LOCAL_PATH/$new_name"
    if [[ ! -d "$src" ]]; then
      echo "[CONTROLLER] Local borg repo '$src' not found - nothing to move"
      return 1
    fi
    if [[ -e "$dst" ]]; then
      echo "[CONTROLLER] Local path '$dst' already exists - refusing to overwrite"
      return 1
    fi
    sudo mv "$src" "$dst"
  fi
}

# Worker for parallel list-repos. Exported via `export -f` so xargs's bash subshells
# can call it. Reads $BASE_DIR and $BORG_REPO_BASE from the environment.
_borg_controller_list_repo_row() {
  local n="$1"
  local installed="no"
  [[ -d "$BASE_DIR/$n" ]] && installed="yes"

  local list_output info_output rc1 rc2 archives size latest
  export BORG_REPO="$BORG_REPO_BASE/$n"
  # Two SSH round-trips per repo:
  #   borg list -> timestamps for every archive (gives both count and latest)
  #   borg info -> dedup size of the whole repo
  list_output=$(sudo -n -E borg list --format '{time}{NL}' 2>/dev/null)
  rc1=$?
  info_output=$(sudo -n -E borg info 2>/dev/null)
  rc2=$?

  if [[ $rc1 -ne 0 || $rc2 -ne 0 ]]; then
    archives="?"
    size="?"
    latest="(unreachable)"
  else
    archives=$(printf '%s' "$list_output" | grep -c . || true)
    size=$(echo "$info_output" | awk '/^All archives:/{print $(NF-1) $NF}')
    [[ -z "$size" ]] && size="-"
    if [[ "$archives" == "0" ]]; then
      latest="(no archives)"
    else
      latest=$(printf '%s' "$list_output" | tail -n 1)
    fi
  fi
  printf "  %-30s %-9s %-9s %-9s %s\n" "$n" "$installed" "$size" "$archives" "$latest"
}
export -f _borg_controller_list_repo_row

borg_controller_commands+=([list-repos]=":List all borg repos under \$BORG_REPO_BASE")
borg_controller_list-repos() {
  if ! borg_controller_parse_base; then
    exit 1
  fi

  echo "[CONTROLLER] Listing borg repos under $BORG_REPO_BASE"
  echo

  local -a names=()
  local n
  if $BORG_BASE_IS_REMOTE; then
    # Hetzner storagebox restricted shell allows `ls` but not loops or `test`.
    # `ls $path` returns one name per line. Each subdirectory is treated as a
    # candidate repo; non-repos surface as "unreachable" in the listing below.
    local listing
    if ! listing=$(borg_controller_ssh "ls '$BORG_BASE_SSH_PATH'"); then
      echo "[CONTROLLER] Failed to list remote repos"
      exit 1
    fi
    while IFS= read -r n; do
      [[ -n "$n" ]] && names+=("$n")
    done <<<"$listing"
  else
    local d
    for d in "$BORG_BASE_LOCAL_PATH"/*/; do
      [[ -f "$d/config" ]] && names+=("$(basename "$d")")
    done
  fi

  if [[ ${#names[@]} -eq 0 ]]; then
    echo "[CONTROLLER] No borg repos found"
    return 0
  fi

  # Fan out 8 parallel SSH/borg calls. xargs reads one name per line from stdin and
  # passes it as $1 to the worker. `sort` restores alphabetical order from `ls` since
  # parallel workers finish out-of-order. The whole batch buffers into $rows so the
  # header doesn't print until results are ready.
  echo "[CONTROLLER] Querying ${#names[@]} repos in parallel (this may take a while)..."
  export BASE_DIR BORG_REPO_BASE
  local rows
  rows=$(printf '%s\n' "${names[@]}" | xargs -P 8 -I {} bash -c '_borg_controller_list_repo_row "$@"' _ {} | sort)
  echo
  printf "  %-30s %-9s %-9s %-9s %s\n" "REPO" "INSTALLED" "SIZE" "ARCHIVES" "LATEST"
  echo "$rows"
}

borg_controller_commands+=([delete-repo]="<name>:Delete a borg repo (shows recent archives first, requires confirmation)")
borg_controller_delete-repo() {
  local name="$1"
  if [[ -z "$name" ]]; then
    echo "Usage: borg delete-repo <name>"
    exit 1
  fi

  export BORG_REPO="$BORG_REPO_BASE/$name"

  echo "[CONTROLLER] Recent archives in $BORG_REPO:"
  if ! sudo -E borg list --last 20; then
    echo "[CONTROLLER] Failed to list repo - aborting"
    exit 1
  fi
  echo

  echo "About to PERMANENTLY DELETE repo $BORG_REPO and ALL its archives."
  if [[ -d "$BASE_DIR/$name" ]]; then
    echo "WARNING: a service folder '$BASE_DIR/$name' still exists."
    echo "         Its future backups will fail until 'borg init' creates a new repo."
  fi
  local typed
  read -p "Type the repo name '$name' to confirm: " typed
  if [[ "$typed" != "$name" ]]; then
    echo "Confirmation mismatch - aborting"
    exit 0
  fi

  if ! sudo -E borg delete --force "$BORG_REPO"; then
    echo "[CONTROLLER] Borg delete failed"
    exit 1
  fi
  echo "[CONTROLLER] Repo $BORG_REPO deleted"

  if borg_autobackup_services_read; then
    local s changed=false
    local -a updated=()
    for s in "${autobackup_services[@]}"; do
      if [[ "$s" == "$name" ]]; then
        changed=true
        continue
      fi
      updated+=("$s")
    done
    if $changed; then
      autobackup_services=("${updated[@]}")
      borg_autobackup_services_write &&
        echo "[CONTROLLER] Removed '$name' from $BASE_DIR/.backup"
    fi
  fi
}
