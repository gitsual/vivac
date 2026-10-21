#!/usr/bin/env bash
set -Eeuo pipefail

# The image builder is only trustworthy if it cannot drift from the gate and
# cannot ship the build's own credentials. Both are structural properties of
# the two scripts, so they are asserted here rather than left to a reviewer.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
build="$repo_root/scripts/build-vm-image.sh"
seal="$repo_root/scripts/seal-vm-image.sh"
gate="$repo_root/scripts/test-vm.sh"
acceptance="$repo_root/tests/guest-acceptance.sh"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
for file in "$build" "$seal" "$gate" "$acceptance"; do
	[[ -x "$file" ]] || fail "missing or not executable: $file"
done

# One acceptance, two callers: neither may carry an inline copy.
for caller in "$build" "$gate"; do
	grep -Fq 'tests/guest-acceptance.sh' "$caller" || fail "$caller does not feed the shared acceptance"
	grep -q "<<'GUEST'" "$caller" && fail "$caller still embeds an inline acceptance"
done

# A backing file is meaningless off this machine; the artifact must be flat.
grep -Eq 'qemu-img convert -O qcow2' "$build" || fail 'the builder does not flatten the overlay'
grep -Fq 'discard=unmap' "$build" || fail 'the build drive cannot be trimmed, so the seal cannot shrink it'
grep -Fq 'IMAGE_SEAL: DONE' "$build" || fail 'the builder does not require the seal marker'
grep -Fq 'VM_ACCEPTANCE: PASS' "$build" || fail 'the builder seals without requiring the acceptance'

# Everything that would identify the build host or let a stranger in.
declare -A removals=(
	[authorized_keys]='the build SSH key'
	['/etc/ssh/ssh_host_']='the SSH host keys'
	['/etc/machine-id']='the machine id'
	['cloud-init.disabled']='the cloud-init datasource'
)
for needle in "${!removals[@]}"; do
	grep -Fq "$needle" "$seal" || fail "the seal does not deal with ${removals[$needle]}"
done
# The credentials are a published convention rather than a secret, so nothing
# expires them; what makes that defensible is the closed door, and the seal has
# to close it.
grep -Fq 'systemctl disable sshd.service' "$seal" || fail 'the seal ships a known root password with sshd enabled'
grep -Fq 'serial-getty@ttyS0.service' "$seal" || fail 'the seal leaves no console to drive the image from'
grep -Fq 'chage' "$seal" && fail 'the seal expires an account whose password is published on purpose'

# Ordering is load-bearing: the seal drops passwordless sudo and its own key
# at the very end, so every privileged step above must already have run.
key_line="$(grep -n 'authorized_keys' "$seal" | tail -1 | cut -d: -f1)"
for earlier in 'fstrim' 'ssh_host_' 'machine-id' 'systemd-run'; do
	line="$(grep -n -- "$earlier" "$seal" | tail -1 | cut -d: -f1)"
	((line < key_line)) || fail "the seal removes its key before it finishes with $earlier"
done

# Dropping cloud-init's NOPASSWD rule is irreversible over SSH: sudo then wants
# a password this session has no terminal to type. Nothing privileged may come
# after it, and only the one root transaction that performs it may contain it.
# This cost one build.
drop_line="$(grep -n '90-cloud-init-users' "$seal" | tail -1 | cut -d: -f1)"
[[ -n "$drop_line" ]] || fail 'the seal never drops the build sudoers rule'
last_sudo="$(grep -nE '(^|\|[[:space:]]*)sudo ' "$seal" | tail -1 | cut -d: -f1)"
((last_sudo < drop_line)) || fail 'the seal invokes sudo after dropping passwordless sudo, which cannot work without a terminal'

# The acceptance meets the image the way its owner will: no network device at
# all, driven from the console with the credentials the README prints.
accept="$repo_root/scripts/test-vm-image.sh"
grep -Fq -- '-nic none' "$accept" || fail 'the acceptance still attaches a network device'
grep -Fq 'SSHD=' "$accept" || fail 'the acceptance does not check that sshd is off'
grep -Fq 'MACHINE_ID=' "$accept" || fail 'the acceptance does not compare machine ids'
grep -Fq 'ssh-keyscan' "$accept" && fail 'the acceptance still expects the image to serve ssh'

grep -Fxq 'dist/' "$repo_root/.gitignore" || fail 'built artifacts are not ignored'

printf 'vm image build: one shared acceptance, a flat artifact, and a seal that outlives nothing\n'
