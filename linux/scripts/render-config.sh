#!/usr/bin/env bash
set -Eeuo pipefail

# The one renderer for both kinds of template.
#
# Committed renders (templates/ -> dotfiles/) depend only on the palette and
# are checked into the repository; that path is check-theme-drift.sh and is
# only delegated to here so there is a single command to remember.
#
# Deploy-time renders (render/ -> $XDG_CONFIG_HOME) depend on this machine's
# hardware facts. They are never written into the checkout: a file that
# differs per machine has no business in a repository that is byte-compared
# by its own gates. Existing files are moved to the same timestamped backup
# location deploy.sh uses, so nothing a user wrote is ever deleted.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/kv.sh
source "$repo_root/lib/kv.sh"
# shellcheck source=lib/facts.sh
source "$repo_root/lib/facts.sh"
# shellcheck source=lib/selectors.sh
source "$repo_root/lib/selectors.sh"
# shellcheck source=lib/render.sh
source "$repo_root/lib/render.sh"
# shellcheck source=lib/settings.sh
source "$repo_root/lib/settings.sh"
# shellcheck source=lib/themes.sh
source "$repo_root/lib/themes.sh"

render_dir="${RENDER_DIR:-$repo_root/render}"
facts_file="${FACTS_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/vivac/hardware-facts}"
facts_override="${FACTS_OVERRIDE:-${XDG_CONFIG_HOME:-$HOME/.config}/vivac/hardware-facts.override}"
settings_file="${SETTINGS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/vivac/settings}"
backup_root="${XDG_STATE_HOME:-$HOME/.local/state}/vivac/backups/$(date -u +%Y%m%dT%H%M%SZ)"

usage() {
	cat <<'USAGE'
Usage: scripts/render-config.sh --committed | --deploy | --dry-run | --check-drift

  --committed    render templates/ into dotfiles/ from the palette
  --deploy       render render/ into $XDG_CONFIG_HOME from this machine's facts
  --dry-run      print what --deploy would write, touching nothing
  --check-drift  verify the deployed renders still match a fresh render

Deploy-time output never lands inside the checkout. Existing files move to
${XDG_STATE_HOME:-~/.local/state}/vivac/backups/<stamp>/ first.
Overrides: THEME_FILE, FACTS_FILE, FACTS_OVERRIDE, SETTINGS_FILE, RENDER_DIR, XDG_CONFIG_HOME.
USAGE
}

mode=""
case "${1:-}" in
--committed | --deploy | --dry-run | --check-drift) mode="${1#--}" ;;
-h | --help)
	usage
	exit 0
	;;
'')
	usage >&2
	exit 2
	;;
*)
	printf 'Unknown option: %s\n' "$1" >&2
	usage >&2
	exit 2
	;;
