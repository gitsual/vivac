#!/usr/bin/env bash
set -Eeuo pipefail

# Permanent gate over i18n/: every language table carries exactly the
# reference key set, its declared key count is true, and every label_key a
# registry references resolves. This stays in check.sh for good — a string
# added in any later change fails here until every table has it, which is the
# only way a second language stays complete.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/kv.sh
source "$repo_root/lib/kv.sh"

dir="${I18N_DIR:-$repo_root/i18n}"
data_dir="${I18N_DATA_DIR:-$repo_root/data}"
reference="$dir/en.conf"
status=0

keys_of() { awk -F= '!/^#/ && NF { print $1 }' "$1" | LC_ALL=C sort; }
declared_of() { awk '/^# keys: / { print $3; exit }' "$1"; }

[[ -r "$reference" ]] || {
	printf 'i18n: reference table %s missing\n' "$reference" >&2
	exit 1
}
reference_keys="$(keys_of "$reference")"

for table in "$dir"/*.conf; do
	name="$(basename -- "$table" .conf)"
	actual="$(keys_of "$table")"
	count="$(printf '%s\n' "$actual" | grep -c . || true)"
	declared="$(declared_of "$table")"

	[[ -n "$declared" ]] || {
		printf 'i18n/%s: no "# keys: N" header\n' "$name" >&2
		status=1
		continue
	}
	[[ "$declared" == "$count" ]] || {
		printf 'i18n/%s: header declares %s keys, table has %s\n' "$name" "$declared" "$count" >&2
		status=1
	}
	[[ "$(printf '%s\n' "$actual" | LC_ALL=C sort -u | grep -c .)" == "$count" ]] || {
		printf 'i18n/%s: duplicate keys\n' "$name" >&2
		status=1
	}
	if [[ "$name" != en && "$actual" != "$reference_keys" ]]; then
		printf 'i18n/%s: key set differs from en\n' "$name" >&2
		diff <(printf '%s\n' "$reference_keys") <(printf '%s\n' "$actual") | sed 's/^/  /' >&2 || true
		status=1
	fi
	# A translation carries no formatting directives: placeholders are {N}.
	if grep -Eq '^[^#][^=]*=.*%[sdqb]' "$table"; then
		printf 'i18n/%s: printf directive in a value; use {1}, {2}, ...\n' "$name" >&2
		status=1
	fi
done

# Every label_key referenced by a registry must exist in the reference table.
# Registries name their label column in the header line; this reads that.
for registry in "$data_dir"/*.tsv; do
	[[ -r "$registry" ]] || continue
	header="$(grep -m1 '^# id' "$registry" || true)"
	[[ -n "$header" ]] || continue
	column="$(printf '%s' "${header#\# }" | tr '\t' '\n' | grep -n '^label_key$' | cut -d: -f1 || true)"
	[[ -n "$column" ]] || continue
	while IFS= read -r key; do
		[[ -n "$key" ]] || continue
		grep -q "^${key}=" "$reference" || {
			printf '%s references label_key %s, absent from i18n/en.conf\n' "$(basename -- "$registry")" "$key" >&2
			status=1
		}
	done < <(grep -v '^#' "$registry" | cut -f"$column")
done

((status == 0)) && printf 'i18n: %d tables, %d keys each, every registry label resolves\n' \
	"$(find "$dir" -name '*.conf' | wc -l)" "$(printf '%s\n' "$reference_keys" | grep -c .)"
exit "$status"
