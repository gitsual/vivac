#!/usr/bin/env bash
set -Eeuo pipefail

# Runs every behaviour test in tests/cases/. Each case is a standalone script
# that exits non-zero on failure; none of them may touch the live machine,
# require privilege, need the network, or assume a graphical session.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
export REPO_ROOT="$repo_root"

mapfile -t cases < <(find "$repo_root/tests/cases" -type f -name 'test_*.sh' | LC_ALL=C sort)

if ((${#cases[@]} == 0)); then
	printf 'no test cases found under tests/cases/\n' >&2
	exit 1
fi

failed=0
for case_file in "${cases[@]}"; do
	name="$(basename -- "$case_file" .sh)"
	if output="$(bash "$case_file" 2>&1)"; then
		printf '  ok   %s\n' "$name"
	else
		printf '  FAIL %s\n' "$name"
		printf '%s\n' "$output" | sed 's/^/       /'
		failed=$((failed + 1))
	fi
done

if ((failed)); then
	printf '%d of %d test cases failed\n' "$failed" "${#cases[@]}" >&2
	exit 1
fi

printf '%d test cases passed\n' "${#cases[@]}"
