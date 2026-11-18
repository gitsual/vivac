#!/usr/bin/env bash
set -Eeuo pipefail

# The SystemUI shade redirect and the launcher agree on the contract (package,
# alias, action, permission), the hook is wired in the status bar touch path,
# and the redirect class only ever uses the documented start flags.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
base="$repo_root/os/patches/frameworks/base"
cls="$base/vivac-files/packages/SystemUI/src/com/android/systemui/statusbar/phone/VivacShadeRedirect.kt"
patch="$base/0002-vivac-shade-redirect.patch"
manifest="$repo_root/launcher/app/src/main/AndroidManifest.xml"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

[[ -f "$cls" ]] || fail "missing VivacShadeRedirect.kt"
[[ -f "$patch" ]] || fail "missing 0002 patch"

has() { grep -qF -- "$2" "$1" || fail "$3"; }

has "$cls" 'const val LAUNCHER_PACKAGE = "dev.vivac.launcher"' "package not the launcher's"
has "$cls" 'const val AVISOS_ENTRY = "dev.vivac.launcher.AvisosEntry"' "alias not AvisosEntry"
has "$cls" 'const val ACTION_OPEN_AVISOS = "dev.vivac.launcher.action.OPEN_AVISOS"' "action not OPEN_AVISOS"
has "$cls" 'FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP' "start flags changed"
has "$cls" 'startActivityAsUser(intent, UserHandle.CURRENT)' "not started as the current user"
has "$cls" 'isKeyguardLocked' "keyguard gate missing"
has "$cls" 'ACTIVITY_TYPE_HOME' "home gate missing"
has "$cls" 'pointerCount > 1' "two-finger gate missing"
has "$patch" '+            when (vivacShadeRedirect.onStatusBarTouch(event)) {' "hook not wired in the status bar touch handler"
has "$patch" 'PhoneStatusBarViewController.kt' "patch is not on PhoneStatusBarViewController"

if [[ -f "$manifest" ]]; then
	has "$manifest" 'android:name=".AvisosEntry"' "launcher has no AvisosEntry alias"
	has "$manifest" 'android.permission.STATUS_BAR_SERVICE' "alias is not protected by STATUS_BAR_SERVICE"
	has "$manifest" 'dev.vivac.launcher.action.OPEN_AVISOS' "alias does not take OPEN_AVISOS"
fi
