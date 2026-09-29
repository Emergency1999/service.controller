# WILDCARD TARGETS
# A target may hold "*" in place of a number, e.g. "8.*.*" or "8.*.*-rc".
# It stands for the tag with the highest numbers, where a number further left
# counts more: "8.*.*" is 8.19.22 rather than 8.18.30.
#
# With a client for the registry the tag is picked from the tags of the repo,
# which the client offers as
#   registry_<client>_list <repo> <filter> <known>
# printing the tags that hold <filter>, one per line, newest first, at least
# up to <known>.
# Without one the tag is found by counting up from the known tag.
# The known tag is the highest one of the history.

# version_wildcard_regex <pattern>: the regular expression of a pattern, with
# one group per "*"
version_wildcard_regex() {
  local regex
  regex=$(sed -e 's/[][\.|$(){}?+^]/\\&/g' -e 's/\*/([0-9]+)/g' <<<"$1")
  echo "^$regex\$"
}

# version_wildcard_filter <pattern>: the longest part of a pattern without a
# "*", which every tag it stands for has to hold
version_wildcard_filter() {
  tr '*' '\n' <<<"$1" | awk 'length($0) > length(best) { best = $0 } END { print best }'
}

# version_wildcard_fill <pattern> <number...>: the tag with the numbers in
# place of the "*"
version_wildcard_fill() {
  local tag="$1" number
  shift
  for number in "$@"; do
    tag="${tag/\*/$number}"
  done
  echo "$tag"
}

# version_wildcard_best <pattern>: reads tags, one per line, and prints the one
# with the highest numbers
version_wildcard_best() {
  local regex tag key number i best="" best_key=""
  regex=$(version_wildcard_regex "$1")

  while read -r tag; do
    [[ $tag =~ $regex ]] || continue

    key=""
    for ((i = 1; i < ${#BASH_REMATCH[@]}; i++)); do
      printf -v number '%020d' "$((10#${BASH_REMATCH[i]}))"
      key+="$number"
    done
    if [[ -z $best || $key > $best_key ]]; then
      best="$tag"
      best_key="$key"
    fi
  done

  [[ -n $best ]] || return 1
  echo "$best"
}

# version_wildcard_known <repo> <pattern>: the highest tag of the history
version_wildcard_known() {
  [[ -f $SERVICE_DIR/$VERSION_HISTORY ]] || return 0
  awk -F'\t' -v r="$1" 'FNR > 1 && $2 == r { print $1; print $4 }' "$SERVICE_DIR/$VERSION_HISTORY" |
    tr ',' '\n' | version_wildcard_best "$2" || true
}

# version_wildcard_count <repo> <pattern> <known>: finds the tag by counting
# up, the leftmost number first. A number that was raised starts the ones right
# of it again, at 0 or 1. Without a known tag every number starts there.
version_wildcard_count() {
  local repo="$1" pattern="$2" known="$3" stars i j bits tag found
  local -a numbers=() next=()
  stars="${pattern//[^*]/}"

  if [[ -n $known ]]; then
    [[ $known =~ $(version_wildcard_regex "$pattern") ]]
    numbers=("${BASH_REMATCH[@]:1}")
  fi

  # i is the number that is raised, -1 looks for the tag to start with
  for ((i = ${#numbers[@]} > 0 ? 0 : -1; i < ${#stars}; i++)); do
    while true; do
      found=false
      for ((bits = 0; bits < 1 << (${#stars} - i - 1); bits++)); do
        next=("${numbers[@]}")
        ((i < 0)) || next[i]=$((10#${numbers[i]} + 1))
        for ((j = i + 1; j < ${#stars}; j++)); do
          next[j]=$(((bits >> (${#stars} - j - 1)) & 1))
        done

        tag=$(version_wildcard_fill "$pattern" "${next[@]}")
        if version_digest_docker "$repo" "$tag" &>/dev/null; then
          numbers=("${next[@]}")
          found=true
          break
        fi
      done
      $found && ((i >= 0)) || break
    done
    [[ ${#numbers[@]} -gt 0 ]] || return 1
  done

  version_wildcard_fill "$pattern" "${numbers[@]}"
}

# version_wildcard_tag <repo> <pattern>: the tag a pattern stands for
version_wildcard_tag() {
  local known tags
  known=$(version_wildcard_known "$1" "$2")

  if version_registry "$1" && declare -F "registry_${registry_client}_list" >/dev/null; then
    tags=$(registry_${registry_client}_list "$registry_repo" "$(version_wildcard_filter "$2")" "$known") || return 1
    version_wildcard_best "$2" <<<"$tags"
  else
    version_wildcard_count "$1" "$2" "$known"
  fi
}
