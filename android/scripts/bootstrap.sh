#!/usr/bin/env bash
# First step on the phone, inside Termux (from F-Droid, with Termux:API and
# Termux:Boot installed alongside it):
#
#   curl -fsSL <raw url of this file> | bash     or     bash bootstrap.sh
#
# Installs what vivac needs from Termux's own repository (nothing is
# compiled on the phone), clones the repo into ~/vivac (only fast-forwards it
# on later runs) and runs the android deploy. Safe to run again.
set -Eeuo pipefail

url="${VIVAC_REPO_URL:-https://github.com/gitsual/vivac.git}"
dest="$HOME/vivac"

pkg install -y python python-cryptography openssh termux-api git

if [[ -d "$dest/.git" || -d "$dest/android" ]]; then
	git -C "$dest" pull --ff-only
else
	git clone --depth 1 "$url" "$dest"
fi

bash "$dest/android/scripts/deploy.sh"
