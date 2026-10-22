#!/usr/bin/env bash
# The catalogue: the default palette, the ones that ship under data/themes/,
# and the ones made from a picture (vivac-theme from-image), which live
# outside the checkout. Every reader of a theme name resolves it here, so a
# palette made from a picture is worn exactly like a shipped one.
#
# Palettes made from a picture live in the shared root's themes/ when
# shared_settings points at one (docs/bridge.md at the root of the product),
# so the other system finds the palette the shared theme setting names, and
# in $XDG_CONFIG_HOME/vivac/themes. The shared one is looked in first. A
# shipped name always means the shipped palette.
#
# Such a file is the user's, or came across a shared disk, so it is held to
# the corpus rule as it is read: the thirteen tokens, every one a corpus
# colour, and a wallpaper (if it names one) that is a plain file beside it.
# One that fails is not in the catalogue.
#
# Sourced, not executed. Requires lib/kv.sh and lib/settings.sh.

THEMES_DEFAULT=bad-romance

# themes_settings_file — the settings file every lookup reads the shared root from.
themes_settings_file() {
	printf '%s' "${SETTINGS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/vivac/settings}"
}

# themes_user_dirs — the folders palettes made from pictures live in, one per line.
themes_user_dirs() {
	local root
	if root="$(settings_shared_root "$(themes_settings_file)" 2>/dev/null)"; then
		printf '%s\n' "$root/themes"
	fi
	printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/vivac/themes"
}

# themes_home — where a new palette goes: the shared root's themes/ when the
# shared folder is there, this system's own otherwise.
themes_home() {
	local root
	if root="$(settings_shared_root "$(themes_settings_file)" 2>/dev/null)" && [[ -d "$root" ]]; then
		printf '%s' "$root/themes"
	else
		printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/vivac/themes"
	fi
}

# themes_user_valid REPO FILE — 0 when FILE keeps the corpus rule (see above).
themes_user_valid() {
	local repo="$1" file="$2"
	awk -F'\t' -v keys="$(grep -oE '^[A-Z][A-Z0-9_]*' "$repo/data/theme.conf" | tr '\n' ' ')" '
		NR == FNR { if ($0 !~ /^#/ && NF) corpus[$1] = 1; next }
		FNR == 1 { n = split(keys, list, " "); for (i = 1; i <= n; i++) wanted[list[i]] = 1 }
		{ sub(/\r$/, "") }
		/^# @wallpaper: / { if ($0 !~ /^# @wallpaper: [a-z][a-z0-9-]*\.(png|jpg)$/) bad = 1; next }
		/^[[:space:]]*(#|$)/ { next }
		{
			at = index($0, "=")
			key = substr($0, 1, at - 1); value = substr($0, at + 1)
			if (!at || !(key in wanted) || value !~ /^[0-9A-F]{6}$/ || !(value in corpus)) bad = 1
			seen[key] = 1
		}
		END {
			for (key in wanted) if (!(key in seen)) bad = 1
			exit bad
		}' "$repo/data/palette-corpus.tsv" "$file"
}

# theme_file_for REPO NAME — print the palette file NAME resolves to; 1 when none does.
theme_file_for() {
	local repo="$1" name="$2" dir
	if [[ "$name" == "$THEMES_DEFAULT" ]]; then
		printf '%s' "$repo/data/theme.conf"
		return 0
	fi
	[[ "$name" =~ ^[a-z][a-z0-9-]*$ ]] || return 1
	if [[ -f "$repo/data/themes/$name.conf" ]]; then
		printf '%s' "$repo/data/themes/$name.conf"
		return 0
	fi
	while IFS= read -r dir; do
		if [[ -f "$dir/$name.conf" ]] && themes_user_valid "$repo" "$dir/$name.conf"; then
			printf '%s' "$dir/$name.conf"
			return 0
		fi
	done < <(themes_user_dirs)
	return 1
}

# theme_wallpaper_for FILE — print the picture a palette made from one wears, when it is there.
theme_wallpaper_for() {
	local file="$1" picture
	picture="$(sed -nE 's/^# @wallpaper: ([a-z][a-z0-9-]*\.(png|jpg))$/\1/p' "$file" | tail -1)"
	[[ -n "$picture" && -f "$(dirname -- "$file")/$picture" ]] || return 1
	printf '%s' "$(dirname -- "$file")/$picture"
}

# theme_catalogue REPO — every name, the default first, then the shipped ones,
# then the ones made from pictures, each group sorted.
theme_catalogue() {
	local repo="$1" dir file name
	local -A shipped=()
	local mine=()
	printf '%s\n' "$THEMES_DEFAULT"
	while IFS= read -r name; do
		shipped["$name"]=1
		printf '%s\n' "$name"
	done < <(find "$repo/data/themes" -type f -name '*.conf' -printf '%f\n' | sed 's/\.conf$//' | LC_ALL=C sort)
	while IFS= read -r dir; do
		[[ -d "$dir" ]] || continue
		while IFS= read -r file; do
			name="$(basename -- "$file" .conf)"
			[[ "$name" =~ ^[a-z][a-z0-9-]*$ && ! -v shipped["$name"] ]] || continue
			[[ "$(theme_file_for "$repo" "$name")" == "$file" ]] || continue
			mine+=("$name")
		done < <(find "$dir" -maxdepth 1 -type f -name '*.conf')
	done < <(themes_user_dirs)
	((${#mine[@]})) && printf '%s\n' "${mine[@]}" | LC_ALL=C sort -u
	return 0
}
