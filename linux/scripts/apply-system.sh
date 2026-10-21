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
bridge=false
selection_made=false

usage() {
	cat <<'USAGE'
Usage: scripts/apply-system.sh [--dry-run] [--security] [--bluetooth] [--desktop-login] [--vm]
                               [--greeter] [--locale] [--keymap] [--bridge]

With no module selector, the backward-compatible security and Bluetooth profiles
are applied. Selectors compose without enabling unrelated services.

--greeter installs the graphical login (ReGreet in cage) in place of tuigreet,
rendered from the settings file: LANG for the greeter process and
XKB_DEFAULT_LAYOUT for its keyboard, each written only there.

--locale writes /etc/locale.conf and generates the locale; --keymap writes
/etc/vconsole.conf. Both read their value from the user settings file
($XDG_CONFIG_HOME/vivac/settings, see settings.example) and are
the only writers of those files in this repository.

--bridge is the system half of the bridge with Windows (docs/bridge.md at the
root of the product): the sudoers rule that lets wheel set the firmware's
BootNext for "Restart in Windows", UFW rules that open the vivac link port
(TCP and UDP 47321) and the LocalSend port of the phone drop (TCP and UDP
53317) to the local IPv4 subnets only, and the user's vivac-link service,
which stays idle until the machine is paired. The phone drop's service is not
enabled here: vivac-localsend on (or the bridge menu) turns it on, with a PIN.
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
	--bridge) bridge=true; selection_made=true ;;
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

# local_subnets — the IPv4 networks this machine is on now, as network address
# and prefix (a.b.c.0/24), from `ip`. The link port is opened to these and
# to nothing wider; a network joined later needs --bridge again.
local_subnets() {
	local address prefix a b c d mask network
	while read -r address; do
		[[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || continue
		prefix="${address#*/}" address="${address%/*}"
		((prefix > 0 && prefix <= 32)) || continue
		IFS=. read -r a b c d <<<"$address"
		mask=$(((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF))
		network=$((((a << 24) | (b << 16) | (c << 8) | d) & mask))
		printf '%d.%d.%d.%d/%d\n' $((network >> 24 & 255)) $((network >> 16 & 255)) $((network >> 8 & 255)) $((network & 255)) "$prefix"
	done < <(ip -o -4 addr show scope global 2>/dev/null | awk '{ print $4 }') | LC_ALL=C sort -u
}

if $bridge; then
	# The rule is parsed by visudo before it goes in: a broken file in
	# sudoers.d makes sudo refuse every command, not only this one. A backup
	# named vivac-bootnext.vivac-backup.* has a dot in it, which sudo's
	# includedir skips, so it is never read as a second rule.
	sudoers_source="$repo_root/system/etc/sudoers.d/vivac-bootnext"
	if $dry_run; then
		printf 'would install %s -> /etc/sudoers.d/vivac-bootnext (mode 0440, checked by visudo -cf first)\n' "$sudoers_source"
	else
		sudo visudo -cf "$sudoers_source" >/dev/null
		if sudo test -e /etc/sudoers.d/vivac-bootnext; then
			sudo cp -a -- /etc/sudoers.d/vivac-bootnext "/etc/sudoers.d/vivac-bootnext.vivac-backup.$(date -u +%Y%m%dT%H%M%SZ)"
		fi
		sudo install -Dm440 -o root -g root -- "$sudoers_source" /etc/sudoers.d/vivac-bootnext
	fi
	mapfile -t subnets < <(local_subnets)
	((${#subnets[@]})) || printf '%s\n' 'no IPv4 network is up: the vivac link and phone drop ports stay closed; run --bridge again once connected'
	# 47321 is vivac link; 53317 is LocalSend's, for the phone drop: HTTP on
	# TCP, discovery on UDP (multicast to 224.0.0.167 from the same subnet).
	for subnet in "${subnets[@]}"; do
		for opening in '47321 vivac link' '53317 vivac phone drop'; do
			for protocol in tcp udp; do
				if $dry_run; then
					printf 'would allow %s %s from %s in UFW (%s)\n' "$protocol" "${opening%% *}" "$subnet" "${opening#* }"
				else
					sudo ufw allow proto "$protocol" from "$subnet" to any port "${opening%% *}" comment "${opening#* }"
				fi
			done
		done
	done
fi

if $dry_run; then
	((${#services[@]})) && printf 'would enable services: %s\n' "${services[*]}"
	((${#start_services[@]})) && printf 'would start device-activated services: %s\n' "${start_services[*]}"
	$security && printf '%s\n' 'would enable the user ClamAV scan timer'
	$bridge && printf '%s\n' 'would enable the user vivac-link service'
	exit 0
fi

((${#services[@]})) && sudo systemctl enable --now "${services[@]}"
((${#start_services[@]})) && sudo systemctl start "${start_services[@]}"
if $security; then
	systemctl --user daemon-reload
	systemctl --user enable --now clamav-home-scan.timer
fi
# Enabled at once; it only starts once link.conf exists (vivac-link pair).
if $bridge; then
	systemctl --user daemon-reload
	systemctl --user enable --now vivac-link.service
fi
printf '%s\n' 'selected system profiles applied; replaced files were backed up'
