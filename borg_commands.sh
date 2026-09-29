# helper function that gets called
# when the name is not given
# and determines which prompt to show
# $1: the prompt mode (latest, generate)
name_prompt() {
  local mode="$1"

  if [ "$mode" == "generate" ]; then
    # prompt user to use the latest backup
    # "generate" uses YES as default
    printf "[BORG] Generate default backup name?(Y/n): "
    read -r
    case "$REPLY" in
    [nN][oO] | [nN])
      echo "       exiting"
      exit 1
      ;;
    *)
      name="latest"
      ;;
    esac
  elif [ "$mode" == "latest" ]; then
    # prompting user to use the latest backup
    # "latest" uses NO as default
    printf "[BORG] Use latest backup?(y/N): "
    read -r
    case "$REPLY" in
    [yY][eE][sS] | [yY])
      name="latest"
      ;;
    *)
      echo "       exiting"
      exit 1
      ;;
    esac
  else
    # just to avoid misuse of the function
    echo "ILLEGAL: Call to function 'name_prompt' with mode: $mode"
    exit 1
  fi
}

# $1: name of the backup
# $2: if exists, automatically set default name
#     "latest" find the latest backup name
#     "generate" generate a new backup name
borg_check_name() {

  name="$1"

  # if "$2" is empty, "$name" MUST be given
  if [ -z "$2" ]; then
    if [ -z "$name" ]; then
      echo "[BORG] name is required"
      exit 1
    fi
  else
    # if name is NOT given, call the prompt function
    if [ -z "$name" ]; then
      name_prompt "$2"
    fi

    # if the name is "latest" (NOT case-sensitive), find/create the latest backup
    if [ "${name,,}" == "latest" ] || [ "${name,,}" == "auto" ]; then

      # if the second argument is "generate", we will set the name
      # to the hostname and current date and time
      if [ "$2" == "generate" ]; then
        name=${HOSTNAME}_$(date +"%Y-%m-%d_%H-%M-%S")
      else
        # else we will search for the latest
        name=$(sudo -E borg list --sort-by timestamp --format '{archive}{NL}' | tail -n 1)
      fi

      # a bit of logging
      echo "[BORG] using backup: $name"
    fi
  fi
}

borg_init() {
  # check if repository exists
  if borg info &>/dev/null; then
    echo "[BORG] Repository already exists"
    exit 1
  fi

  # # check if passphrase is set
  # if [ -z "$BORG_PASSPHRASE" ]; then
  #   borg_pwgen
  #   load_env
  # fi

  echo "[BORG] Creating remote repository"
  sudo -E borg init --encryption=repokey-blake2 --make-parent-dirs >/dev/null
  echo "[BORG] Repository created"
}

borg_info() {
  echo "[BORG] using BORG_REPO $BORG_REPO"
  #TODO fix the crontab check, it is now in the global .env
  # echo "[BORG] Service information:"
  # if crontab -l | grep -q "$SERVICE_NAME/service.sh borg"; then
  #   echo "[BORG] Automatic backups are enabled."
  # else
  #   echo "[BORG] Automatic backups are disabled."
  # fi
  echo
  echo "[BORG] Repository information:"
  sudo -E borg info
}

borg_list() {
  echo "[BORG] List of backups:"
  sudo -E borg list
}

borg_backup() {
  borg_check_name "$1" "generate"

  echo "[BORG] Backup current data..."
  sudo -E borg create --stats --progress --compression zlib "::$name" .
  if [ $? -ne 0 ]; then
    echo "[BORG] Backup failed"
    exit 1
  fi
  echo "[BORG] Backup finished"
}

borg_check_git_before_restore() {
  rm -rf $BASE_DIR/.tmp/$SERVICE_DIR_NAME/.git #TODO check first, ask user if it should be deleted
  # check if .git folder exists
  if [ ! -d "$SERVICE_DIR/.git" ]; then
    echo "[BORG] No .git folder found in $SERVICE_DIR_NAME."
    echo "       Restoring .git from backup as well."
    export HAS_GIT=false
    return
  fi
  export HAS_GIT=true

  # check if uncommitted changes exist in service
  if [[ -n $(git status --porcelain) ]]; then
    echo "[BORG] Uncommitted changes exist in $SERVICE_DIR_NAME!"
    printf "[BORG] Do you want to continue with the restore?(y/N): "
    read -r
    case "$REPLY" in
    [yY][eE][sS] | [yY])
      ;;
    *)
      echo "       exiting"
      exit 1
      ;;
    esac
  fi

  echo "[BORG] Securing .git folder before restore..."
  mkdir -p $BASE_DIR/.tmp/$SERVICE_DIR_NAME
  sudo mv .git $BASE_DIR/.tmp/$SERVICE_DIR_NAME/
}

borg_check_git_after_restore() {
  if [ "$HAS_GIT" == false ]; then
    return
  fi
  echo "[BORG] Restoring .git folder after restore..."
  sudo rm -rf .git
  sudo mv $BASE_DIR/.tmp/$SERVICE_DIR_NAME/.git ./
}

