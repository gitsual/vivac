#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
packages=(hypr waybar kitty dunst rofi wofi nvim shell theme audio security automation ricer welcome)
dry_run=false
protected=()
reapply_theme=true

usage() {
	cat <<'USAGE'
Usage: scripts/deploy.sh [--all] [--dry-run] [--protect REL]... [--no-theme] [package ...]

Packages: hypr waybar kitty dunst rofi wofi nvim shell theme audio security automation
Existing files are moved to a timestamped backup; nothing is deleted.

  --protect REL  leave $HOME/REL alone: not backed up, not linked (repeatable)
  --no-theme     do not reapply the chosen palette afterwards
DEPLOY_BACKUP_ROOT names the backup directory (default: a new stamp under the state home).
USAGE
}

selected=()
while (($#)); do
	case "$1" in
	--all) selected=("${packages[@]}") ;;
	--dry-run) dry_run=true ;;
	--no-theme) reapply_theme=false ;;
	--protect)
		[[ -n "${2:-}" && "$2" != /* ]] || {
			printf '%s\n' '--protect needs a path relative to the home directory' >&2
			exit 2
		}
		protected+=("$2")
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	--*)
		printf 'Unknown option: %s\n' "$1" >&2
		usage >&2
		exit 2
		;;
	*) selected+=("$1") ;;
	esac
	shift
done
((${#selected[@]})) || selected=("${packages[@]}")

command -v stow >/dev/null || {
	printf 'GNU Stow is required. Run scripts/bootstrap.sh first.\n' >&2
	exit 1
}

for package in "${selected[@]}"; do
	[[ " ${packages[*]} " == *" $package "* ]] || {
		printf 'Unknown package: %s\n' "$package" >&2
		exit 2
	}
done

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_root="${DEPLOY_BACKUP_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/vivac/backups/$stamp}"

is_protected() {
	local path
	for path in "${protected[@]}"; do
		[[ "$path" == "$1" ]] && return 0
	done
	return 1
}

# Nothing is moved until the backup directory can take the files.
backup_root_ready=false
ensure_backup_root() {
	$backup_root_ready && return 0
	{ mkdir -p -- "$backup_root" && [[ -w "$backup_root" ]]; } || {
		printf 'deploy: the backup directory %s is not writable; nothing was replaced\n' "$backup_root" >&2
		exit 1
	}
	backup_root_ready=true
}

for package in "${selected[@]}"; do
	package_root="$repo_root/dotfiles/$package"
	while IFS= read -r -d '' source; do
		relative="${source#"$package_root"/}"
		target="$HOME/$relative"
		if is_protected "$relative"; then
			if [[ -e "$target" || -L "$target" ]]; then
				if $dry_run; then verb='would skip (protected)'; else verb='skipped (protected)'; fi
				printf '%s %s\n' "$verb" "$target"
			fi
			continue
		fi
		# Stow may link an entire parent directory. Compare canonical file
		# paths even when the final component is not itself a symlink; this
		# prevents a second run from moving files out of the repository.
		if [[ -e "$target" && "$(readlink -f -- "$target")" == "$(readlink -f -- "$source")" ]]; then
			continue
		fi
		if [[ -e "$target" || -L "$target" ]]; then
			destination="$backup_root/$relative"
			if $dry_run; then
				printf 'would back up %s -> %s\n' "$target" "$destination"
			else
				ensure_backup_root
				mkdir -p -- "$(dirname -- "$destination")"
				mv -- "$target" "$destination"
				printf 'backed up %s -> %s\n' "$target" "$destination"
			fi
		fi
	done < <(find "$package_root" -type f -print0)

done

if $dry_run; then
	printf 'would stow: %s\n' "${selected[*]}"
	exit 0
fi

ignores=()
for path in "${protected[@]}"; do
	# shellcheck disable=SC2001  # one class of characters, escaped for a regex
	ignores+=("--ignore=^$(sed 's/[][\\.*^$+?(){}|]/\\&/g' <<<"$path")\$")
done
stow --dir="$repo_root/dotfiles" --target="$HOME" --no-folding "${ignores[@]}" --restow "${selected[@]}"
printf 'deployed: %s\n' "${selected[*]}"

# Restowing points every themed file back at the committed default render, and
# a non-default theme lives as an overlay written OVER those symlinks. Deploying
# therefore undressed the desktop: the settings file still said cosmos
# and the terminal came back bad-romance, which is the one mismatch nobody looks
# for because the setting is right. Put the chosen palette back on.
# Read with pipefail in force: sed exits non-zero when the settings file does
# not exist yet, which is the ordinary case on a first deploy, and a pipeline
# that fails there would take the whole deploy with it.
settings_file="${XDG_CONFIG_HOME:-$HOME/.config}/vivac/settings"
theme=''
if [[ -r "$settings_file" ]]; then
	theme="$(sed -nE 's/^theme=(.*)$/\1/p' "$settings_file" | tail -1)"
fi
if $reapply_theme && [[ -n "$theme" && "$theme" != bad-romance ]]; then
	if "$repo_root/scripts/apply-theme.sh" --theme "$theme" >/dev/null; then
		printf 'theme reapplied: %s\n' "$theme"
	else
		printf 'deploy: the desktop is deployed but %s could not be reapplied\n' "$theme" >&2
	fi
fi
if [[ -d "$backup_root" ]]; then
	printf 'backup: %s\n' "$backup_root"
fi
