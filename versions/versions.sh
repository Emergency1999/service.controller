# VERSION COMMANDS
# A service with a .version file has its image versions managed. The file holds
# three variables per image:
#   <name>_REPO     the image, without tag
#   <name>_TARGET   the tag that is followed, "*" stands for the highest number
#   <name>_CURRENT  the digest that is installed
declare -A version_commands=(
  [add]="<name> <repo> <target>:Add an image to .version and put it into docker-compose.yml"
  [info]=":Show the current and the target hash of every image with their tags"
  [search]="<name/repo> <hash/tag>:Show all tags that belong to a hash or tag of an image of .version or of a repo"
  [running]=":Show the hash of the image of every running container with its tags and dates"
  [history]="[name]:List the backups of the versions replaced by auto-upgrade and the installed version, of one image or of all"
  ["auto-upgrade"]="[-y]:Upgrade to the digests the target tags point to"
)

# backups of replaced versions; borg_prune keeps archives starting with "+"
VERSION_ARCHIVE="+upgrade-from-"

# VERSION SUB COMMAND
commands+=([version]=":Manage image versions")
cmd_version() {
  local command="$1"

  if [[ ! " ${!version_commands[@]} " =~ " $command " ]]; then
    print_help "version " "version_commands"
    if ! [[ -z "$command" ]]; then
      echo
      echo "Unknown command: version $command"
    fi
    exit 1
  fi

  if [[ " info history auto-upgrade " == *" $command "* && ! -s "$SERVICE_DIR/.version" ]]; then
    echo "[VERSION] $SERVICE_DIR_NAME has no .version file"
    exit 1
  fi

  cd $SERVICE_DIR
  shift # remove first argument ("version" command)
  version_$command "$@"
}

source "$CORE_DIR/versions/registry.sh"
source "$CORE_DIR/versions/wildcard.sh"
source "$CORE_DIR/versions/upgrade.sh"

# FUNCTIONS

# version_names: the images in .version
version_names() {
  sed -nE 's/^([A-Za-z0-9_]+)_REPO=.*/\1/p' "$SERVICE_DIR/.version"
}

# version_check: every image needs all three variables and has to be used by
# docker-compose.yml as "image: ${<name>_REPO}@${<name>_CURRENT}"
version_check() {
  local name failed=false

  for name in $(version_names); do
    if ! grep -q "^${name}_TARGET=" .version || ! grep -q "^${name}_CURRENT=" .version; then
      echo "[VERSION] .version needs ${name}_TARGET and ${name}_CURRENT"
      failed=true
    fi
    if ! grep -Eq "image: *[\"']?[$][{]?${name}_REPO[}]?@[$][{]?${name}_CURRENT[}]?" docker-compose.yml; then
      echo "[VERSION] docker-compose.yml has no \"image: \${${name}_REPO}@\${${name}_CURRENT}\""
      failed=true
    fi
  done

  if $failed; then
    exit 1
  fi
}

# version_load <name>: sets $repo, $target and $current from the loaded
# .version and $new, the digest the target points to
version_load() {
  local var
  var="$1_REPO" && repo="${!var}"
  var="$1_TARGET" && target="${!var}"
  var="$1_CURRENT" && current="${!var}"
  new=""

  [[ -n $target ]] || return 1
  new=$(version_digest "$repo" "$target")
}

# version_ignore: keeps the history out of git. It changes by commands that
# only read, and every borg backup holds it anyway.
version_ignore() {
  local ignore="$SERVICE_DIR/.gitignore"

  if ! grep -qsxF "$VERSION_HISTORY" "$ignore"; then
    # a last line without its end would take up the one that is added
    [[ ! -s $ignore || -z $(tail -c1 "$ignore") ]] || echo >>"$ignore"
    echo "$VERSION_HISTORY" >>"$ignore"
  fi
}

# version_init: gives every image with an empty <name>_CURRENT the digest its
# target points to and keeps the history out of git. Called by docker_up and
# docker_pull, a service without a .version file is left alone.
version_init() {
  local name var repo target current new i
  local -a names=() digests=()

  [[ -s "$SERVICE_DIR/.version" ]] || return 0
  version_check
  version_ignore

  for name in $(version_names); do
    var="${name}_CURRENT"
    [[ -z ${!var} ]] || continue

    if ! version_load "$name"; then
      echo "[VERSION] $repo:$target not found in the registry"
      exit 1
    fi
    names+=("$name")
    digests+=("$new")
  done

  # written once every image was found, a failure leaves .version untouched
  for i in "${!names[@]}"; do
    sed -i "s|^${names[i]}_CURRENT=.*|${names[i]}_CURRENT=${digests[i]}|" .version
    export "${names[i]}_CURRENT=${digests[i]}"
    echo "[VERSION] Initialized ${names[i]} to ${digests[i]}"
  done
}

