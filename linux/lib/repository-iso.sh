#!/usr/bin/env bash
# The disc the guest reads the repository from.
#
# This existed three times, once per script that boots a machine, and the three
# copies drifted: the one in open-tested-vm.sh never learned to skip `dist/`,
# so re-opening a VM after an image had been published tarred the published
# image into the disc it was building -- eighteen gigabytes of it, growing as
# it wrote, and the open never finished. The exclusions are not a detail of one
# script; they are the definition of "the repository", so they live once.

# repository_iso REPO_ROOT RUN_DIR
repository_iso() {
	local repo_root="$1" run="$2"
	tar --exclude=.git --exclude=.vm-test --exclude=.vm-image --exclude=dist \
		-czf "$run/repository.tar.gz" -C "$repo_root" .
	xorriso -as mkisofs -quiet -output "$run/repository.iso" \
		-volid VIVAC -joliet -rock "$run/repository.tar.gz"
}
