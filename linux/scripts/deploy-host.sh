#!/usr/bin/env bash
set -Eeuo pipefail

# Adopt the Lua desktop on a machine that already has a configuration of its own,
# without losing any of it.
#
#   scripts/deploy-host.sh [--dry-run] [--all] [--without PKG]...   verify, back up, deploy, recolour
#   scripts/deploy-host.sh --rollback [BACKUP] [--force]   put the pre-deploy state back
#
# Order: preflight -> stage the render in a scratch HOME -> Hyprland --verify-config
# on the staged config (the host's local.lua included) -> only then touch the host:
# back up what is replaced, deploy with the protect list, recolour the owner's own
# files. A failed or missing verifier changes nothing. Docs: docs/host-deploy.md.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/kv.sh
source "$repo_root/lib/kv.sh"
# shellcheck source=lib/settings.sh
source "$repo_root/lib/settings.sh"
hyprland="${HYPRLAND_BIN:-Hyprland}"
config="$HOME/.config"
state="${XDG_STATE_HOME:-$HOME/.local/state}"
# waybar, kitty, dunst, rofi and wofi are never packages here, not even with
# --all: they are the owner's own layouts and only get the palette (colour overlay).
packages=(hypr nvim ricer welcome bridge)
dry_run=false rollback=false force=false backup_arg=''
default_packages=("${packages[@]}")
without=()

die() {
	printf 'deploy-host: %s\n' "$*" >&2
	exit 1
}

while (($#)); do
	case "$1" in
	--dry-run) dry_run=true ;;
	--all) packages=(hypr nvim shell theme audio security automation ricer welcome bridge) ;;
	--without)
		(($# >= 2)) || {
			printf 'deploy-host: --without needs a package name\n' >&2
			exit 2
		}
		case " ${default_packages[*]} " in
		*" $2 "*) ;;
		*)
			printf 'deploy-host: --without: unknown package %s (one of: %s)\n' "$2" "${default_packages[*]}" >&2
			exit 2
			;;
		esac
		[[ "$2" != hypr ]] || die '--without hypr is refused: the Hyprland config is the point of this deploy'
		without+=("$2")
		shift
		;;
	--rollback) rollback=true ;;
	--force) force=true ;;
	-h | --help)
		sed -n '4,9p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
		exit 0
		;;
	-*) die "unknown option: $1" ;;
	*) backup_arg="$1" ;;
	esac
	shift
