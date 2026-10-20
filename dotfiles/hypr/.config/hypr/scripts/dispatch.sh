#!/usr/bin/env bash
# Send one classic Hyprland dispatcher to the running compositor, in whichever
# config language it was started with.
#
#   dispatch.sh workspace e+1
#   dispatch.sh dpms off
#
# For callers that cannot source a library: waybar scroll handlers, hypridle.
# Runs from the stowed symlink, so lib/hypr-ipc.sh is read from the checkout the
# symlink points into. The exit code is the helper's: 2 for a dispatcher it does
# not know.
set -Eeuo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo_root="${VIVAC_REPO:-$(cd -- "$(dirname -- "$self")/../../../../.." && pwd -P)}"
# shellcheck source=lib/hypr-ipc.sh
source "$repo_root/lib/hypr-ipc.sh"

hypr_dispatch "$@" >/dev/null
