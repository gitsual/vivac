#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_root"

# Stage labels are numbered at run time so that adding a stage touches one line
# instead of renumbering every label. The total is the number of `stage` calls
# in this file, counted once at startup.
stage_total="$(grep -c '^stage ' "${BASH_SOURCE[0]}")"
stage_index=0
stage() {
	stage_index=$((stage_index + 1))
	printf '[%d/%d] %s\n' "$stage_index" "$stage_total" "$1"
}

stage 'shell syntax'
while IFS= read -r -d '' file; do bash -n "$file"; done < <(find scripts dotfiles lib tests -type f \( -name '*.sh' -o -name 'workstation-security-audit' \) -print0)

stage 'shellcheck'
if command -v shellcheck >/dev/null; then
	mapfile -d '' shell_files < <(find scripts dotfiles lib tests -type f \( -name '*.sh' -o -name 'workstation-security-audit' \) -print0)
	shellcheck "${shell_files[@]}"
else
	printf '%s\n' 'shellcheck not installed; syntax checks still ran'
fi

stage 'structured configuration'
python -c 'import ast, pathlib; ast.parse(pathlib.Path("scripts/privacy-scan.py").read_text())'
python -c 'import ast, pathlib; ast.parse(pathlib.Path("scripts/configure-audio.py").read_text())'
python -c 'import ast, pathlib; ast.parse(pathlib.Path("dotfiles/automation/.local/bin/workstation-task-runner").read_text())'
python -m json.tool profiles/automation/example.json >/dev/null
while IFS= read -r -d '' file; do
	nvim --headless --clean -u NONE -c "lua assert(loadfile([[${file}]]))" -c qa
done < <(find dotfiles/nvim -type f -name '*.lua' -print0)
systemd-analyze verify \
	dotfiles/security/.config/systemd/user/*.service \
	dotfiles/security/.config/systemd/user/*.timer \
	dotfiles/automation/.config/systemd/user/*.service \
	dotfiles/automation/.config/systemd/user/*.timer

stage 'package manifests'
for manifest in packages/*.txt; do
	[[ "$manifest" == *.local.txt ]] && continue
	[[ -f "$manifest" ]]
	diff -u "$manifest" <(LC_ALL=C sort -u "$manifest")
done

stage 'symlinks and unexpected binaries'
if find . \( -path ./.git -o -path ./.vm-test -o -path ./.vm-image -o -path ./dist -o -path ./.audit \) -prune -o -type l ! -exec test -e {} \; -print -quit | grep -q .; then
	printf '%s\n' 'broken symlink found' >&2
	exit 1
fi
# The synthetic /sys trees under tests/fixtures are exempt. Their contents are
# whatever the kernel writes in that file — a bare driver name, a raw
# millidegree count — and `file` guesses wildly on inputs that short: an
# hwmon `name` holding "coretemp" is reported as a Xenix core file. The shape
# of those files is not ours to change, so the scan does not read them.
# The bundled wallpaper and everything under assets/ — the README captures, the
# rendered banner and the recorded tour — are the only binaries this repository
# ships on purpose; every byte of them is still pinned by
# data/asset-manifest.tsv, the film included.
if find . \( -path ./.git -o -path ./.vm-test -o -path ./.vm-image -o -path ./dist -o -path ./.audit -o -path './tests/fixtures/*/sysroot/sys' \) -prune -o -type f ! -path './dotfiles/hypr/.local/share/wallpapers/bad-romance.png' ! -path './assets/*.png' ! -path './assets/*.mp4' ! -path './assets/*.gif' -print0 | xargs -0 file | grep -Ev 'text|empty|SVG|JSON|Python script|shell script' >/dev/null; then
	printf '%s\n' 'unexpected binary file found' >&2
	exit 1
fi

# Renders are checked before the asset manifest on purpose: the manifest hashes
# rendered bytes, and hashing before rendering would pass on stale output.
# tests/cases/test_stage_order.sh asserts this ordering.
stage 'committed renders and theme drift'
"$repo_root/scripts/check-theme-drift.sh"

stage 'asset manifest'
"$repo_root/scripts/check-asset-manifest.sh"
stage 'privacy and secret scan'
python scripts/privacy-scan.py .
if command -v gitleaks >/dev/null; then
	gitleaks detect --no-banner --no-git --source .
else
	printf '%s\n' 'gitleaks not installed; explicit privacy scanner completed'
fi

stage 'default profile baseline'
"$repo_root/scripts/freeze-baseline.sh"

# Skipped with a notice where Hyprland is not installed; the VM gate runs it
# for real on a guest that has it.
stage 'hyprland config verification'
hypr_verify_log="$(mktemp)"
"$repo_root/scripts/verify-hypr-config.sh" | tee "$hypr_verify_log"

stage 'selector registry'
"$repo_root/scripts/check-selectors.sh"

stage 'gpu catalogue'
"$repo_root/scripts/check-gpu-catalogue.sh"

stage 'help registry'
"$repo_root/scripts/check-help-registry.sh"

stage 'i18n coverage'
"$repo_root/scripts/check-i18n-coverage.sh"

stage 'unit and fixture tests'
"$repo_root/tests/run.sh"

stage 'deployment script dry run'
dry_home="$(mktemp -d "${TMPDIR:-/tmp}/vivac-dry-run.XXXXXX")"
trap 'rm -rf -- "$dry_home"' EXIT
HOME="$dry_home" XDG_STATE_HOME="$dry_home/.local/state" "$repo_root/scripts/deploy.sh" --all --dry-run
HOME="$dry_home" XDG_STATE_HOME="$dry_home/.local/state" FACTS_FILE="$repo_root/tests/golden/vm-virtio/hardware-facts" \
	"$repo_root/scripts/render-config.sh" --dry-run
HOME="$dry_home" XDG_STATE_HOME="$dry_home/.local/state" FACTS_FILE="$repo_root/tests/golden/vm-virtio/hardware-facts" \
	FACTS_OVERRIDE="$dry_home/none" "$repo_root/scripts/gpu-setup.sh" --dry-run
rm -rf -- "$dry_home"
trap - EXIT

stage 'isolated deployment regression'
"$repo_root/scripts/test-deploy.sh"

stage 'deployment integrity'
"$repo_root/scripts/check-deploy-integrity.sh"

printf '%s\n' 'all repository checks passed'
# A skipped Hyprland verification is not a pass for the config: say so last.
if grep -q 'NOT VERIFIED' "$hypr_verify_log"; then grep '^!!!' "$hypr_verify_log"; fi
rm -f -- "$hypr_verify_log"
