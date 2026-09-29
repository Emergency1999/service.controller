# REGISTRY INTERFACE
# Finds the digest of a tag and the tags of a digest.
#
# A client in registries/<client>.sh adds the hosts it serves to
# version_registries and defines
#   registry_<client>_digest <repo> <tag>     the digest the tag points to
#   registry_<client>_tags <repo> <digest>    the tags pointing to the digest, one per line
# <repo> is passed without the host.

VERSION_UNSUPPORTED=3 # return value: no client for the registry of the image
VERSION_HISTORY=".version-history.tsv"

declare -A version_registries=()

for client in "$CORE_DIR"/versions/registries/*.sh; do
  source "$client"
done

# version_registry <repo>: sets $registry_client and $registry_repo
version_registry() {
  local host="docker.io" first="${1%%/*}"
  registry_repo="$1"

  # the part before the first slash is a host if it looks like one
  if [[ $1 == */* && ($first == *.* || $first == *:* || $first == localhost) ]]; then
    host="$first"
    registry_repo="${1#*/}"
  fi

  registry_client="${version_registries[$host]:-}"
  [[ -n $registry_client ]] || return $VERSION_UNSUPPORTED
}

# version_digest <repo> <tag>: the digest the tag points to
version_digest() {
  local digest
  version_registry "$1" || return

  digest=$(registry_${registry_client}_digest "$registry_repo" "$2") || return 1
  [[ -n $digest ]] || return 1
  echo "$digest"
}

# version_digest_docker <repo> <tag>: the digest the tag points to, asked
# through docker. Needs no client, but cannot find the tags of a digest. Like
# the clients it answers with the image for this host's architecture.
version_digest_docker() {
  local manifest digest
  manifest=$(docker buildx imagetools inspect "$1:$2" --format '{{json .Manifest}}' 2>/dev/null) || return 1

  digest=$(jq -r --arg a "$(docker version --format '{{.Server.Arch}}')" '
    if (.manifests // []) | length > 0
    then [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $a)][0].digest // empty
    else .digest // empty
    end' <<<"$manifest") || return 1
  [[ -n $digest ]] || return 1
  echo "$digest"
}

# version_tags <repo> <digest>: the tags pointing to the digest, comma-separated.
# Answers from the history in the service folder; the registry is asked only
# for a digest that is not in there yet, and its answer is added.
version_tags() {
  local history="$SERVICE_DIR/$VERSION_HISTORY" tags=""

  if [[ -f $history ]]; then
    tags=$(awk -F'\t' -v r="$1" -v d="$2" '$2 == r && $3 == d { print $4; exit }' "$history")
  fi

  if [[ -z $tags ]]; then
    version_registry "$1" || return
    tags=$(registry_${registry_client}_tags "$registry_repo" "$2" | paste -sd,)
    [[ -n $tags ]] || return 1

    [[ -f $history ]] || printf 'time\trepo\tdigest\ttags\n' >"$history"
    printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$1" "$2" "$tags" >>"$history"
  fi

  echo "$tags"
}
