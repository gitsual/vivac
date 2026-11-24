#!/usr/bin/env bash
set -Eeuo pipefail

# android/scripts/deploy.sh in a fake Termux ($PREFIX and $HOME in a
# sandbox): every android/bin tool is linked into $PREFIX/bin; a file the
# user already had there is moved to a timestamped backup, never deleted; the
# Termux:Boot script is written and executable and starts sshd with a wake
# lock; sshd_config ends up refusing passwords; Termux wears the theme named
# in ~/.config/vivac/settings (the terminal colours Linux's kitty wears), a
# colours file of the user's own being backed up first; a second run changes
# nothing; --dry-run writes nothing at all.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
deploy="$repo_root/scripts/deploy.sh"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-deploy.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
export PREFIX="$sandbox/usr" HOME="$sandbox/home"
mkdir -p "$PREFIX/bin" "$PREFIX/etc/ssh" "$HOME"
printf 'old mine\n' >"$PREFIX/bin/vivac-facts"
printf 'Port 8022\n#PasswordAuthentication yes\nPrintMotd yes\n' >"$PREFIX/etc/ssh/sshd_config"
mkdir -p "$HOME/.termux" "$HOME/.config/vivac"
printf 'background=#000000\n' >"$HOME/.termux/colors.properties"
printf 'theme=metropolis\nprompt_user=someone\nlanguage=es\n' >"$HOME/.config/vivac/settings"
printf 'alias ll="ls -l"\n' >"$HOME/.bashrc"
printf 'extra-keys = [[ESC, TAB]]\nterminal-cursor-style = block\n' >"$HOME/.termux/termux.properties"

