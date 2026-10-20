#!/usr/bin/env bash
set -Eeuo pipefail

# scripts/deploy.sh --protect REL leaves a file of the owner's alone while the
# rest of the package is deployed; DEPLOY_BACKUP_ROOT names where the moved
# files go; the root must be writable before anything is moved; --no-theme skips
# the palette reapply, which writes outside the backup.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
deploy="$repo_root/scripts/deploy.sh"
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-protect.XXXXXX")"
trap 'chmod -R u+w "$sandbox" 2>/dev/null; rm -rf -- "$sandbox"' EXIT
fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

home="$sandbox/home"
mkdir -p -- "$home/.config/hypr" "$home/.config/vivac"
printf 'owner shell\n' >"$home/.bashrc"
printf 'owner paper\n' >"$home/.config/hypr/hyprpaper.conf"
printf 'owner hyprland\n' >"$home/.config/hypr/hyprland.lua"
printf 'theme=carmen\n' >"$home/.config/vivac/settings"
cp -a -- "$home" "$sandbox/before"
run() { HOME="$home" XDG_STATE_HOME="$sandbox/state" "$deploy" "$@"; }
protect=(--protect .bashrc --protect .config/hypr/hyprpaper.conf)

# --- bad usage ------------------------------------------------------------------------------------------------
run --protect >/dev/null 2>&1 && fail '--protect without a path was accepted'
run --protect /etc/passwd hypr >/dev/null 2>&1 && fail 'an absolute --protect path was accepted'

# --- the dry run names what it keeps and changes nothing ----------------------------------------------------
out="$(run --dry-run "${protect[@]}" shell hypr)"
grep -Fq "would skip (protected) $home/.bashrc" <<<"$out" || fail "the dry run did not name .bashrc: $out"
grep -Fq "would back up $home/.config/hypr/hyprland.lua" <<<"$out" || fail 'the dry run did not plan the hyprland.lua backup'
grep -Fq "would back up $home/.config/hypr/hyprpaper.conf" <<<"$out" && fail 'the dry run planned to move a protected file'
diff -r "$sandbox/before" "$home" >/dev/null || fail 'the dry run changed the home directory'

# --- an unwritable backup root aborts before anything moves ---------------------------------------------------
mkdir -p -- "$sandbox/ro"
chmod 500 "$sandbox/ro"
DEPLOY_BACKUP_ROOT="$sandbox/ro/backups/x" run --no-theme "${protect[@]}" shell hypr >/dev/null 2>"$sandbox/err" &&
	fail 'deploy went ahead with an unwritable backup root'
grep -q 'backup' "$sandbox/err" || fail "no explanation for the unwritable backup root: $(<"$sandbox/err")"
diff -r "$sandbox/before" "$home" >/dev/null || fail 'an aborted deploy changed the home directory'
chmod 700 "$sandbox/ro"

# --- protected files stay, the rest is deployed, the backup lands where it was told --------------------------
out="$(DEPLOY_BACKUP_ROOT="$sandbox/bk" run --no-theme "${protect[@]}" shell hypr)" || fail "deploy failed: $out"
for f in .bashrc .config/hypr/hyprpaper.conf; do
	[[ -f "$home/$f" && ! -L "$home/$f" ]] || fail "$f is no longer the owner's regular file"
	cmp -s "$sandbox/before/$f" "$home/$f" || fail "$f changed"
	[[ ! -e "$sandbox/bk/$f" ]] || fail "$f was backed up although it is protected"
done
[[ "$(readlink -f -- "$home/.config/hypr/hyprland.lua")" == "$repo_root/dotfiles/hypr/.config/hypr/hyprland.lua" ]] || fail 'hyprland.lua was not deployed'
[[ "$(<"$sandbox/bk/.config/hypr/hyprland.lua")" == 'owner hyprland' ]] || fail 'the replaced hyprland.lua was not backed up in the named root'
[[ -L "$home/.config/hypr/scripts/help-pane.sh" ]] || fail 'the unprotected part of the package was not deployed'
grep -Fxq "backup: $sandbox/bk" <<<"$out" || fail "the backup root was not printed: $out"
grep -q 'theme reapplied' <<<"$out" && fail '--no-theme still reapplied the palette'
printf 'deploy --protect: owner files kept, rest deployed, backup root honoured\n'
