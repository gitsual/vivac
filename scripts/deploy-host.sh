#!/usr/bin/env bash
set -Eeuo pipefail

# Adopt the Lua desktop on a machine that already has a configuration of its own,
# without losing any of it.
#
#   scripts/deploy-host.sh [--dry-run] [--all]   verify, back up, deploy, recolour
#   scripts/deploy-host.sh --rollback [BACKUP]   put the pre-deploy state back
#
# Order: preflight -> stage the render in a scratch HOME -> Hyprland --verify-config
# on the staged config (the host's local.lua included) -> only then touch the host:
# back up what is replaced, deploy with the protect list, recolour the owner's own
# files. A failed or missing verifier changes nothing. Docs: docs/host-deploy.md.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
hyprland="${HYPRLAND_BIN:-Hyprland}"
config="$HOME/.config"
state="${XDG_STATE_HOME:-$HOME/.local/state}"
# waybar, kitty, dunst, rofi and wofi are never packages here, not even with
# --all: they are the owner's own layouts and only get the palette (colour overlay).
packages=(hypr nvim ricer welcome)
dry_run=false rollback=false backup_arg=''

die() {
	printf 'deploy-host: %s\n' "$*" >&2
	exit 1
}

while (($#)); do
	case "$1" in
	--dry-run) dry_run=true ;;
	--all) packages=(hypr nvim shell theme audio security automation ricer welcome) ;;
	--rollback)
		rollback=true
		backup_arg="${2:-}"
		[[ $# -lt 2 ]] || shift
		;;
	-h | --help)
		sed -n '4,9p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
		exit 0
		;;
	*) die "unknown option: $1" ;;
	esac
	shift
done

# --- rollback: backed-up files come back, created files and directories go ------------------------------
if $rollback; then
	root="$backup_arg"
	[[ -n "$root" ]] || root="$(find "$state/vivac/backups" -mindepth 2 -maxdepth 2 -name MANIFEST 2>/dev/null | LC_ALL=C sort | tail -n 1 | xargs -r dirname)"
	[[ -f "$root/MANIFEST" ]] || die "no deploy-host backup to roll back (looked for ${root:-the newest} MANIFEST)"
	while IFS=$'\t' read -r kind value; do
		case "$kind" in
		created) rm -f -- "$HOME/$value" ;;
		newtree) rm -rf -- "$value" ;;
		esac
	done <"$root/MANIFEST"
	while IFS= read -r -d '' saved; do
		relative="${saved#"$root"/}"
		[[ "$relative" != MANIFEST ]] || continue
		mkdir -p -- "$(dirname -- "$HOME/$relative")"
		rm -f -- "$HOME/$relative"
		cp -a -- "$saved" "$HOME/$relative"
	done < <(find "$root" \( -type f -o -type l \) -print0)
	awk -F'\t' '$1=="newdir"{print $2}' "$root/MANIFEST" | LC_ALL=C sort -r | while IFS= read -r dir; do
		rmdir -- "$HOME/$dir" 2>/dev/null || true
	done
	printf 'rolled back to the state before %s\n' "$root"
	exit 0
fi

# --- preflight ------------------------------------------------------------------------------------------------------
command -v stow >/dev/null || die 'GNU Stow is required'
[[ "$repo_root" != *[[:space:]]* ]] || die "the checkout path has whitespace; the session autostart cannot use it: $repo_root"
command -v "$hyprland" >/dev/null || die "$hyprland is not installed, so the staged config cannot be verified; refusing to replace the live compositor config"
facts="$state/vivac/hardware-facts" override="$config/vivac/hardware-facts.override" settings="$config/vivac/settings"
[[ -r "$facts" || -r "$override" ]] || die 'no hardware facts; run scripts/hardware-facts.sh --emit first'
live="$config/hypr/hyprland.lua"
if [[ ( -e "$live" || -L "$live" ) && "$(readlink -f -- "$live")" != "$repo_root/dotfiles/hypr/.config/hypr/hyprland.lua" && ! -e "$config/hypr/local.lua" ]]; then
	die "$live is your own file and there is no $config/hypr/local.lua to carry its keys; it would be backed up and replaced. Write local.lua first (docs/local-overlay.md, import checklist), then run again"
fi

# --- stage and verify ---------------------------------------------------------------------------------------
stage="$(mktemp -d "${TMPDIR:-/tmp}/vivac-deploy-host.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
staged="$stage/home"
mkdir -p -- "$staged/.config/hypr" "$staged/.config/vivac" "$stage/run"
chmod 700 "$stage/run"
HOME="$staged" XDG_CONFIG_HOME="$staged/.config" XDG_STATE_HOME="$staged/.state" \
	FACTS_FILE="$facts" FACTS_OVERRIDE="$override" SETTINGS_FILE="$settings" \
	"$repo_root/scripts/render-config.sh" --deploy >/dev/null || die 'the render failed; nothing was changed'
cp -- "$repo_root/dotfiles/hypr/.config/hypr/hyprland.lua" "$staged/.config/hypr/hyprland.lua"
printf '%s\n' "$repo_root" >"$staged/.config/vivac/repo"
if [[ -e "$config/hypr/local.lua" ]]; then cp -L -- "$config/hypr/local.lua" "$staged/.config/hypr/local.lua"; fi
if ! output="$(HOME="$staged" XDG_CONFIG_HOME="$staged/.config" XDG_RUNTIME_DIR="$stage/run" \
	"$hyprland" --verify-config -c "$staged/.config/hypr/hyprland.lua" 2>&1)"; then
	printf '%s\n' "$output" >&2
	die 'Hyprland refused the staged config (see above); nothing was changed'
fi