done
$rollback || [[ -z "$backup_arg" ]] || die "unexpected argument: $backup_arg"
# Excluded packages are neither stowed nor backed up; the summary says so.
if ((${#without[@]})); then
	kept=()
	for package in "${packages[@]}"; do
		skip=false
		for excluded in "${without[@]}"; do [[ "$package" != "$excluded" ]] || skip=true; done
		$skip || kept+=("$package")
	done
	packages=("${kept[@]}")
fi
skipped_note() {
	local excluded
	for excluded in "${without[@]}"; do printf 'skipped: %s (--without)\n' "$excluded"; done
}

# --- rollback: backed-up files come back, created files and directories go ------------------------------
# The MANIFEST is read as untrusted input: every line is checked before anything is removed.
backup_has_content() { # a backup counts when the MANIFEST lists something or a file was saved
	[[ -f "$1/MANIFEST" && ! -e "$1/ROLLED-BACK" ]] || return 1
	[[ -s "$1/MANIFEST" ]] || [[ -n "$(find "$1" -mindepth 1 ! -name MANIFEST ! -name ROLLED-BACK -print -quit)" ]]
}
# rollback_root ROOT: put back what ROOT/MANIFEST says this run changed. Returns 1, having
# changed nothing, when the MANIFEST does not belong to this host.
rollback_root() {
	local root="$1" overlay_state="$state/vivac/colour-overlay" bad='' kind value saved relative dir
	while IFS=$'\t' read -r kind value; do
		[[ -n "$kind" ]] || continue
		case "$kind" in
		created | newdir) [[ -n "$value" && "$value" != /* && ! "$value" =~ (^|/)\.\.(/|$) ]] || bad+="$kind $value; " ;;
		newtree) [[ "$value" == "$overlay_state" ]] || bad+="$kind $value; " ;;
		overlaystate) [[ -n "$value" && "$value" != */* && "$value" != . && "$value" != .. ]] || bad+="$kind $value; " ;;
		*) bad+="$kind $value; " ;;
		esac
	done <"$root/MANIFEST"
	if [[ -n "$bad" ]]; then
		printf 'deploy-host: refusing to roll back: the MANIFEST has lines that do not belong to this host (%s); nothing was changed\n' "${bad%; }" >&2
		return 1
	fi
	while IFS=$'\t' read -r kind value; do
		case "$kind" in
		created) rm -f -- "$HOME/$value" || return 1 ;;
		newtree) rm -rf -- "$value" || return 1 ;;
		overlaystate)
			rm -rf -- "${overlay_state:?}/$value" || return 1
			if [[ -e "$root/.overlay-state/$value" ]]; then
				mkdir -p -- "$overlay_state" && cp -a -- "$root/.overlay-state/$value" "$overlay_state/$value" || return 1
			fi
			;;
		esac
	done <"$root/MANIFEST"
	while IFS= read -r -d '' saved; do
		relative="${saved#"$root"/}"
		case "$relative" in MANIFEST | ROLLED-BACK | .overlay-state/*) continue ;; esac
		{ mkdir -p -- "$(dirname -- "$HOME/$relative")" && rm -f -- "$HOME/$relative" && cp -a -- "$saved" "$HOME/$relative"; } || return 1
	done < <(find "$root" \( -type f -o -type l \) -print0)
	awk -F'\t' '$1=="newdir"{print $2}' "$root/MANIFEST" | LC_ALL=C sort -r | while IFS= read -r dir; do
		rmdir -- "$HOME/$dir" 2>/dev/null || true
	done
	: >"$root/ROLLED-BACK"
}
if $rollback; then
	backups="$state/vivac/backups"
	root="$backup_arg"
	if [[ -z "$root" ]]; then
		while IFS= read -r candidate; do
			if backup_has_content "$candidate"; then
				root="$candidate"
				break
			fi
		done < <(find "$backups" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort -r)
		[[ -n "$root" ]] || die "no deploy-host backup with anything to roll back under $backups"
		printf 'using the newest backup with something to undo: %s\n' "$root"
	fi
	[[ -f "$root/MANIFEST" ]] || die "no deploy-host backup to roll back (looked for $root/MANIFEST)"
	root="$(cd -- "$root" && pwd -P)"
	if ! $force; then
		real_backups="$(cd -- "$backups" 2>/dev/null && pwd -P || true)"
		[[ -n "$real_backups" && "$(dirname -- "$root")" == "$real_backups" ]] ||
			die "refusing to roll back $root: it is not under $backups (--force to use it anyway)"
	fi
	rollback_root "$root" || exit 1
	printf 'rolled back to the state before %s\n' "$root"
	exit 0
fi

# --- preflight ------------------------------------------------------------------------------------------------------
command -v stow >/dev/null || die 'GNU Stow is required'
[[ "$repo_root" != *[[:space:]]* ]] || die "the checkout path has whitespace; the session autostart cannot use it: $repo_root"
command -v "$hyprland" >/dev/null || die "$hyprland is not installed, so the staged config cannot be verified; refusing to replace the live compositor config"
# bootstrap.sh installs packages/pacman.txt; a host adopting the desktop never ran it.
# Without socat the workspace strip freezes after its first snapshot, without swaybg
# the wallpaper never follows the theme -- and neither says so on screen.
mapfile -t missing < <(grep -Ev '^[[:space:]]*(#|$)' "$repo_root/packages/pacman.txt" | xargs "${PACMAN_BIN:-pacman}" -T 2>/dev/null || true)
((${#missing[@]} == 0)) || die "packages the desktop runs on are not installed; run: sudo pacman -S --needed ${missing[*]}"
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
# The settings go through the repository's own reader (shape-checked, CR dropped),
# so a theme name can never be a path and a CRLF file means what it says.
if [[ -r "$settings" ]]; then LC_ALL=C tr -d '\r' <"$settings" >"$stage/settings"; fi
settings_load "$stage/settings" || die 'the settings file is not valid (see above); nothing was changed'
theme="$(settings_get theme)"
[[ "$theme" == bad-romance || -f "$repo_root/data/themes/$theme.conf" ]] || die "the theme '$theme' is not in the catalogue; nothing was changed"
mkdir -p -- "$staged/.config/hypr" "$staged/.config/vivac" "$stage/run"
chmod 700 "$stage/run"
HOME="$staged" XDG_CONFIG_HOME="$staged/.config" XDG_STATE_HOME="$staged/.state" \
	FACTS_FILE="$facts" FACTS_OVERRIDE="$override" SETTINGS_FILE="$stage/settings" \
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
	"$repo_root/scripts/deploy.sh" --dry-run --no-theme "${protect_args[@]}" "${packages[@]}" || die 'the stow simulation failed; nothing was changed'
	for path in "${overlay[@]}"; do printf 'would recolour %s (%s)\n' "$HOME/$path" "$theme"; done
	skipped_note
	printf 'dry run: the staged config verified; nothing was changed\n'
	exit 0
fi

# --- the stow simulation: still nothing touched -----------------------------------------------------------------
# Stow aborts all packages on one conflict, so ask it before the first file moves.
"$repo_root/scripts/deploy.sh" --dry-run --no-theme "${protect_args[@]}" "${packages[@]}" >/dev/null || die 'the stow simulation failed (see above); nothing was changed'

# --- go live: every step below is undone by --rollback -------------------------------------------------------------
# The stamp has to be unique: two deploys in one second must not share (and overwrite) a backup.
backups_dir="$state/vivac/backups"
{ mkdir -p -- "$backups_dir" && [[ -w "$backups_dir" ]]; } || die "the backup directory $backups_dir is not writable; nothing was changed"
stamp="$(date -u +%Y%m%dT%H%M%SZ)" suffix='' attempt=0
until mkdir -- "$backups_dir/$stamp$suffix" 2>/dev/null; do
	attempt=$((attempt + 1))
	((attempt < 100)) || die "cannot create a backup directory under $backups_dir; nothing was changed"
	suffix="-$attempt"
done
backup_root="$backups_dir/$stamp$suffix"
overlay_state="$state/vivac/colour-overlay"
overlay_keys=()
for path in "${overlay[@]}"; do
	key="${HOME}/${path}"
	key="${key#"$config"/}"
	overlay_keys+=("${key//\//__}")
done
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
[[ -d "$overlay_state" ]] || colour_state_new=true

# A backup entry that equals what is live now says nothing a rollback needs, and a
# deploy with nothing left over keeps no backup at all: a later bare --rollback
# must never land on an empty one.
prune_backup() {
	local saved relative live
	while IFS= read -r -d '' saved; do
		relative="${saved#"$backup_root"/}"
		live="$HOME/$relative"
		if [[ -L "$saved" ]]; then
			[[ -L "$live" && "$(readlink -- "$saved")" == "$(readlink -- "$live")" ]] && rm -f -- "$saved"
		elif [[ -f "$live" && ! -L "$live" ]] && cmp -s -- "$saved" "$live" && [[ "$(stat -c %a -- "$saved")" == "$(stat -c %a -- "$live")" ]]; then
			rm -f -- "$saved"
		fi
	done < <(find "$backup_root" -path "$backup_root/.overlay-state" -prune -o \( -type f -o -type l \) ! -name MANIFEST -print0)
	find "$backup_root" -mindepth 1 -type d -empty -delete
}

# The one child that may outlive a signal: deploy.sh (and the stow under it) or the overlay.
# It gets its own session, so finish can stop the whole group, and the wait below is
# interrupted at once by a trapped signal (a foreground child would hold the trap back).
child=''
run_child() {
	local rc=0
	setsid "$@" &
	child=$!
	wait "$child" || rc=$?
	child=''
	return "$rc"
}

finish() {
	local status=$? path key
	trap '' INT TERM HUP
	if [[ -n "$child" ]]; then
		kill -TERM -- "-$child" 2>/dev/null || true
		wait "$child" 2>/dev/null || true
	fi
	prune_backup || true
	{
		for path in "${absent[@]}"; do
			[[ ! -e "$HOME/$path" && ! -L "$HOME/$path" ]] || printf 'created\t%s\n' "$path"
		done
		for path in "${newdirs[@]}"; do [[ ! -d "$HOME/$path" ]] || printf 'newdir\t%s\n' "$path"; done
		if $colour_state_new && [[ -d "$overlay_state" ]]; then printf 'newtree\t%s\n' "$overlay_state"; fi
		for key in "${overlay_keys[@]}"; do
			if [[ -d "$overlay_state/$key" && -d "$backup_root/.overlay-state/$key" ]] && diff -rq -- "$backup_root/.overlay-state/$key" "$overlay_state/$key" >/dev/null; then
				rm -rf -- "${backup_root:?}/.overlay-state/$key"
			elif [[ -e "$overlay_state/$key" || -e "$backup_root/.overlay-state/$key" ]]; then
				printf 'overlaystate\t%s\n' "$key"
			fi
		done
	} >"$backup_root/MANIFEST"
	find "$backup_root" -mindepth 1 -type d -empty -delete
	if [[ ! -s "$backup_root/MANIFEST" && -z "$(find "$backup_root" -mindepth 1 ! -name MANIFEST -print -quit)" ]]; then
		rm -rf -- "$backup_root"
		printf 'nothing changed on the host; no backup kept\n'
	elif ((status != 0)); then
		# Whatever stopped the run, the host must not stay half applied: undo this run's MANIFEST now.
		printf 'deploy-host: failed (exit %s); undoing this run\n' "$status" >&2
		if rollback_root "$backup_root"; then
			printf 'deploy-host: the host is back to its state before this run (rolled back automatically); backup kept at %s\n' "$backup_root" >&2
		else
			printf 'deploy-host: the automatic rollback FAILED; run: %s --rollback %s\n' "$repo_root/scripts/deploy-host.sh" "$backup_root" >&2
		fi
	else
		printf 'backup: %s\n' "$backup_root"
		printf 'rollback: %s --rollback %s\n' "$repo_root/scripts/deploy-host.sh" "$backup_root"
	fi
	rm -rf -- "$stage"
	exit "$status"
}
trap finish EXIT
# A signal must end in the EXIT trap with a non-zero status, or the run would look like a success.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

save() { # save RELATIVE — copy a host file into the backup, keeping mode and links
	mkdir -p -- "$(dirname -- "$backup_root/$1")"
	cp -a -- "$HOME/$1" "$backup_root/$1"
}
# The overlay's state decides whether it swaps or skips; it has to travel with the files it describes.
for key in "${overlay_keys[@]}"; do
	if [[ -d "$overlay_state/$key" ]]; then
		mkdir -p -- "$backup_root/.overlay-state"
		cp -a -- "$overlay_state/$key" "$backup_root/.overlay-state/$key"
	fi
done
# The MANIFEST is written BEFORE the first change, from the plan, and again at the end from what
# really happened. After a kill -9 or a power cut --rollback still finds it: removing a path that was
# absent before this run (or restoring a saved one) is right whether or not the run got to it.
{
	for path in "${absent[@]}"; do printf 'created\t%s\n' "$path"; done
	for path in "${newdirs[@]}"; do printf 'newdir\t%s\n' "$path"; done
	if $colour_state_new; then printf 'newtree\t%s\n' "$overlay_state"; fi
	for key in "${overlay_keys[@]}"; do printf 'overlaystate\t%s\n' "$key"; done
} >"$backup_root/MANIFEST.tmp"
mv -- "$backup_root/MANIFEST.tmp" "$backup_root/MANIFEST"
sync "$backup_root/MANIFEST" "$backup_root" 2>/dev/null || true
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

# deploy.sh names its own backup directory; this script prints the one that matters.
skipped_note
deploy_rc=0
DEPLOY_BACKUP_ROOT="$backup_root" run_child "$repo_root/scripts/deploy.sh" --no-theme "${protect_args[@]}" "${packages[@]}" >"$stage/deploy.out" || deploy_rc=$?
grep -v '^backup: ' "$stage/deploy.out" || true
((deploy_rc == 0)) || exit "$deploy_rc"

for path in "${overlay[@]}"; do [[ -e "$backup_root/$path" ]] || save "$path"; done
run_child "$repo_root/scripts/colour-overlay.sh" --apply "$theme" --config-dir "$config" || die 'the colour overlay failed'
