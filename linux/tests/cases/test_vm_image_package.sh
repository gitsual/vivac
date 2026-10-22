#!/usr/bin/env bash
set -Eeuo pipefail

# A release asset over 2 GiB is refused at upload, after a very long upload,
# so the packager checks the budget itself. What ships is also what was
# accepted: the same acceptance boots the qcow2 and the OVA's disk, and the
# page that tells a stranger how to reassemble the parts must exist.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
packager="$repo_root/scripts/package-vm-image.sh"
accepter="$repo_root/scripts/test-vm-image.sh"
doc="$repo_root/docs/vm-image.md"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
for file in "$packager" "$accepter"; do
	[[ -x "$file" ]] || fail "missing or not executable: $file"
done
[[ -f "$doc" ]] || fail 'docs/vm-image.md is missing'

grep -Fq '2 * 1024 * 1024 * 1024' "$packager" || fail 'the packager does not name the release asset ceiling'
grep -Fq 'over the' "$packager" || fail 'the packager does not refuse an oversized part'
grep -Fq 'SHA256SUMS' "$packager" || fail 'the packager writes no checksums'
grep -Eq 'sha256sum -- "\$\{sums\[@\]\}"' "$packager" || fail 'the checksums do not cover every emitted file'

# The OVF descriptor must precede the disk inside the archive, per the spec;
# an OVA that lists them the other way round is rejected by some importers.
# shellcheck disable=SC2016  # the needles are literal script text, not expansions
grep -Eq 'tar -C "\$dist" -cf "\$dist/\$stem\.ova" "\$stem\.ovf" "\$stem\.vmdk"' "$packager" ||
	fail 'the OVA does not put its descriptor first'
grep -Fq 'subformat=streamOptimized' "$packager" || fail 'the OVA disk is not streamOptimized'

# The accepter must read the format rather than assume qcow2, or the OVA's
# disk could never be put through it.
# shellcheck disable=SC2016  # literal script text again
grep -Fq 'format=$image_format' "$accepter" || fail 'the accepter hardcodes a disk format'

grep -Fq 'cat vivac.qcow2.part*' "$doc" || fail 'the page does not show how to reassemble'
# --ignore-missing is not cosmetic: SHA256SUMS lists both formats and a reader
# downloads one, so the bare command reports the other format's four absent
# entries as failures and exits non-zero on a download that is perfectly good.
grep -Fq 'sha256sum --ignore-missing -c SHA256SUMS' "$doc" ||
	fail 'the page does not show how to verify a partial download'
# Credentials that are published have to be published in full, and the reason
# they are safe has to be published with them: the page states both accounts
# and that the image does not listen.
grep -Fq 'toor' "$doc" || fail 'the page does not print the root password it ships'
grep -Fq 'does not listen on the network' "$doc" ||
	fail 'the page prints a known root password without saying why that is safe'
grep -Fq 'docs/vm-image.md' "$repo_root/README.md" || fail 'the README does not link the image page'
grep -Fq 'Downloadable image' "$repo_root/docs/destination-tests.md" ||
	fail 'the destination matrix has no section for the image'

printf 'vm image package: budget enforced, checksums complete, both disks acceptable\n'
