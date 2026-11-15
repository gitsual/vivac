#!/usr/bin/env bash
# The android half's gate, run on the PC (no phone needed): shell syntax,
# the shell linter, Python syntax of the tools, shared data in sync, and the tests.
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

step() { printf '== %s\n' "$*"; }

step 'shell syntax'
for f in scripts/*.sh tests/run.sh tests/cases/*.sh; do bash -n "$f"; done

step 'shellcheck'
shellcheck scripts/*.sh tests/run.sh tests/cases/*.sh

step 'python syntax'
for f in bin/*; do
	head -1 "$f" | grep -q python || continue
	python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "$f"
done

step 'privacy and secret scan'
python3 ../linux/scripts/privacy-scan.py .

step 'shared data matches shared/'
bash ../shared/sync.sh --check

step 'tests'
bash tests/run.sh
