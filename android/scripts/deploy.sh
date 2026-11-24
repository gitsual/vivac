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
reload=0
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

# 4. Termux looks like Linux's terminal: kitty wears the theme's terminal
# background and foreground (from the theme named in ~/.config/vivac/settings,
# the same setting the other halves read; the default palette when none is
# named or the name is not a shipped one) and keeps kitty's own cursor colour
# and sixteen colours, which are copied here as they are.
theme="$(sed -n 's/^theme=//p' "$HOME/.config/vivac/settings" 2>/dev/null | tail -1)" || theme=""
palette="$here/data/theme.conf"
if [[ "$theme" =~ ^[a-z][a-z0-9-]*$ && -f "$here/data/themes/$theme.conf" ]]; then
	palette="$here/data/themes/$theme.conf"
fi
colour() { sed -n "s/^$1=\([0-9A-Fa-f]\{6\}\)$/\1/p" "$palette" | tail -1 | tr 'A-F' 'a-f'; }
kitty_colours="color0=#000000
color1=#cc0403
color2=#19cb00
color3=#cecb00
color4=#0d73cc
color5=#cb1ed1
color6=#0dcdcd
color7=#dddddd
color8=#767676
color9=#f2201f
color10=#23fd00
color11=#fffd00
color12=#1a8fff
color13=#fd28ff
color14=#14ffff
color15=#ffffff"
colors="$HOME/.termux/colors.properties"
colors_body="# Written by vivac android/scripts/deploy.sh from $(basename "$palette" .conf); rewritten on every deploy.
background=#$(colour TERMINAL_BG)
foreground=#$(colour TERMINAL_FG)
cursor=#cccccc
$kitty_colours
"
if [[ ! -f "$colors" ]] || [[ "$(cat "$colors")"$'\n' != "$colors_body" ]]; then
	if [[ -e "$colors" ]] && ! grep -q 'Written by vivac' "$colors"; then backup "$colors"; fi
	if ((dry)); then
		say "would: write $colors"
	else
		mkdir -p "$(dirname "$colors")"
		printf '%s' "$colors_body" >"$colors"
		say "wrote $colors"
		reload=1
	fi
fi

# 5. kitty's font, Fira Code 6.2 (published only inside its release zip),
# pinned by the checksum of the TTF itself, the same file Arch's ttf-fira-code
# installs: a download that fails or does not match is dropped and the deploy
# carries on without it.
font="$HOME/.termux/font.ttf"
font_url="https://github.com/tonsky/FiraCode/releases/download/6.2/Fira_Code_v6.2.zip"
font_sha="${VIVAC_FONT_SHA256:-5992ab9640e2df491b2f609467b1de60e8bc39b2c28db184342a0592d98f6117}"
if ! { [[ -f "$font" ]] && [[ "$(sha256sum "$font" | cut -d' ' -f1)" == "$font_sha" ]]; }; then
	if ((dry)); then
		say "would: download Fira Code into $font"
	else
		zip="$(mktemp)" tmp="$(mktemp)"
		if ! command -v unzip >/dev/null 2>&1; then
			say "skipped $font: needs unzip (pkg install unzip)"
		elif curl -fsSL "$font_url" -o "$zip" && unzip -p "$zip" ttf/FiraCode-Regular.ttf >"$tmp" 2>/dev/null &&
			[[ "$(sha256sum "$tmp" | cut -d' ' -f1)" == "$font_sha" ]]; then
			[[ -e "$font" ]] && backup "$font"
			mkdir -p "$(dirname "$font")"
			cat "$tmp" >"$font"
			say "wrote $font"
			reload=1
		else
			say "skipped $font: the download failed or did not match its checksum"
		fi
		rm -f -- "$zip" "$tmp"
	fi
fi

# 6. kitty's cursor: a beam blinking every half second. Edits these keys in
# place; every other setting in termux.properties is kept.
props="$HOME/.termux/termux.properties"
for kv in 'terminal-cursor-style = bar' 'terminal-cursor-blink-rate = 500'; do
	key="${kv%% =*}"
	[[ -f "$props" ]] && grep -qx -- "$kv" "$props" && continue
	if ((dry)); then
		say "would: set $kv in $props"
		continue
	fi
	mkdir -p "$(dirname "$props")"
	touch "$props"
	tmp="$(mktemp)"
	awk -v key="$key" -v line="$kv" 'BEGIN{done=0}
		$0 ~ "^#?[[:space:]]*" key "[[:space:]]*=" { if (!done) { print line; done=1 } next }
		{ print }
		END { if (!done) print line }' "$props" >"$tmp"
	cat "$tmp" >"$props"
	rm -f -- "$tmp"
	say "set $kv in $props"
	reload=1
done

if ((reload)); then
	command -v termux-reload-settings >/dev/null 2>&1 && termux-reload-settings || true
fi