# version_describe <label> <repo> <digest>: prints the hash and the tags of a
# digest
version_describe() {
  local tags rc=0
  if [[ -z $3 ]]; then
    printf '          %-8shash: none\n' "$1"
    return
  fi

  tags=$(version_tags "$2" "$3") || rc=$?
  if [[ $rc -eq $VERSION_UNSUPPORTED ]]; then
    tags="registry is not supported"
  elif [[ $rc -ne 0 ]]; then
    tags="no tags found"
  fi
  printf '          %-8shash: %s\n' "$1" "$3"
  printf '          %-8stags: %s\n' "" "${tags//,/, }"
}

# version_find <repo> <hash/tag>: the digest that a hash or a tag stands for
version_find() {
  if [[ $2 =~ ^(sha256:)?([0-9a-f]{64})$ ]]; then
    echo "sha256:${BASH_REMATCH[2]}"
    return
  fi
  version_digest "$1" "$2"
}

# version_borg <arguments...>: runs borg the way cmd_borg does
version_borg() {
  borg_check
  BORG_RSH="$(echo $BORG_RSH | sed "s/~/\/home\/$USER/g")"
  sudo -E borg "$@"
}

version_add() {
  local name="${1^^}" repo="$2" target="$3"

  if [[ -z $name || -z $repo || -z $target ]]; then
    echo "[VERSION] name, repo and target are required"
    exit 1
  fi
  if grep -qs "^${name}_REPO=" .version; then
    echo "[VERSION] $name is in .version already"
    exit 1
  fi

  # a last line without its end would take up the first one that is added
  [[ ! -s .version || -z $(tail -c1 .version) ]] || echo >>.version
  printf '%s_REPO=%s\n%s_TARGET=%s\n%s_CURRENT=\n' "$name" "$repo" "$name" "$target" "$name" >>.version

  echo "[VERSION] Added $name to .version"

  # the image lines of the repo, with any tag or digest, quoted or not
  local image="\${${name}_REPO}@\${${name}_CURRENT}" lines
  local line="^([[:space:]]*image:[[:space:]]*)[\"']?${repo//./\\.}([:@][^\"'[:space:]#]*)?[\"']?([[:space:]]*#.*)?$"
  lines=$(grep -sE "$line" docker-compose.yml | sed 's/^[[:space:]]*//')
  if [[ -n $lines ]]; then
    sed -i -E "s|$line|\1$image\3|" docker-compose.yml
    echo "[VERSION] Replaced in docker-compose.yml by image: $image"
    echo "$lines" | sed 's/^/          /'
  else
    echo "[VERSION] No image of $repo found in docker-compose.yml, use it there as"
    echo "          image: $image"
  fi
}

version_info() {
  local name repo target current new rc
  local current_names="" update_names="" missing_names=""

  version_check

  for name in $(version_names); do
    rc=0
    version_load "$name" || rc=$?

    echo "[VERSION] $name: $repo:$target"
    version_describe current "$repo" "$current"
    if [[ $rc -ne 0 ]]; then
      echo "          target  not found in the registry"
      missing_names+="${missing_names:+, }$name"
    else
      version_describe target "$repo" "$new"
      if [[ $new != "$current" ]]; then
        echo "          update available"
        update_names+="${update_names:+, }$name"
      else
        current_names+="${current_names:+, }$name"
      fi
    fi
  done

  echo
  if [[ -n $current_names ]]; then
    echo "[VERSION] Up to date: $current_names"
  fi
  if [[ -n $update_names ]]; then
    echo "[VERSION] Update available: $update_names"
  fi
  if [[ -n $missing_names ]]; then
    echo "[VERSION] Target not found: $missing_names"
  fi
}

# version_time <time>: a time of docker as the date and time of this host
version_time() {
  # docker writes the year 1 for a time it does not know, date takes no time for now
  if [[ -z $1 || $1 == 0001-* ]]; then
    echo "unknown"
    return
  fi
  date -d "$1" '+%F %H:%M' 2>/dev/null || echo "unknown"
}

