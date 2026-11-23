#!/usr/bin/env bash
# Put the android half of vivac in place inside Termux.
#
#   scripts/deploy.sh            link the tools, write the boot script, harden sshd
#   scripts/deploy.sh --dry-run  say what would change, change nothing
#
# Same rules as the Linux deploy: nothing is ever deleted. A file of the
# user's own in the way is moved to $HOME/.local/state/vivac/backups/<stamp>/.
# Running it twice changes nothing the second time.
set -Eeuo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
prefix="${PREFIX:?not inside Termux: PREFIX is unset}"
dry=0
[[ "${1:-}" == "--dry-run" ]] && dry=1
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
backups="$HOME/.local/state/vivac/backups/$stamp"

say() { printf '%s\n' "$*"; }
act() {
	if ((dry)); then say "would: $*"; else "$@"; fi
}
backup() {
	local path="$1" rel="${1#"$prefix"/}"
	[[ "$rel" == "$1" ]] && rel="home/${1#"$HOME"/}"
	act mkdir -p "$(dirname "$backups/$rel")"
	act mv -- "$path" "$backups/$rel"
	say "backed up $path"
}

# 1. Tools into $PREFIX/bin.
for tool in "$here"/bin/*; do
	dest="$prefix/bin/$(basename "$tool")"
	[[ -L "$dest" && "$(readlink -- "$dest")" == "$tool" ]] && continue
	[[ -e "$dest" || -L "$dest" ]] && backup "$dest"
	act ln -s -- "$tool" "$dest"
	say "linked $dest"
done

# 2. Termux:Boot script: wake lock, sshd and whatever services later phases add.
boot="$HOME/.termux/boot/vivac"
boot_body="#!/data/data/com.termux/files/usr/bin/sh
# Written by vivac android/scripts/deploy.sh; rewritten on every deploy.
termux-wake-lock
sshd
"
if [[ ! -f "$boot" ]] || [[ "$(cat "$boot")"$'\n' != "$boot_body" ]]; then
	if [[ -e "$boot" ]] && ! grep -q 'Written by vivac' "$boot"; then backup "$boot"; fi
	if ((dry)); then
		say "would: write $boot"
	else
		mkdir -p "$(dirname "$boot")"
		printf '%s' "$boot_body" >"$boot"
		chmod 700 "$boot"
		say "wrote $boot"
	fi
fi

# 3. sshd: keys only. Edits one line in place; every other setting is kept.
conf="$prefix/etc/ssh/sshd_config"
if [[ -f "$conf" ]] && ! grep -qx 'PasswordAuthentication no' "$conf"; then
	if ((dry)); then
		say "would: set PasswordAuthentication no in $conf"
	else
		tmp="$(mktemp)"
		awk 'BEGIN{done=0}
			/^#?[[:space:]]*PasswordAuthentication[[:space:]]/ { if (!done) { print "PasswordAuthentication no"; done=1 } next }
			{ print }
			END { if (!done) print "PasswordAuthentication no" }' "$conf" >"$tmp"
		cat "$tmp" >"$conf"
		rm -f -- "$tmp"
		say "sshd: passwords refused"
	fi
fi

# 4. Termux wears the theme: the terminal colours Linux's kitty wears (its
# background and foreground) and the accent as the cursor, from the theme
# named in ~/.config/vivac/settings (the same setting the other halves read),
# the default palette when none is named or the name is not a shipped one.
theme="$(sed -n 's/^theme=//p' "$HOME/.config/vivac/settings" 2>/dev/null | tail -1)"
palette="$here/data/theme.conf"
if [[ "$theme" =~ ^[a-z][a-z0-9-]*$ && -f "$here/data/themes/$theme.conf" ]]; then
	palette="$here/data/themes/$theme.conf"
fi
colour() { sed -n "s/^$1=\([0-9A-Fa-f]\{6\}\)$/\1/p" "$palette" | tail -1 | tr 'A-F' 'a-f'; }
colors="$HOME/.termux/colors.properties"
colors_body="# Written by vivac android/scripts/deploy.sh from $(basename "$palette" .conf); rewritten on every deploy.
background=#$(colour TERMINAL_BG)
foreground=#$(colour TERMINAL_FG)
cursor=#$(colour COLOR_ACCENT)
"
if [[ ! -f "$colors" ]] || [[ "$(cat "$colors")"$'\n' != "$colors_body" ]]; then
	if [[ -e "$colors" ]] && ! grep -q 'Written by vivac' "$colors"; then backup "$colors"; fi
	if ((dry)); then
		say "would: write $colors"
	else
		mkdir -p "$(dirname "$colors")"
		printf '%s' "$colors_body" >"$colors"
		say "wrote $colors"
		command -v termux-reload-settings >/dev/null 2>&1 && termux-reload-settings || true
	fi
fi