borg_restore-fresh() {
  local clean_git=false
  local args=()
  for arg in "$@"; do
    case "$arg" in
      --clean-git) clean_git=true ;;
      *) args+=("$arg") ;;
    esac
  done

  borg_check_name "${args[0]:-}" "latest"

  cd $SERVICE_DIR
  if ! $clean_git; then
    borg_check_git_before_restore
  fi
  set +e # disable exit on error

  echo "[BORG] Purging current data..."
  # delete all files and folders
  sudo rm -rf ./*
  echo "[BORG] Restore data from backup..."
  BORG_RSH="$(echo $BORG_RSH | sed "s/~/\/home\/$USER/g")"
  sudo -E borg extract --progress "::$name"
  if [ $? -ne 0 ]; then
    if ! $clean_git; then
      borg_check_git_after_restore
    fi
    echo "[BORG] Restore failed"
    exit 1
  fi

  if ! $clean_git; then
    borg_check_git_after_restore
  fi
  set -e # enable exit on error

  echo "[BORG] Restore finished"
}

borg_restore-diff() {
  local clean_git=false
  local args=()
  for arg in "$@"; do
    case "$arg" in
      --clean-git) clean_git=true ;;
      *) args+=("$arg") ;;
    esac
  done

  borg_check_name "${args[0]:-}" "latest"

  BORG_RSH="$(echo $BORG_RSH | sed "s/~/\/home\/$USER/g")"

  cd $SERVICE_DIR
  if ! $clean_git; then
    borg_check_git_before_restore
  fi
  set +e # disable exit on error

  echo "[BORG] Mounting the backup..."
  mkdir -p "$BASE_DIR/.tmp/$SERVICE_DIR_NAME/mnt"
  sudo -E borg mount --progress "::$name" "$BASE_DIR/.tmp/$SERVICE_DIR_NAME/mnt"
  if [ $? -ne 0 ]; then
    if ! $clean_git; then
      borg_check_git_after_restore
    fi
    echo "[BORG] Mount failed. Try a restore-fresh instead."
    exit 1
  fi

  echo "[BORG] Restoring the differences from backup..."
  # Use --info=progress2 to show only the overall progress percentage
  sudo rsync -ah --info=progress2 --delete "$BASE_DIR/.tmp/$SERVICE_DIR_NAME/mnt/" "$SERVICE_DIR"
  restoreExitCode=$?

  echo "[BORG] Unmounting the backup..."
  sudo -E borg umount "$BASE_DIR/.tmp/$SERVICE_DIR_NAME/mnt"
  unmountExitCode=$?

  if ! $clean_git; then
    borg_check_git_after_restore
  fi
  set -e # enable exit on error

  if [ $restoreExitCode -ne 0 ] || [ $unmountExitCode -ne 0 ]; then
    echo "[BORG] Restore failed:"
    echo "       rsync: $restoreExitCode"
    echo "       umount: $unmountExitCode"
    exit 1
  fi
  echo "[BORG] Restore finished"
}

borg_export() {
  local file="$1"
  borg_check_name "$2" "latest"

  if [ -z "$file" ]; then
    echo "[BORG] File name is required"
    exit 1
  fi
  if [[ ! "$file" =~ \.tar$ ]]; then
    echo "[BORG] File name must end with .tar"
    exit 1
  fi

  echo "[BORG] Export backup to a .tar file..."
  sudo -E borg export-tar --progress "::$name" $file
  if [ $? -ne 0 ]; then
    echo "[BORG] Export failed"
    exit 1
  fi
  echo "[BORG] Export finished"
}

borg_delete() {
  borg_check_name "$1"

  echo "[BORG] Delete backup..."
  sudo -E borg delete --progress "::$name"
  if [ $? -ne 0 ]; then
    echo "[BORG] Delete failed"
    exit 1
  fi
  echo "[BORG] Backup deleted"
}

borg_compact() {
  echo "[BORG] Compact the repository..."
  sudo -E borg compact --progress
  if [ $? -ne 0 ]; then
    echo "[BORG] Compact failed"
    exit 1
  fi
  echo "[BORG] Repository compacted"
}

borg_prune() {
  echo "[BORG] Prune old backups..."
  # archives starting with "+" are never pruned (versions replaced by auto-upgrade)
  sudo -E borg prune --progress --stats --glob-archives '[!+]*' --keep-within 2d --keep-daily=14 --keep-weekly=8 --keep-monthly=12 --keep-yearly=3
  if [ $? -ne 0 ]; then
    echo "[BORG] Prune failed"
    exit 1
  fi
  echo "[BORG] Old backups pruned"
  # executing compact as well, as prune does not delete the data
  borg_compact
}

borg_break-lock() {
  echo "[BORG] Free the repository lock"
  echo "[BORG] Waiting 5 seconds before breaking the lock"
  echo "[BORG] ONLY USE THIS COMMAND IF YOU KNOW WHAT YOU ARE DOING"
  sleep 5
  sudo -E borg break-lock
  if [ $? -ne 0 ]; then
    echo "[BORG] Failed to break the lock"
    exit 1
  fi
  echo "[BORG] Repository lock freed"
}

borg_autobackup_services_read() {
  autobackup_services=()
  local backup_file="$BASE_DIR/.backup"
  local env_file="$BASE_DIR/.env"
  local raw_services="${BORG_AUTOBACKUP_SERVICES:-}"
  local parsed_services=()
  local service

  if [[ ! -f "$backup_file" ]]; then
    if [[ -n "$raw_services" ]]; then
      IFS=',' read -r -a parsed_services <<< "$raw_services"
      for service in "${parsed_services[@]}"; do
        service="$(echo "$service" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        if [[ -z "$service" ]]; then
          continue
        fi
        autobackup_services+=("$service")
      done

      if ! borg_autobackup_services_write; then
        echo "[BORG] Failed to migrate legacy BORG_AUTOBACKUP_SERVICES to $backup_file"
        return 1
      fi

      if [[ -f "$env_file" ]]; then
        local tmp_env_file
        tmp_env_file="$(mktemp)"
        awk '!/^[[:space:]]*BORG_AUTOBACKUP_SERVICES=/' "$env_file" > "$tmp_env_file" || {
          rm -f "$tmp_env_file"
          return 1
        }
        mv "$tmp_env_file" "$env_file" || {
          rm -f "$tmp_env_file"
          return 1
        }
      fi

      unset BORG_AUTOBACKUP_SERVICES
      export BORG_AUTOBACKUP_SERVICES=""
      echo "[BORG] Migrated legacy BORG_AUTOBACKUP_SERVICES to $backup_file"
      return 0
    fi

    if ! touch "$backup_file"; then
      echo "[BORG] Failed to create $backup_file"
      return 1
    fi
  fi

  while IFS= read -r service || [[ -n "$service" ]]; do
    service="$(echo "$service" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [[ -z "$service" ]]; then
      continue
    fi
    autobackup_services+=("$service")
  done < "$backup_file"

  return 0
}

borg_autobackup_services_write() {
  local backup_file="$BASE_DIR/.backup"
  local service
  local tmp_file

  tmp_file="$(mktemp)"

  for service in "${autobackup_services[@]}"; do
    if [[ -z "$service" ]]; then
      continue
    fi
    echo "$service" >> "$tmp_file" || {
      rm -f "$tmp_file"
      return 1
    }
  done

  mv "$tmp_file" "$backup_file" || {
    rm -f "$tmp_file"
    return 1
  }

  return 0
}

borg_autobackup-enable() {
  local service

  if ! borg_autobackup_services_read; then
    return 1
  fi

  for service in "${autobackup_services[@]}"; do
    if [[ "$service" == "$SERVICE_DIR_NAME" ]]; then
      return 0
    fi
  done

  autobackup_services+=("$SERVICE_DIR_NAME")
  if ! borg_autobackup_services_write; then
    echo "[BORG] Failed to update $BASE_DIR/.backup"
    return 1
  fi

  echo "[BORG] Enabled autobackup for '$SERVICE_DIR_NAME'"
  return 0
}

borg_autobackup-disable() {
  local service
  local updated_services=()
  local removed=false

  if ! borg_autobackup_services_read; then
    return 1
  fi

  for service in "${autobackup_services[@]}"; do
    if [[ "$service" == "$SERVICE_DIR_NAME" ]]; then
      removed=true
      continue
    fi
    updated_services+=("$service")
  done

  autobackup_services=("${updated_services[@]}")
  if ! borg_autobackup_services_write; then
    echo "[BORG] Failed to update $BASE_DIR/.backup"
    return 1
  fi

  if $removed; then
    echo "[BORG] Disabled autobackup for '$SERVICE_DIR_NAME'"
  fi

  return 0
}

borg_autobackup-now() {
  if [ ! -z "$1" ]; then
    $SERVICE_DIR/service.sh borg autobackup-now > $1 2>&1
    exit $?
  fi
  tstart=$(date +%s)
  echo "[CRON] $(date) Automatic backup started..."
  success="up"
  borg_backup auto || success="backup"
  if [ $success == "up" ]; then
    borg_prune || success="prune"
  fi
  tend=$(date +%s)
  tdiff=$((tend - tstart))
  
  if [ ! -z "$BORG_SUCCESS_URL" ]; then
    echo "[CRON] $(date) Sending uptime message..."
    status="up"
    msg="$name"
    if [ $success != "up" ]; then
      status="down"
      msg="$success failed"
    fi
    curl -X GET \
      -G "$BORG_SUCCESS_URL" \
      --data-urlencode "status=$status" \
      --data-urlencode "msg=$msg" \
      --data-urlencode "ping=$tdiff"
  fi

  echo 
  echo "[CRON] $(date) Automatic backup finished, took $tdiff seconds"
  if [ $success != "up" ]; then
    echo "[CRON] $(date) Backup failed at $success"
    exit 1
  fi
}
