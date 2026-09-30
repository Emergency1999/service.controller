# REGISTRY INTERFACE
# Finds the digest of a tag and the tags of a digest.
#
# A client in registries/<client>.sh adds the hosts it serves to
# version_registries and defines
#   registry_<client>_digest <repo> <tag>     the digest the tag points to
#   registry_<client>_tags <repo> <digest>    the tags pointing to the digest, one per line
# and, for wildcard targets, registry_<client>_list as described in wildcard.sh.
# <repo> is passed without the host.
#
# Without a client for a registry the digest of a tag is asked through docker.
# That works with every registry, but counts as a pull where pulls are limited.
# The tags of a digest are not known then.

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

# version_digest_docker <repo> <tag>: the digest the tag points to, the one of
# the image for this host's architecture
version_digest_docker() {
  local manifest digest
  manifest=$(docker buildx imagetools inspect "$1:$2" --format '{{json .Manifest}}') || return 1

  digest=$(jq -r --arg a "$(docker version --format '{{.Server.Arch}}')" '
    if (.manifests // []) | length > 0
    then [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $a)][0].digest // empty
    else .digest // empty
    end' <<<"$manifest") || return 1
  [[ -n $digest ]] || return 1
  echo "$digest"
}

# version_digest <repo> <tag>: the digest the tag points to, which is kept in
# the history with the tag. The tag may be a wildcard target, see wildcard.sh.
version_digest() {
  local tag="$2" digest history="$SERVICE_DIR/$VERSION_HISTORY"
  if [[ $tag == *"*"* ]]; then
    tag=$(version_wildcard_tag "$1" "$tag") || return 1
  fi
  # docker is asked without a client and if the client does not find the tag
  if ! version_registry "$1" || ! digest=$(registry_${registry_client}_digest "$registry_repo" "$tag") || [[ -z $digest ]]; then
    digest=$(version_digest_docker "$1" "$tag") || return 1
  fi

  version_remember "$tag" "$1" "$digest"
  echo "$digest"
}

# version_remember <tag> <repo> <digest>: adds the digest to the history, with
# the tag that led to it and its short hash, by which backups are named.
# Without a tag any line of the digest will do.
version_remember() {
  local history="$SERVICE_DIR/$VERSION_HISTORY"

  [[ -f $history ]] || printf 'tag\trepo\tdigest\ttags\tshort\n' >"$history"
  # "" makes awk compare the tags as text, 8 and 8.0 are the same number
  awk -F'\t' -v t="$1" -v r="$2" -v d="$3" \
    '(t == "" || $1 "" == t "") && $2 == r && $3 == d { found = 1 } END { exit !found }' "$history" ||
    printf '%s\t%s\t%s\t\t%s\n' "$1" "$2" "$3" "${3:7:12}" >>"$history"
}

# version_pulled <repo> <digest>: the tags that led to the digest, comma-separated
version_pulled() {
  [[ -f $SERVICE_DIR/$VERSION_HISTORY ]] || return 0
  awk -F'\t' -v r="$1" -v d="$2" '$2 == r && $3 == d && $1 != "" { print $1 }' "$SERVICE_DIR/$VERSION_HISTORY" | paste -sd,
}

# version_tags <repo> <digest>: the tags pointing to the digest, comma-separated.
# Answers from the history, which is never brought up to date: it tells what a
# digest was when it was found. The registry is only asked as long as it did
# not know a tag.
version_tags() {
  local history="$SERVICE_DIR/$VERSION_HISTORY" tags=""

  if [[ -f $history ]]; then
    tags=$(awk -F'\t' -v r="$1" -v d="$2" '$2 == r && $3 == d && $4 != "" { print $4; exit }' "$history")
  fi

  if [[ -z $tags ]] && version_registry "$1"; then
    tags=$(registry_${registry_client}_tags "$registry_repo" "$2") || tags=""
    tags=$(paste -sd, <<<"$tags")
    if [[ -n $tags ]]; then
      version_remember "" "$1" "$2"
      awk -F'\t' -v OFS='\t' -v r="$1" -v d="$2" -v t="$tags" \
        '$2 == r && $3 == d { $4 = t } { print }' "$history" >"$history.tmp"
      mv "$history.tmp" "$history"
    fi
  fi

  if [[ -z $tags ]]; then
    version_registry "$1" || return
    return 1
  fi
  echo "$tags"
}
