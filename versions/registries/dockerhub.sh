# Docker Hub client. Reads the web API, which lists tags with their digests.
version_registries+=([docker.io]="dockerhub")

DOCKERHUB_API=https://hub.docker.com/v2/repositories
DOCKERHUB_MAX_PAGES=5 # pages of 100 tags searched for a digest
DOCKERHUB_MAX_LIST_PAGES=10 # pages of 100 tags listed for a wildcard target, Docker Hub offers no more
DOCKERHUB_AUTH=https://index.docker.io/v1/ # key of Docker Hub in ~/.docker/config.json

# dockerhub_token: the token of the docker login at Docker Hub, empty without
# one. Private repos are only found with it.
dockerhub_token() {
  local config="$HOME/.docker/config.json" store creds
  [[ -f $config ]] || return 0

  store=$(jq -r '.credsStore // empty' "$config")
  if [[ -n $store ]]; then
    creds=$(docker-credential-"$store" get <<<"$DOCKERHUB_AUTH" 2>/dev/null) || return 0
    creds=$(jq -c '{username: .Username, password: .Secret}' <<<"$creds")
  else
    creds=$(jq -r --arg k "$DOCKERHUB_AUTH" '.auths[$k].auth // empty' "$config" | base64 -d) || return 0
    [[ -n $creds ]] || return 0
    creds=$(jq -nc --arg c "$creds" '{username: ($c | sub(":.*"; "")), password: ($c | sub("^[^:]*:"; ""))}')
  fi

  curl -fsS -H 'Content-Type: application/json' -d "$creds" https://hub.docker.com/v2/users/login |
    jq -r '.token // empty'
}

# dockerhub_curl <url>: curl, logged in if docker is
dockerhub_curl() {
  [[ -n ${DOCKERHUB_TOKEN+x} ]] || DOCKERHUB_TOKEN=$(dockerhub_token) || DOCKERHUB_TOKEN=""
  if [[ -n $DOCKERHUB_TOKEN ]]; then
    curl -fsS -H "Authorization: Bearer $DOCKERHUB_TOKEN" "$1"
  else
    curl -fsS "$1"
  fi
}

# registry_dockerhub_digest <repo> <tag>: the digest the tag points to.
# It is the digest of the image for this host's architecture, not of the
# multi-arch index: tags of the same version carry different index digests when
# their architecture lists differ.
registry_dockerhub_digest() {
  local repo="$1" body
  [[ $repo == */* ]] || repo="library/$repo"

  body=$(dockerhub_curl "$DOCKERHUB_API/$repo/tags/$2") || return 1
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
    body=$(dockerhub_curl "$url") || return 1
    found=$(jq -r --arg d "$2" '.results[]
      | select(.digest == $d or any(.images[]; .digest == $d))
      | .name' <<<"$body") || return 1
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

# registry_dockerhub_list <repo> <filter> <known>: the tags that hold the
# filter and have an image for this host's architecture, one per line, newest
# first. Ends with the page that holds the known tag.
registry_dockerhub_list() {
  local repo="$1" arch url body page
  [[ $repo == */* ]] || repo="library/$repo"
  arch=$(docker version --format '{{.Server.Arch}}')

  url="$DOCKERHUB_API/$repo/tags?page_size=100&ordering=last_updated&name=$2"
  for ((page = 1; page <= DOCKERHUB_MAX_LIST_PAGES; page++)); do
    body=$(dockerhub_curl "$url") || return 1
    jq -r --arg a "$arch" '.results[]
      | select(any(.images[]; .os == "linux" and .architecture == $a))
      | .name' <<<"$body" || return 1

    [[ -z $3 ]] || ! jq -e --arg k "$3" 'any(.results[]; .name == $k)' <<<"$body" >/dev/null || break
    url=$(jq -r '.next // empty' <<<"$body")
    [[ -n $url ]] || break
  done
}