esac
[[ $# -le 1 ]] || {
	printf 'Choose one mode at a time.\n' >&2
	exit 2
}

if [[ "$mode" == committed ]]; then
	exec "$repo_root/scripts/check-theme-drift.sh" --render
fi

# Settings are the chosen values (language axes); they become tokens the same
# way facts do, under their own prefix so a template says which it means.
settings_load "$settings_file"

# The catalogue is resolved after the settings are read, because the chosen
# theme is one of them. THEME_FILE still wins: the gates render an explicit
# file. The default name resolves to data/theme.conf, the palette every
# committed dotfile was rendered from, so choosing nothing changes nothing.
if [[ -n "${THEME_FILE:-}" ]]; then
	theme="$THEME_FILE"
elif [[ "${SETTINGS[theme]}" == bad-romance ]]; then
	theme="$repo_root/data/theme.conf"
else
	# A shipped name, or a palette made from a picture (lib/themes.sh).
	theme="$(SETTINGS_FILE="$settings_file" theme_file_for "$repo_root" "${SETTINGS[theme]}")" || {
		printf 'no theme named %s; the catalogue holds: %s\n' "${SETTINGS[theme]}" \
			"$(SETTINGS_FILE="$settings_file" theme_catalogue "$repo_root" | tr '\n' ' ')" >&2
		exit 1
	}
fi
render_load_tokens "$theme"
[[ -r "$facts_file" || -r "$facts_override" ]] || {
	printf 'no hardware facts at %s; run scripts/hardware-facts.sh --emit first\n' "$facts_file" >&2
	exit 1
}
if [[ -r "$facts_file" ]]; then
	facts_require_schema "$facts_file"
fi
render_load_facts "$facts_file" "$facts_override"
for key in "${!SETTINGS[@]}"; do
	RENDER_TOKENS["SETTING_${key^^}"]="${SETTINGS["$key"]}"
	# ...and as setting_<key> for line guards, next to the facts.
	RENDER_FACTS["setting_$key"]="${SETTINGS["$key"]}"
done

# inside_checkout PATH — 0 when PATH, or the nearest ancestor that exists,
# resolves into the repository. A deployed directory that is itself a symlink
# into the checkout (a folded Stow tree, a hand-made link) would otherwise
# turn a deploy-time render into a silent write to committed files.
inside_checkout() {
	local probe="$1" resolved
	while [[ ! -e "$probe" ]]; do
		probe="$(dirname -- "$probe")"
	done
	resolved="$(readlink -f -- "$probe")"
	[[ "$resolved" == "$repo_root" || "$resolved" == "$repo_root"/* ]]
}

backup_path() {
	local target="$1" relative
	if [[ "$target" == "$HOME"/* ]]; then
		relative="${target#"$HOME"/}"
	else
		relative="${target#/}"
	fi
	printf '%s/%s' "$backup_root" "$relative"
}

scratch="$(mktemp -d "${TMPDIR:-/tmp}/vivac-deploy-render.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT

status=0
count=0
written=0
while IFS= read -r template; do
	relative="${template#"$render_dir"/}"
	target="$(render_deploy_output_path "render/$relative")"
	count=$((count + 1))
	rendered="$scratch/$count"
	render_file "$template" "$rendered" || {
		status=1
		continue
	}

	if inside_checkout "$target"; then
		printf 'refusing to render %s: %s resolves inside the checkout\n' "$relative" "$target" >&2
		status=1
		continue
	fi

	# A render that calls scripts by path is only as good as those scripts.
	# deploy-host never stows the waybar package, so on such a host the bar
	# would call ws-render.sh and friends that are not there and draw a blank
	# workspace strip over the owner's working one. Keep what is there.
	missing=()
	while IFS= read -r called; do
		[[ -e "$HOME/$called" ]] || missing+=("$called")
	done < <(grep -o '\$HOME/[A-Za-z0-9._/-]*' "$rendered" | sed 's|^\$HOME/||' | LC_ALL=C sort -u)
	if ((${#missing[@]})); then
		printf 'skipped %s: it calls %s, which is not deployed (deploy the package that provides it)\n' \
			"$target" "${missing[*]}" >&2
		continue
	fi

	case "$mode" in
	check-drift)
		if [[ ! -f "$target" ]]; then
			printf 'not deployed: %s\n' "$target" >&2
			status=1
		elif ! cmp -s "$rendered" "$target"; then
			printf 'deploy drift: %s differs from a fresh render\n' "$target" >&2
			diff -u --label 'rendered' "$rendered" --label 'deployed' "$target" | head -n 20 >&2 || true
			status=1
		fi
		;;
	dry-run | deploy)
		if [[ -f "$target" && ! -L "$target" ]] && cmp -s "$rendered" "$target"; then
			printf 'unchanged %s\n' "$target"
			continue
		fi
		if [[ -e "$target" || -L "$target" ]]; then
			destination="$(backup_path "$target")"
			if [[ "$mode" == dry-run ]]; then
				printf 'would back up %s -> %s\n' "$target" "$destination"
			else
				mkdir -p -- "$(dirname -- "$destination")"
				mv -- "$target" "$destination"
				printf 'backed up %s -> %s\n' "$target" "$destination"
			fi
		fi
		if [[ "$mode" == dry-run ]]; then
			printf 'would write %s\n' "$target"
		else
			mkdir -p -- "$(dirname -- "$target")"
			mv -- "$rendered" "$target"
			printf 'rendered %s\n' "$target"
			written=$((written + 1))
		fi
		;;
	esac
done < <(find "$render_dir" -type f -name '*.in' | LC_ALL=C sort)

((count > 0)) || {
	printf 'no templates found under %s\n' "$render_dir" >&2
	exit 1
}
((status == 0)) || exit 1

case "$mode" in
check-drift) printf 'deploy: %d rendered files match their templates\n' "$count" ;;
dry-run) printf 'deploy: would render %d files\n' "$count" ;;
deploy)
	printf 'deploy: %d files rendered, %d written\n' "$count" "$written"
	if [[ -d "$backup_root" ]]; then printf 'backup: %s\n' "$backup_root"; fi
	;;
esac
