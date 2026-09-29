# Docker Hub client. Reads the web API, which lists tags with their digests.
version_registries+=([docker.io]="dockerhub")

DOCKERHUB_API=https://hub.docker.com/v2/repositories
DOCKERHUB_MAX_PAGES=5 # pages of 100 tags searched for a digest

# registry_dockerhub_digest <repo> <tag>: the digest the tag points to.
# It is the digest of the image for this host's architecture, not of the
# multi-arch index: tags of the same version carry different index digests when
# their architecture lists differ.
registry_dockerhub_digest() {
  local repo="$1" body
  [[ $repo == */* ]] || repo="library/$repo"

  body=$(curl -fsS "$DOCKERHUB_API/$repo/tags/$2") || return 1
  jq -r --arg a "$(docker version --format '{{.Server.Arch}}')" \
    '[.images[] | select(.os == "linux" and .architecture == $a)][0].digest // empty' <<<"$body"
}

# registry_dockerhub_tags <repo> <digest>: the tags pointing to the digest,
# one per line
registry_dockerhub_tags() {
  local repo="$1" url body found seen="" page
  [[ $repo == */* ]] || repo="library/$repo"

  url="$DOCKERHUB_API/$repo/tags?page_size=100&ordering=last_updated"
  for ((page = 1; page <= DOCKERHUB_MAX_PAGES; page++)); do
    body=$(curl -fsS "$url") || return 1
    found=$(jq -r --arg d "$2" '.results[]
      | select(.digest == $d or any(.images[]; .digest == $d))
      | .name' <<<"$body")
    if [[ -n $found ]]; then
      seen=1
      echo "$found"
    elif [[ -n $seen ]]; then
      break
    fi
    url=$(jq -r '.next // empty' <<<"$body")
    [[ -n $url ]] || break
  done
}
