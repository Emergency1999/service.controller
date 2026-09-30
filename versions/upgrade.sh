# AUTO-UPGRADE

VERSION_TIMEOUT=300 # seconds a service has to get healthy in after an upgrade
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

# version_passed <condition>: says that a condition of the upgrade is met
version_passed() {
  printf '[VERSION] %-40s ok\n' "$1"
}

# version_unique <name> <archives>: the name for a new backup. If the archives,
# one per line, hold the name already, a counter is put to its end: the second
# backup of a name is <name>.2
version_unique() {
  awk -v b="$1" '
    $0 == b && n < 1 { n = 1 }
    index($0, b ".") == 1 { c = substr($0, length(b) + 2) + 0; if (c > n) n = c }
    END { print (n ? b "." (n + 1) : b) }' <<<"$2"
}

version_auto-upgrade() {
  local name repo target current new short i archives
  local from="" to="" running=false failure="" restore
  local -a names=() repos=() targets=() currents=() digests=()

  # every condition that is met is said, the one that is not ends the upgrade
  version_check
  version_passed ".version fits docker-compose.yml"

  for name in $(version_names); do
    if ! version_load "$name"; then
      echo "[VERSION] $repo:$target not found in the registry"
      exit 1
    fi
    [[ $new != "$current" ]] || continue

    names+=("$name")
    repos+=("$repo")
    targets+=("$target")
    currents+=("$current")
    digests+=("$new")
    # backups are named by the short hashes, which the history holds as well
    [[ -z $current ]] || version_remember "" "$repo" "$current"
    short="${current:7:12}"
    from+="${from:+_}${short:-none}"
    to+="${to:+_}${new:7:12}"
  done
  version_passed "Targets found in the registries"

  if [[ ${#names[@]} -eq 0 ]]; then
    echo "[VERSION] $SERVICE_DIR_NAME is up to date"
    return 0
  fi

  local backup="$VERSION_ARCHIVE$from"
  local message="upgrade-to-$to"
  local commit="commit: $message"

  failure=$(version_unhealthy)
  if [[ -n $failure ]]; then
    echo "[VERSION] $SERVICE_DIR_NAME is not healthy, aborting:"
    echo "$failure" | sed 's/^/          /'
    exit 1
  fi
  version_passed "All containers are healthy"
  if [[ -n $(version_containers) ]]; then
    running=true
  fi
  if ! archives=$(version_borg list --format '{archive}{NL}'); then
    echo "[VERSION] The borg repository is not reachable, aborting"
    exit 1
  fi
  version_passed "Borg repository is reachable"
  version_mountable

  for i in "${!names[@]}"; do
    echo "[VERSION] Upgrade ${names[i]}: ${repos[i]}:${targets[i]}"
    version_describe from "${repos[i]}" "${currents[i]}"
    version_describe to "${repos[i]}" "${digests[i]}"
  done
  # a backup of an earlier upgrade is kept, the new one gets a name of its own
  backup=$(version_unique "$backup" "$archives")
  commit=$(version_unique "$commit" "$archives")

  if [[ $1 != "-y" ]]; then
    printf "[VERSION] Proceed?(y/N): "
    read -r
    case "$REPLY" in
    [yY][eE][sS] | [yY]) ;;
    *)
      echo "          exiting"
      exit 1
      ;;
    esac
  fi

  echo "[VERSION] Pulling the new images..."
  for i in "${!names[@]}"; do
    export "${names[i]}_CURRENT=${digests[i]}"
  done
  cmd_docker pull
  # images that are built on one of the new ones are built anew
  cmd_docker build

  if $running; then
    version_run down
  fi

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
    # only .version is committed, other changes of the service are left alone.
    # Without a change there is nothing to commit, e.g. when an upgrade is
    # repeated after its backup was restored by hand
    if [[ -n $(git status --porcelain -- .version) ]]; then
      git add .version && git commit -m "$message" -- .version || failure="commit"
    fi
    [[ -n $failure ]] || version_run backup "$commit" || failure="backup"
    if [[ -n $failure ]]; then
      echo "[VERSION] Upgraded $SERVICE_DIR_NAME, but the $failure failed"
      exit 1
    fi
    echo "[VERSION] Upgraded $SERVICE_DIR_NAME"
    return 0
  fi

  echo "[VERSION] Upgrade failed, restoring '$backup'..."
  if version_restore "$backup" -n; then
    echo "[VERSION] Upgrade of $SERVICE_DIR_NAME was rolled back, $failure"
  else
    echo "[VERSION] Upgrade of $SERVICE_DIR_NAME failed and so did the rollback, restore '$backup' by hand."
    echo "          $failure"
  fi
  exit 1
}

# version_mountable: sets $restore to the restore that fits: restore-diff
# with FUSE, restore-fresh without, which is said
version_mountable() {
  restore="restore-diff"
  if version_borg debug info 2>/dev/null | grep -q 'fuse: None'; then
    restore="restore-fresh"
    echo "[VERSION] Borg cannot mount backups, a restore is fresh"
  fi
}

# version_restore <backup> [-y/-n]: stops the service, restores the backup
# and starts the service again if it was running. A backup of the state
# before is made with -y, not made with -n, else it is asked for.
version_restore() {
  local name="$1" answer="$2" restore running=false

  if [[ -z $name ]]; then
    echo "[VERSION] name of the backup is required"
    exit 1
  fi
  if [[ -z $answer ]]; then
    printf "[VERSION] Make a backup of the current state first?(y/N): "
    read -r answer
  fi
  case "$answer" in
  -[yY] | [yY][eE][sS] | [yY]) version_run backup latest ;;
  esac

  version_mountable
  if [[ -n $(version_containers) ]]; then
    running=true
  fi
  if version_run down && version_run borg "$restore" "$name" --clean-git && { ! $running || version_run up; }; then
    echo "[VERSION] Restored $SERVICE_DIR_NAME from '$name'"
  else
    echo "[VERSION] Restore of $SERVICE_DIR_NAME from '$name' failed"
    return 1
  fi
}