# version_running: the image of every running container. One that was started
# by a tag has the digest the tag had when it was pulled, which is the one of
# all architectures and not the one a .version would hold.
# docker keeps no time of the pull, but the time the image got its name, which
# is the last pull of it. The container tells since when the image is in use.
# What is found is added to the history.
version_running() {
  local ids id name image identity created pulled repo tag digest
  ids=$(docker compose -p $SERVICE_DIR_NAME ps -q)

  if [[ -z $ids ]]; then
    echo "[VERSION] No container of $SERVICE_DIR_NAME is running"
    return 0
  fi
  version_ignore

  for id in $ids; do
    read -r name image identity created < <(docker inspect --format '{{.Name}} {{.Config.Image}} {{.Image}} {{.Created}}' "$id")
    pulled=$(docker image inspect --format '{{json .Metadata.LastTagTime}}' "$identity" | tr -d '"')
    repo="${image%@*}"
    tag=""
    # what follows the last colon is a tag, unless it is the port of a registry
    if [[ $repo == *:* && ${repo##*:} != */* ]]; then
      tag="${repo##*:}"
      repo="${repo%:*}"
    fi
    if [[ $image == *@* ]]; then
      digest="${image#*@}"
    else
      digest=$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$identity" | sed -n 's/.*@//p' | head -n1)
      # an image whose tag was pulled again has lost its name, not its digest
      digest="${digest:-$identity}"
    fi

    version_remember "$tag" "$repo" "$digest"
    echo "[VERSION] ${name#/}: $image"
    version_describe running "$repo" "$digest"
    echo "                pulled: $(version_time "$pulled")"
    echo "               created: $(version_time "$created")"
  done
}

# version_search <name/repo> <hash/tag>: what is searched in is an image of
# .version, given by its name, or else a repo
version_search() {
  local name="$1" query="$2" names="" var repo digest tags rc=0

  if [[ -z $name || -z $query ]]; then
    echo "[VERSION] name or repo and hash or tag are required"
    exit 1
  fi

  if [[ -s "$SERVICE_DIR/.version" ]]; then
    names=$(version_names)
  fi
  if grep -qxF "${name^^}" <<<"$names"; then
    var="${name^^}_REPO" && repo="${!var}"
    name="${name^^}: $repo"
  else
    repo="$name"
  fi
  version_ignore

  if ! digest=$(version_find "$repo" "$query"); then
    echo "[VERSION] $query not found in $repo"
    exit 1
  fi

  tags=$(version_tags "$repo" "$digest") || rc=$?
  if [[ $rc -eq $VERSION_UNSUPPORTED ]]; then
    tags="registry is not supported"
  elif [[ $rc -ne 0 ]]; then
    tags="no tags found"
  fi

  echo "[VERSION] $name"
  echo "          hash: $digest"
  echo "          tags: ${tags//,/, }"
  [[ $rc -eq 0 ]] || exit 1
}

# version_image <repo>: the name of the image of .version with the repo
version_image() {
  local name var
  for name in $(version_names); do
    var="${name}_REPO"
    if [[ ${!var} == "$1" ]]; then
      echo "$name"
      return
    fi
  done
}

# version_history [name]: the backups with the digests and tags that the history
# holds for the short hashes in their names, and the installed version the
# same way, each digest with the name of its image. With a name only that
# image and the backups that hold it.
# A name may end with a counter, see version_unique.
version_history() {
  local only="${1^^}" archives archive short repo digest name var installed="" lines
  if [[ -n $only ]] && ! version_names | grep -qxF "$only"; then
    echo "[VERSION] $only is not in .version"
    exit 1
  fi

  echo "[VERSION] Versions replaced by auto-upgrade:"
  archives=$(version_borg list --glob-archives "$VERSION_ARCHIVE*" --format '{archive}{NL}')

  for archive in $archives; do
    lines=""
    short="${archive#"$VERSION_ARCHIVE"}"
    for short in $(tr '_' '\n' <<<"${short%.*}"); do
      read -r repo digest < <(awk -F'\t' -v s="$short" '$5 == s { print $2, $3; exit }' "$SERVICE_DIR/$VERSION_HISTORY") || continue
      name=$(version_image "$repo")
      [[ -z $only || $name == "$only" ]] || continue
      lines+="$(version_describe "$name" "$repo" "$digest")"$'\n'
    done
    [[ -z $only || -n $lines ]] || continue
    echo "$archive"
    printf '%s' "$lines"
  done

  echo "[VERSION] Installed version:"
  for name in $(version_names); do
    [[ -z $only || $name == "$only" ]] || continue
    var="${name}_CURRENT" && short="${!var:7:12}"
    installed+="${installed:+_}${short:-none}"
  done
  echo "$installed"
  for name in $(version_names); do
    [[ -z $only || $name == "$only" ]] || continue
    var="${name}_REPO" && repo="${!var}"
    var="${name}_CURRENT" && version_describe "$name" "$repo" "${!var}"
  done
}
