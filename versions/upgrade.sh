# AUTO-UPGRADE

VERSION_TIMEOUT=60 # seconds a service has to get healthy in after an upgrade
VERSION_SETTLE=10  # seconds a service is left alone before its health is looked at

# version_run <command...>: runs a command of this service in a process of its
# own, so that it loads .version again and its failure can be handled
version_run() {
  "$SERVICE_DIR/service.sh" "$@"
}

# version_containers: the ids of all containers of this service
version_containers() {
  docker compose -p $SERVICE_DIR_NAME ps -aq
}

# version_unhealthy [fresh]: the containers that are not up and healthy, one
# per line. A container without a healthcheck is healthy while it runs, and so
# is one that finished without an error. With "fresh" the containers have just
# been created, so one that was restarted since then is not healthy.
version_unhealthy() {
  local ids
  ids=$(version_containers) || return 1
  [[ -n $ids ]] || return 0

  docker inspect --format '{{.Name}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}} {{.State.ExitCode}} {{.RestartCount}}' $ids |
    awk -v fresh="$1" '
      $2 == "exited" && $4 == 0 { next }
      $2 == "running" && ($3 == "-" || $3 == "healthy") && !(fresh && $5 > 0) { next }
      {
        state = $2
        if ($3 != "-") state = state ", " $3
        if ($2 == "exited") state = state ", exit code " $4
        if ($5 > 0) state = state ", restarted " $5 " times"
        print substr($1, 2) " (" state ")"
      }'
}

# version_wait: waits until the service is healthy. Prints the containers that
# are not when the time is up, together with the end of their logs.
version_wait() {
  local start=$SECONDS unhealthy container state

  sleep "$VERSION_SETTLE"
  while true; do
    unhealthy=$(version_unhealthy fresh) || return 1
    [[ -n $unhealthy ]] || return 0
    ((SECONDS - start < VERSION_TIMEOUT)) || break
    sleep 2
  done

  while read -r container state; do
    echo "$container $state"
    docker logs --tail 20 "$container" 2>&1 | sed 's/^/    /'
  done <<<"$unhealthy"
  return 1
}

# version_replace <archive>: deletes the archive if it exists, so that one left
# behind by an earlier upgrade does not stop the new backup
version_replace() {
  if version_borg info "::$1" &>/dev/null; then
    echo "[VERSION] Replacing existing backup '$1'"
    version_borg delete "::$1"
  fi
}

version_auto-upgrade() {
  local name repo target current new rc i old_label new_label
  local from="" to="" running=false failure=""
  local -a names=() digests=()

  version_check

  for name in $(version_names); do
    rc=0
    version_load "$name" || rc=$?
    if [[ $rc -eq $VERSION_UNSUPPORTED ]]; then
      echo "[VERSION] Skipping $name: registry of $repo is not supported"
      continue
    elif [[ $rc -ne 0 ]]; then
      echo "[VERSION] $repo:$target not found in the registry"
      exit 1
    fi
    [[ $new != "$current" ]] || continue

    old_label=$(version_label "$repo" "$current")
    new_label=$(version_label "$repo" "$new")
    names+=("$name")
    digests+=("$new")
    from+="${from:+_}$old_label"
    to+="${to:+_}$new_label"
    echo "[VERSION] Upgrade $name from $old_label to $new_label"
  done

  if [[ ${#names[@]} -eq 0 ]]; then
    echo "[VERSION] $SERVICE_DIR_NAME is up to date"
    return 0
  fi

  failure=$(version_unhealthy)
  if [[ -n $failure ]]; then
    echo "[VERSION] $SERVICE_DIR_NAME is not healthy, aborting:"
    echo "$failure" | sed 's/^/          /'
    exit 1
  fi
  if [[ -n $(version_containers) ]]; then
    running=true
  fi

  if [[ $1 != "-y" ]]; then
    printf "[VERSION] Proceed?(y/N): "
    read -n 1 -r
    echo
    case "$REPLY" in
    [yY]) ;;
    *)
      echo "          exiting"
      exit 1
      ;;
    esac
  fi

  local backup="$VERSION_ARCHIVE$from"
  local message="upgrade-from-$from-to-$to"

  echo "[VERSION] Pulling the new images..."
  for i in "${!names[@]}"; do
    export "${names[i]}_CURRENT=${digests[i]}"
  done
  cmd_docker pull

  if $running; then
    version_run down
  fi

  version_replace "$backup"
  if ! version_run backup "$backup"; then
    if $running; then
      version_run up
    fi
    echo "[VERSION] Backup failed, $SERVICE_DIR_NAME was not upgraded"
    exit 1
  fi

  for i in "${!names[@]}"; do
    sed -i "s|^${names[i]}_CURRENT=.*|${names[i]}_CURRENT=${digests[i]}|" .version
  done

  if ! version_run up; then
    failure="it did not start"
  else
    echo "[VERSION] Waiting up to $VERSION_TIMEOUT seconds for $SERVICE_DIR_NAME to get healthy..."
    failure=$(version_wait) || failure="it did not get healthy:"$'\n'"$failure"
  fi

  if [[ -z $failure ]]; then
    version_replace "commit: $message"
    # without a change there is nothing to commit, e.g. when an upgrade is
    # repeated after its backup was restored by hand
    if [[ -n $(git status --porcelain) ]]; then
      version_run commit "$message" || failure="commit"
    else
      version_run backup "commit: $message" || failure="backup"
    fi
    if [[ -n $failure ]]; then
      echo "[VERSION] Upgraded $SERVICE_DIR_NAME, but the $failure failed"
      exit 1
    fi
    echo "[VERSION] Upgraded $SERVICE_DIR_NAME"
    return 0
  fi

  echo "[VERSION] Upgrade failed, restoring '$backup'..."
  version_run down
  version_run borg restore-diff "$backup" --clean-git
  if $running; then
    version_run up
  fi

  echo "[VERSION] Upgrade of $SERVICE_DIR_NAME was rolled back, $failure"
  exit 1
}
