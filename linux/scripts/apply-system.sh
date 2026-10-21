#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/kv.sh
source "$repo_root/lib/kv.sh"
# shellcheck source=lib/settings.sh
source "$repo_root/lib/settings.sh"
# shellcheck source=lib/render.sh
source "$repo_root/lib/render.sh"
settings_file="${SETTINGS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/vivac/settings}"
dry_run=false
locale_axis=false
keymap_axis=false
security=false
bluetooth=false
desktop_login=false
greeter=false
vm_profile=false
selection_made=false

usage() {
	cat <<'USAGE'
Usage: scripts/apply-system.sh [--dry-run] [--security] [--bluetooth] [--desktop-login] [--vm]
                               [--greeter] [--locale] [--keymap]

With no module selector, the backward-compatible security and Bluetooth profiles
are applied. Selectors compose without enabling unrelated services.

--greeter installs the graphical login (ReGreet in cage) in place of tuigreet,
rendered from the settings file: LANG for the greeter process and
XKB_DEFAULT_LAYOUT for its keyboard, each written only there.

--locale writes /etc/locale.conf and generates the locale; --keymap writes
/etc/vconsole.conf. Both read their value from the user settings file
($XDG_CONFIG_HOME/vivac/settings, see settings.example) and are
the only writers of those files in this repository.
USAGE
}

while (($#)); do
	case "$1" in
	--dry-run) dry_run=true ;;
	--security) security=true; selection_made=true ;;
	--bluetooth) bluetooth=true; selection_made=true ;;
	--desktop-login) desktop_login=true; selection_made=true ;;
	--greeter) greeter=true; selection_made=true ;;
	--vm) vm_profile=true; selection_made=true ;;
	--locale) locale_axis=true; selection_made=true ;;
	--keymap) keymap_axis=true; selection_made=true ;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		printf 'Unknown option: %s\n' "$1" >&2
		exit 2
		;;
	esac
	shift
done

if ! $selection_made; then
	security=true
	bluetooth=true
fi

install_config() {
	local source=$1 destination=$2
	if $dry_run; then
		printf 'would install %s -> %s\n' "$source" "$destination"
		return
	fi
	if sudo test -e "$destination"; then
		sudo cp -a -- "$destination" "$destination.vivac-backup.$(date -u +%Y%m%dT%H%M%SZ)"
	fi
	sudo install -Dm644 -- "$source" "$destination"
}

# write_axis DESTINATION LINE... — replace DESTINATION with LINE(s), through
# the same backup as every other system file. Shown, not done, in a dry run.
write_axis() {
	local destination="$1" staged
	shift
	if $dry_run; then
		printf 'would write %s: %s\n' "$destination" "$*"
		return
	fi
	staged="$(mktemp)"
	printf '%s\n' "$@" >"$staged"
	install_config "$staged" "$destination"
	rm -f -- "$staged"
}

if $locale_axis || $keymap_axis || $greeter; then
	settings_load "$settings_file"
fi
if $locale_axis; then
	locale="$(settings_get locale)"
	write_axis /etc/locale.conf "LANG=$locale"
	if $dry_run; then
		printf 'would enable %s in /etc/locale.gen and run locale-gen\n' "$locale"
	else
		# Uncomment the line when it exists, append it when it does not; the
		# file is Arch's, so its own format is kept.
		if sudo grep -Eq "^#?[[:space:]]*${locale//./\\.} UTF-8[[:space:]]*$" /etc/locale.gen; then
			sudo sed -i -E "s/^#?[[:space:]]*(${locale//./\\.} UTF-8)[[:space:]]*$/\\1/" /etc/locale.gen
		else
			printf '%s UTF-8\n' "$locale" | sudo tee -a /etc/locale.gen >/dev/null
		fi
		sudo locale-gen >/dev/null
	fi
fi
if $keymap_axis; then
	keymap="$(settings_get keymap)"
	if $dry_run; then
		printf 'would write /etc/vconsole.conf: KEYMAP=%s (other lines kept)\n' "$keymap"
	else
		# vconsole.conf may carry FONT or XKB lines; only KEYMAP is ours.
		kept=()
		if [[ -r /etc/vconsole.conf ]]; then
			mapfile -t kept < <(grep -v '^KEYMAP=' /etc/vconsole.conf || true)
		fi
		write_axis /etc/vconsole.conf "KEYMAP=$keymap" "${kept[@]}"
	fi
fi

services=()
start_services=()
if $bluetooth; then
	install_config "$repo_root/system/etc/bluetooth/main.conf" /etc/bluetooth/main.conf
	services+=(bluetooth.service)
fi
if $security; then
	install_config "$repo_root/system/etc/clamav/freshclam.conf" /etc/clamav/freshclam.conf
	install_config "$repo_root/system/etc/clamav/clamd.conf" /etc/clamav/clamd.conf
	if $dry_run; then
		printf '%s\n' 'would set UFW defaults: deny incoming, allow outgoing, enable'
	else
		sudo ufw default deny incoming
		sudo ufw default allow outgoing
		sudo ufw --force enable
	fi
	services+=(clamav-freshclam.service ufw.service fstrim.timer)
fi
if $greeter; then
	# The greeter's two language axes are rendered from the settings into
	# greetd's config; the VM variant and tuigreet are left exactly as they are.
	RENDER_TOKENS=()
	for key in "${!SETTINGS[@]}"; do
		RENDER_TOKENS["SETTING_${key^^}"]="${SETTINGS["$key"]}"
	done
	rendered_greetd="$(mktemp)"
	render_file "$repo_root/system/etc/greetd/config-gui.toml.in" "$rendered_greetd"
	if $dry_run; then
		printf 'would install /etc/greetd/config.toml with: %s\n' "$(grep '^command' "$rendered_greetd")"
		printf 'would install %s -> /etc/greetd/regreet.toml\n' "$repo_root/system/etc/greetd/regreet.toml"
		printf 'would install %s -> /etc/greetd/regreet.css\n' "$repo_root/system/etc/greetd/regreet.css"
	else
		install_config "$rendered_greetd" /etc/greetd/config.toml
		install_config "$repo_root/system/etc/greetd/regreet.toml" /etc/greetd/regreet.toml
		install_config "$repo_root/system/etc/greetd/regreet.css" /etc/greetd/regreet.css
	fi
	rm -f -- "$rendered_greetd"
	services+=(greetd.service)
elif $desktop_login; then
	greetd_config=config.toml
	# The disposable test VM logs its user straight into the desktop.
	$vm_profile && greetd_config=config-vm.toml
	install_config "$repo_root/system/etc/greetd/$greetd_config" /etc/greetd/config.toml
	services+=(greetd.service)
fi
if $vm_profile; then
	start_services+=(qemu-guest-agent.service)
fi

if $dry_run; then
	((${#services[@]})) && printf 'would enable services: %s\n' "${services[*]}"
	((${#start_services[@]})) && printf 'would start device-activated services: %s\n' "${start_services[*]}"
	$security && printf '%s\n' 'would enable the user ClamAV scan timer'
	exit 0
fi

((${#services[@]})) && sudo systemctl enable --now "${services[@]}"
((${#start_services[@]})) && sudo systemctl start "${start_services[@]}"
if $security; then
	systemctl --user daemon-reload
	systemctl --user enable --now clamav-home-scan.timer
fi
printf '%s\n' 'selected system profiles applied; replaced files were backed up'
