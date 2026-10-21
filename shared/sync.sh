#!/usr/bin/env bash
# Copy what both systems share (shared/data/) into linux/data/ and
# windows/data/. Each side keeps its own copy so it deploys on its own; this
# is the only way those copies change.
#
#   shared/sync.sh           copy, and say what changed
#   shared/sync.sh --check   change nothing; exit 1 and name every copy that
#                            differs (what both sides' gates run)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"
check=0
[[ "${1:-}" == "--check" ]] && check=1

drift=0
while IFS= read -r -d '' src; do
  rel="${src#"$here"/}"
  for side in linux windows; do
    dest="$root/$side/$rel"
    if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then continue; fi
    if (( check )); then
      echo "drift: $side/$rel differs from shared/$rel" >&2
      drift=1
    else
      mkdir -p "$(dirname "$dest")"
      cp "$src" "$dest"
      echo "updated $side/$rel"
    fi
  done
done < <(find "$here/data" -type f -print0 | sort -z)

exit "$drift"
