#!/usr/bin/env bash
# Bind and registry parity for the help panes.
#
# Every bind in the Hyprland templates carries a "# @help: <pane> <label_key>"
# line right above it (Lua: "-- @help: ..." above a literal one-line
# hl.bind("MODS + KEY", ...), the only form the gate can read), that key
# exists in the English table, and the registry has the row (pane, bind id)
# with the same key. Every hypr row in the
# registry is such a bind. Every doc row points at a file under docs/. A key
# added to the desktop without its help line, or a help line that describes
# a key that is gone, fails here rather than in a user's F1.
set -Eeuo pipefail

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
# shellcheck source=lib/kv.sh
source "$repo_root/lib/kv.sh"
# shellcheck source=lib/i18n.sh
source "$repo_root/lib/i18n.sh"
# shellcheck source=lib/help.sh
source "$repo_root/lib/help.sh"

registry="${HELP_REGISTRY:-$repo_root/data/help-registry.tsv}"
status=0
problem() {
	printf 'help registry: %s\n' "$1" >&2
	status=1
}

# HELP_TEMPLATE names one template; by default the Lua compositor template is
# read, and it must carry the full set of annotated binds.
if [[ -n "${HELP_TEMPLATE:-}" ]]; then
	templates=("$HELP_TEMPLATE")
else
	templates=("$repo_root/templates/hypr/.config/hypr/hyprland.lua.in")
fi

i18n_load en "$repo_root/i18n"
help_load_registry "$registry"

declare -A seen=()

# check_annotated PREVIOUS LINENO ID ANNOTATION_PATTERN HINT — a bind's id must
# sit under an annotation naming a label that the registry agrees with.
check_annotated() {
	local previous="$1" lineno="$2" id="$3" pattern="$4" hint="$5" pane label
	if [[ "$previous" =~ $pattern ]]; then
		pane="${BASH_REMATCH[1]}"
		label="${BASH_REMATCH[2]}"
		[[ -v I18N_TEXT["$label"] ]] || problem "line $lineno: label $label is not in i18n/en.conf"
		if [[ -v HELP_LABEL["$pane/$id"] ]]; then
			[[ "${HELP_LABEL["$pane/$id"]}" == "$label" ]] || problem "line $lineno: registry says $pane/$id is ${HELP_LABEL["$pane/$id"]}, the annotation says $label"
		else
			problem "line $lineno: bind $id has no registry row in pane $pane"
		fi
		seen["$pane/$id"]=1
	else
		problem "line $lineno: bind $id has no '$hint' line above it"
	fi
}

# scan_template FILE — fill `seen` with the pane/id of every annotated bind.
scan_template() {
	local file="$1" line previous='' lineno=0 mods key rc lua=false
	[[ "$file" == *.lua.in || "$file" == *.lua ]] && lua=true
	seen=()
	while IFS= read -r line || [[ -n "$line" ]]; do
		lineno=$((lineno + 1))
		if $lua; then
			rc=0
			help_lua_bind_id "$line" || rc=$?
			if ((rc == 0)); then
				check_annotated "$previous" "$lineno" "$HELP_LUA_ID" '^--\ @help:\ ([a-z]+)\ ([a-z0-9_.]+)$' '-- @help: <pane> <label_key>'
			elif ((rc == 2)); then
				problem "line $lineno: hl.bind key is not a literal (loops, concatenation and indentation hide it from the gate): $line"
			fi
		elif [[ "$line" =~ ^bind[lmer]*\ =\ ([^,]*),\ ([^,]+), ]]; then
			mods="${BASH_REMATCH[1]}"
			key="${BASH_REMATCH[2]}"
			check_annotated "$previous" "$lineno" "$(help_bind_id "$mods" "${key// /}")" '^#\ @help:\ ([a-z]+)\ ([a-z0-9_.]+)$' '# @help: <pane> <label_key>'
		fi
		previous="$line"
	done <"$file"
}

for template in "${templates[@]}"; do
	scan_template "$template"
	for row in "${HELP_ROWS[@]}"; do
		case "${HELP_TYPE["$row"]}" in
		exec | dispatch)
			[[ -v seen["$row"] ]] || problem "$row: the registry describes a Hyprland key the template does not bind (${template##*/})"
			;;
		esac
	done
done

for row in "${HELP_ROWS[@]}"; do
	[[ -v I18N_TEXT["${HELP_LABEL["$row"]}"] ]] || problem "$row: label ${HELP_LABEL["$row"]} is not in i18n/en.conf"
	case "${HELP_TYPE["$row"]}" in
	doc)
		path="${HELP_VALUE["$row"]%%#*}"
		[[ "$path" == docs/* && -f "$repo_root/$path" ]] || problem "$row: doc value $path is not a file under docs/"
		;;
	exec | dispatch)
		[[ "${HELP_PANE["$row"]}" == hypr ]] || problem "$row: ${HELP_TYPE["$row"]} actions belong to the hypr pane"
		;;
	esac
done

((status == 0)) && printf 'help registry: %d rows, every Hyprland bind annotated and registered\n' "${#HELP_ROWS[@]}"
exit "$status"
