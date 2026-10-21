#!/usr/bin/env bash
set -Eeuo pipefail

# Runs INSIDE the build guest, fed over `bash -s` by scripts/build-vm-image.sh,
# after the guest has passed tests/guest-acceptance.sh. It turns a provisioned
# test guest into something a stranger can safely boot.
#
# IMAGE_LOCALE, IMAGE_KEYMAP, IMAGE_LAYOUT and IMAGE_USER are exported by the
# caller.

cd "$HOME/vivac"

# The acceptance seeds three deliberately different axis values (es/es/fr) so
# each writer can be told apart. A published image carries defaults instead.
printf 'locale=%s\nkeymap=%s\nxkb_layout=%s\nime=fcitx5\n' \
	"$IMAGE_LOCALE" "$IMAGE_KEYMAP" "$IMAGE_LAYOUT" \
	>"$HOME/.config/vivac/settings"
./scripts/apply-system.sh --locale --keymap
./scripts/render-config.sh --deploy >/dev/null
grep -Fxq "LANG=$IMAGE_LOCALE" /etc/locale.conf
grep -Fxq "KEYMAP=$IMAGE_KEYMAP" /etc/vconsole.conf
grep -Fq "kb_layout = \"$IMAGE_LAYOUT\"" "$HOME/.config/hypr/generated/input.lua"

# The test guest logs straight in with no greeter, which is right for a gate
# and wrong for a published image: whoever downloads this should meet the
# graphical login, in the palette, and land in Hyprland without typing its
# name. ReGreet's default session is already Hyprland, so installing it for
# real is the whole change.
sudo ./scripts/apply-system.sh --greeter
grep -Fq 'cage -s -- regreet' /etc/greetd/config.toml

# Draw every wallpaper in the catalogue now, while there is a rasterizer and
# time to spare. The wallpaper is the only themed file that is rendered at
# RUN time rather than committed, so without this the first preview of each
# theme stops to rasterize a 4K image and the desktop sits bare while it does
# — during the one minute the wizard is asking someone to judge the theme by
# looking at it.
# The catalogue only: the default's PNG is committed, and Stow has put a
# symlink to it at exactly this path. Redrawing it would replace that link with
# a regular file and leave Stow's bookkeeping wrong for a file that was already
# correct.
catalogue=()
while IFS= read -r conf; do catalogue+=(--theme "$(basename -- "$conf" .conf)"); done \
	< <(find data/themes -type f -name '*.conf' | LC_ALL=C sort)
./scripts/make-wallpaper.sh "${catalogue[@]}" --out "$HOME/.local/share/wallpapers"
drawn="$(find "$HOME/.local/share/wallpapers" -type f -name '*.png' | wc -l)"
wanted="$((${#catalogue[@]} / 2))"
((drawn >= wanted)) || {
	printf 'only %s of %s catalogue wallpapers were drawn; themes would fall back to the default\n' \
		"$drawn" "$wanted" >&2
	exit 1
}

# Nothing that identifies the build host or the build run may survive.
sudo pacman -Scc --noconfirm >/dev/null
sudo journalctl --rotate >/dev/null 2>&1 || true
sudo journalctl --vacuum-time=1s >/dev/null 2>&1 || true
sudo rm -rf -- /var/log/journal/* /var/tmp/* /tmp/vivac-runtime
rm -f -- "$HOME/.bash_history"
# systemd writes a fresh id at boot when the file exists and is empty.
sudo truncate -s 0 /etc/machine-id
# Host keys regenerate at first boot: Arch's sshd.service wants
# sshdgenkeys.service, which is conditioned on exactly these paths missing.
# Without this every downloaded copy of the image would share one identity.
sudo rm -f -- /etc/ssh/ssh_host_*

# cloud-init provisioned this guest from a seed ISO the artifact will not have;
# left enabled it stalls every boot waiting for a datasource that never comes.
sudo touch /etc/cloud/cloud-init.disabled
sudo rm -rf -- /var/lib/cloud/*

sudo fstrim -av >/dev/null 2>&1 || true

# One root transaction, because the first step below destroys the means to run
# the next one over SSH: dropping cloud-init's NOPASSWD rule makes sudo ask for
# a password this session has no terminal to type. So the shutdown is scheduled
# from inside and the bridges are burned in order.
#
# The credentials are a published convention rather than something to keep.
# Both accounts use their own name as the password, and root uses the usual
# reversal of it — the README prints both — so a stranger who downloads the
# image can log in without hunting for them. That is only defensible because the image
# does not listen on the network — sshd is installed and disabled, and turning
# it on is a deliberate act by whoever owns the copy. An image that shipped
# with a known root password AND an open port would be a liability, not a demo.
sudo bash -euc "
	# Deferred so this SSH session closes cleanly and the caller can read the
	# marker below; powering off inline would drop the connection mid-stream.
	systemd-run --on-active=20 --unit=seal-poweroff systemctl poweroff >/dev/null
	printf '$IMAGE_USER:$IMAGE_USER\n' | chpasswd
	printf 'root:toor\n' | chpasswd
	rm -f -- /etc/sudoers.d/90-cloud-init-users
	printf '%%wheel ALL=(ALL:ALL) ALL\n' >/etc/sudoers.d/10-wheel
	chmod 0440 /etc/sudoers.d/10-wheel
	visudo -c -q
	# Installed, reachable, off. The console stays available so the image can
	# be driven headlessly without a network at all.
	systemctl disable sshd.service >/dev/null
	systemctl enable serial-getty@ttyS0.service >/dev/null
"
# The build key is the last thing to go, and it needs no privileges.
shred -u -- "$HOME/.ssh/authorized_keys" 2>/dev/null || rm -f -- "$HOME/.ssh/authorized_keys"

printf '%s\n' 'IMAGE_SEAL: DONE'
