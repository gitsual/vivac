#!/usr/bin/env bash
set -Eeuo pipefail
output_dir="${XDG_SCREENSHOTS_DIR:-$HOME/Pictures/Screenshots}"
mkdir -p "$output_dir"
file="$output_dir/screenshot_$(date +%Y%m%d_%H%M%S).png"
geometry="$(slurp)" || exit 0
[[ -n "$geometry" ]] || exit 0
grim -g "$geometry" "$file"
wl-copy <"$file"
notify-send "Screenshot saved" "$file"
