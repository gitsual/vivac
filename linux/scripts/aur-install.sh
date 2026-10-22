#!/usr/bin/env bash
set -Eeuo pipefail

# Install the named AUR packages, and be honest about what that means.
#
# The AUR is not a repository: it is a collection of build recipes, so every
# name here is compiled on this machine. That is a real decision, so it is made
# in one place instead of being assumed by every caller.
#
# No helper is installed to do it. The first attempt did install one — paru-bin
# — and it failed the way prebuilt binaries fail: paru-bin 2.1.0 is linked
# against libalpm.so.15, the guest had just upgraded to a pacman that ships
# libalpm.so.16, and the helper could not start. A tool that must be rebuilt
# whenever pacman moves is a poor foundation for provisioning pacman.
#
# What a helper would do for an explicit, flat list of packages is clone each
# recipe and run makepkg, so that is what happens here: no Rust toolchain, no
# Go toolchain, no third party in the trust chain, and nothing that can be out
# of step with the local libalpm because nothing is prebuilt. makepkg resolves
# official dependencies through pacman on its own. An AUR package that depends
# on ANOTHER AUR package fails loudly naming it, and the cure is to list that
# one first — which also documents the dependency where a reader will find it.
#
# If the machine already has paru or yay, theirs is used: someone who chose a
# helper has chosen how their AUR packages get built, and this is not the place
# to overrule them.
#
#   --noconfirm   pass it through to makepkg and pacman
#
# Already-installed packages are left alone; this is --needed, not a rebuild.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
noconfirm=false
packages=()
while (($#)); do
	case "$1" in
	--noconfirm) noconfirm=true ;;
	-h | --help)
		sed -n '4,29p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
		exit 0
		;;
	--)
		shift
		packages+=("$@")
		break
		;;
	-*)
		printf 'Unknown option: %s\n' "$1" >&2
		exit 2
		;;
	*) packages+=("$1") ;;
	esac
	shift
done
((${#packages[@]})) || exit 0
: "$repo_root"

# makepkg refuses to run as root and asks for root itself when it installs, so
# this must run as the user who will own the packages.
[[ "$(id -u)" -ne 0 ]] || {
	printf 'aur-install: run as the unprivileged user; makepkg refuses to build as root.\n' >&2
	exit 1
}

for helper in paru yay; do
	if command -v "$helper" >/dev/null; then
		args=(-S --needed)
		$noconfirm && args+=(--noconfirm)
		exec "$helper" "${args[@]}" -- "${packages[@]}"
	fi
done

for required in git makepkg; do
	command -v "$required" >/dev/null || {
		printf 'aur-install: cannot build without %s; install base-devel and git.\n' "$required" >&2
		exit 1
	}
done

work="$(mktemp -d "${TMPDIR:-/tmp}/vivac-aur.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT

makepkg_args=(-si)
$noconfirm && makepkg_args+=(--noconfirm)
built=0
for package in "${packages[@]}"; do
	if pacman -Qq -- "$package" >/dev/null 2>&1; then
		printf 'aur-install: %s is already installed\n' "$package"
		continue
	fi
	printf 'aur-install: building %s from its AUR recipe\n' "$package"
	git clone --depth 1 "https://aur.archlinux.org/$package.git" "$work/$package" || {
		printf 'aur-install: no AUR recipe named %s\n' "$package" >&2
		exit 1
	}
	(cd "$work/$package" && makepkg "${makepkg_args[@]}") || {
		printf 'aur-install: %s did not build. If it names an AUR dependency, list that one first.\n' "$package" >&2
		exit 1
	}
	pacman -Qq -- "$package" >/dev/null 2>&1 || {
		printf 'aur-install: %s built but is not installed\n' "$package" >&2
		exit 1
	}
	built=$((built + 1))
done
printf 'aur-install: %d of %d built from source\n' "$built" "${#packages[@]}"