# The font comes from the network: a fake curl hands over a fixture, whose
# checksum stands in for the pinned one; a wrong checksum installs nothing.
fakes="$sandbox/fakes"
mkdir -p "$fakes"
printf 'not really a font\n' >"$sandbox/font.fixture"
python3 -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1],"w").write(sys.argv[2],"ttf/FiraCode-Regular.ttf")' "$sandbox/font.zip" "$sandbox/font.fixture"
cat >"$fakes/getprop" <<'FAKE'
#!/usr/bin/env bash
[[ "$1" == ro.product.model ]] && echo 'Pixel 8'
FAKE
chmod +x "$fakes/getprop"
cat >"$fakes/curl" <<'FAKE'
#!/usr/bin/env bash
out=""
while (($#)); do [[ "$1" == -o ]] && { out="$2"; shift; }; shift; done
printf 'called\n' >>"$CURL_LOG"
cp -- "$FONT_FIXTURE" "$out"
FAKE
chmod +x "$fakes/curl"
export PATH="$fakes:$PATH" CURL_LOG="$sandbox/curl.log" FONT_FIXTURE="$sandbox/font.zip"
VIVAC_FONT_SHA256="$(sha256sum "$sandbox/font.fixture" | cut -d' ' -f1)"
export VIVAC_FONT_SHA256

snapshot() { (cd "$sandbox" && find . -printf '%p %y %l\n' | LC_ALL=C sort && find . -type f -exec md5sum {} + | LC_ALL=C sort); }

# Dry run: nothing changes.
before="$(snapshot)"
bash "$deploy" --dry-run >/dev/null || fail "dry run failed"
[[ "$(snapshot)" == "$before" ]] || fail "dry run changed files"

bash "$deploy" >/dev/null || fail "deploy failed"
for tool in "$repo_root"/bin/*; do
	name="$(basename "$tool")"
	[[ "$(readlink -- "$PREFIX/bin/$name")" == "$tool" ]] || fail "$name not linked into \$PREFIX/bin"
done
backup="$(find "$HOME/.local/state/vivac/backups" -type f -name vivac-facts)"
[[ -n "$backup" && "$(cat "$backup")" == 'old mine' ]] || fail "the user's own vivac-facts was not backed up"

boot="$HOME/.termux/boot/vivac"
[[ -x "$boot" ]] || fail "boot script missing or not executable"
grep -q 'termux-wake-lock' "$boot" || fail "boot script takes no wake lock"
grep -q 'sshd' "$boot" || fail "boot script does not start sshd"

conf="$PREFIX/etc/ssh/sshd_config"
grep -qx 'PasswordAuthentication no' "$conf" || fail "sshd still accepts passwords"
grep -qx 'PrintMotd yes' "$conf" || fail "deploy lost the user's sshd settings"
[[ "$(grep -c '^PasswordAuthentication' "$conf")" == 1 ]] || fail "PasswordAuthentication set twice"

colors="$HOME/.termux/colors.properties"
grep -qx 'background=#0b100f' "$colors" || fail "Termux background is not the theme's terminal background: $(cat "$colors")"
grep -qx 'foreground=#c9c9c8' "$colors" || fail "Termux foreground is not the theme's"
grep -qx 'cursor=#cccccc' "$colors" || fail "Termux cursor is not kitty's"
grep -qx 'color1=#cc0403' "$colors" || fail "Termux red is not kitty's"
grep -qx 'color12=#1a8fff' "$colors" || fail "Termux bright blue is not kitty's"
[[ "$(grep -c '^color[0-9]*=' "$colors")" == 16 ]] || fail "Termux does not carry kitty's 16 colours"
cmp -s "$HOME/.termux/font.ttf" "$sandbox/font.fixture" || fail "Termux does not wear Fira Code"
props="$HOME/.termux/termux.properties"
grep -qx 'terminal-cursor-style = bar' "$props" || fail "Termux cursor is not kitty's beam"
grep -qx 'terminal-cursor-blink-rate = 500' "$props" || fail "Termux cursor does not blink like kitty's"
grep -qx 'extra-keys = \[\[ESC, TAB\]\]' "$props" || fail "deploy lost the user's termux.properties"
[[ "$(grep -c '^terminal-cursor-style' "$props")" == 1 ]] || fail "cursor style set twice"
# The prompt Linux's bash wears: user in salmon, host in olive, directory in sand.
grep -qx 'alias ll="ls -l"' "$HOME/.bashrc" || fail "deploy lost the user's .bashrc"
grep -qF '\[\e[38;5;203m\]someone\[\e[0m\]@\[\e[38;5;143m\]pixel-8\[\e[0m\] \[\e[38;5;180m\]\w\[\e[0m\] \$ ' "$HOME/.bashrc" ||
    fail "Termux prompt is not Linux's: $(grep PS1 "$HOME/.bashrc")"
[[ "$(grep -c '>>> vivac prompt' "$HOME/.bashrc")" == 1 ]] || fail "prompt block written twice"
grep -q '\.bashrc' "$HOME/.bash_profile" || fail "a login shell would not read .bashrc"
# The home-screen widget's button for the computer's screen, named in the
# phone's language, running vivac's script.
widget="$HOME/.shortcuts/tasks/Pantalla vivac"
[[ "$(readlink -- "$widget")" == "$repo_root/shortcuts/vivac-screen" ]] || fail "the widget has no button for the computer's screen"
[[ -x "$repo_root/shortcuts/vivac-screen" ]] || fail "the widget's script is not executable"
grep -q 'Written by vivac' "$colors" || fail "colours file not marked as vivac's"
mine="$(find "$HOME/.local/state/vivac/backups" -type f -name colors.properties)"
[[ -n "$mine" && "$(cat "$mine")" == 'background=#000000' ]] || fail "the user's own colours were not backed up"

: >"$CURL_LOG"
after="$(snapshot)"
bash "$deploy" >/dev/null || fail "second deploy failed"
[[ ! -s "$CURL_LOG" ]] || fail "second deploy downloaded the font again"
[[ "$(snapshot)" == "$after" ]] || fail "second deploy is not idempotent"

# A phone with no vivac settings file (a fresh Termux) still gets the
# colours, from the default palette: the missing file is not an error.
rm -rf -- "$HOME" && mkdir -p "$HOME"
out="$(bash "$deploy" 2>&1)" || fail "deploy without a settings file failed: $out"
grep -q 'Written by vivac' "$HOME/.termux/colors.properties" 2>/dev/null ||
    fail "deploy without a settings file wrote no Termux colours"
grep -q '^background=#[0-9a-f]\{6\}$' "$HOME/.termux/colors.properties" ||
    fail "default palette gave no terminal background"

# A font that does not match the pinned checksum is not installed, and the
# deploy carries on.
rm -rf -- "$HOME" && mkdir -p "$HOME"
VIVAC_FONT_SHA256=0000 bash "$deploy" >/dev/null 2>&1 || fail "a bad font download stopped the deploy"
[[ ! -e "$HOME/.termux/font.ttf" ]] || fail "a font with the wrong checksum was installed"