# --- the plan -------------------------------------------------------------------------------------------------------
protect=(.bashrc .config/hypr/scripts/screenshot.sh .config/hypr/hyprpaper.conf)
while IFS= read -r file; do protect+=("$file"); done < <(cd "$repo_root/dotfiles/waybar" && find .config -type f | sed 's|^\./||')
protect_args=()
for path in "${protect[@]}"; do
	protect_args+=(--protect "$path")
	if [[ -e "$HOME/$path" || -L "$HOME/$path" ]]; then
		if $dry_run; then verb='would skip-protect'; else verb='skip-protect'; fi
		printf '%s %s\n' "$verb" "$HOME/$path"
	fi
done
overlay=()
while read -r _ pattern _; do
	while IFS= read -r file; do
		if [[ -f "$file" && ! -L "$file" ]]; then overlay+=("${file#"$HOME"/}"); fi
	done < <(compgen -G "$config/$pattern" || true)
done <"$repo_root/data/colour-overlay.tsv"
theme="$(sed -nE 's/^theme=(.*)$/\1/p' "$settings" 2>/dev/null | tail -n 1 || true)"
theme="${theme:-bad-romance}"
orphans=()
for name in hardware input monitors; do
	[[ ! -e "$config/hypr/generated/$name.conf" ]] || orphans+=(".config/hypr/generated/$name.conf")
done

if $dry_run; then
	for file in "$staged"/.config/hypr/generated/*.lua; do
		target="$config/hypr/generated/$(basename -- "$file")"
		if [[ ! -e "$target" ]]; then printf 'would write %s\n' "$target"; elif ! cmp -s "$file" "$target"; then printf 'would back up and write %s\n' "$target"; fi
	done
	for path in "${orphans[@]}"; do printf 'would back up and remove %s\n' "$HOME/$path"; done
	printf 'would write %s (the checkout: %s)\n' "$config/vivac/repo" "$repo_root"
	"$repo_root/scripts/deploy.sh" --dry-run --no-theme "${protect_args[@]}" "${packages[@]}"
	for path in "${overlay[@]}"; do printf 'would recolour %s (%s)\n' "$HOME/$path" "$theme"; done
	printf 'dry run: the staged config verified; nothing was changed\n'
	exit 0
fi

# --- go live: every step below is undone by --rollback -------------------------------------------------------------
backup_root="$state/vivac/backups/$(date -u +%Y%m%dT%H%M%SZ)"
{ mkdir -p -- "$backup_root" && [[ -w "$backup_root" ]]; } || die "the backup directory $backup_root is not writable; nothing was changed"
absent=() newdirs=()
track() {
	local relative="$1" dir
	if [[ ! -e "$HOME/$relative" && ! -L "$HOME/$relative" ]]; then absent+=("$relative"); fi
	dir="$(dirname -- "$relative")"
	while [[ "$dir" != . ]]; do
		[[ -d "$HOME/$dir" ]] || newdirs+=("$dir")
		dir="$(dirname -- "$dir")"
	done
}
for file in "$staged"/.config/hypr/generated/*.lua; do track ".config/hypr/generated/$(basename -- "$file")"; done
track .config/vivac/repo
for package in "${packages[@]}"; do
	while IFS= read -r file; do track "$file"; done < <(cd "$repo_root/dotfiles/$package" && find . -type f | sed 's|^\./||')
done
colour_state_new=false
[[ -d "$state/vivac/colour-overlay" ]] || colour_state_new=true

finish() {
	local status=$? path
	{
		for path in "${absent[@]}"; do
			[[ ! -e "$HOME/$path" && ! -L "$HOME/$path" ]] || printf 'created\t%s\n' "$path"
		done
		for path in "${newdirs[@]}"; do [[ ! -d "$HOME/$path" ]] || printf 'newdir\t%s\n' "$path"; done
		if $colour_state_new && [[ -d "$state/vivac/colour-overlay" ]]; then printf 'newtree\t%s\n' "$state/vivac/colour-overlay"; fi
	} >"$backup_root/MANIFEST"
	printf 'backup: %s\n' "$backup_root"
	printf 'rollback: %s --rollback %s\n' "$repo_root/scripts/deploy-host.sh" "$backup_root"
	rm -rf -- "$stage"
	exit "$status"
}
trap finish EXIT

save() { # save RELATIVE — copy a host file into the backup, keeping mode and links
	mkdir -p -- "$(dirname -- "$backup_root/$1")"
	cp -a -- "$HOME/$1" "$backup_root/$1"
}
for path in "${orphans[@]}"; do
	save "$path"
	rm -f -- "$HOME/$path"
	printf 'removed the orphaned hyprlang fragment %s\n' "$HOME/$path"
done
mkdir -p -- "$config/hypr/generated" "$config/vivac"
for file in "$staged"/.config/hypr/generated/*.lua; do
	target="$config/hypr/generated/$(basename -- "$file")"
	if [[ -e "$target" || -L "$target" ]]; then
		cmp -s "$file" "$target" && continue
		save "${target#"$HOME"/}"
	fi
	cp --remove-destination -- "$file" "$target"
	printf 'rendered %s\n' "$target"
done
[[ "$(cat "$config/vivac/repo" 2>/dev/null)" == "$repo_root" ]] || {
	if [[ -e "$config/vivac/repo" ]]; then save .config/vivac/repo; fi
	printf '%s\n' "$repo_root" >"$config/vivac/repo"
}

DEPLOY_BACKUP_ROOT="$backup_root" "$repo_root/scripts/deploy.sh" --no-theme "${protect_args[@]}" "${packages[@]}"

for path in "${overlay[@]}"; do [[ -e "$backup_root/$path" ]] || save "$path"; done
"$repo_root/scripts/colour-overlay.sh" --apply "$theme" --config-dir "$config" || printf 'deploy-host: the colour overlay failed; the desktop is deployed\n' >&2
