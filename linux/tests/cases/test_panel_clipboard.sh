#!/usr/bin/env bash
# The fakes are shell source written out literally: their $ expands when they run.
# shellcheck disable=SC2016
set -Eeuo pipefail

# vivac-panel clipboard, the backend without a screen: cliphist's list is read
# into entries (text with its lines and characters, pictures with their size),
# what looks like a secret is flagged and masked and never matched by the
# filter, the filter ignores case and accents, copying decodes the entry into
# wl-copy (with its picture type), and forgetting one or all goes through
# cliphist delete / wipe. Without cliphist the list is empty and says why.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-clip.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/bin" "$sandbox/data" "$sandbox/run"

# A cliphist that keeps its history in $SANDBOX/db (id<TAB>preview) and each
# entry's bytes in $SANDBOX/data/<id>.
cat >"$sandbox/bin/cliphist" <<'FAKE'
#!/usr/bin/env bash
db="$SANDBOX/db"
case "$1" in
list) cat "$db" ;;
decode)
	id="${2:-}"
	[[ -n "$id" ]] || { read -r line; id="${line%%$'\t'*}"; }
	cat "$SANDBOX/data/$id" ;;
delete)
	read -r line
	id="${line%%$'\t'*}"
	grep -v "^$id"$'\t' "$db" >"$db.new" || true
	mv "$db.new" "$db" ;;
wipe) : >"$db" ;;
esac
FAKE
cat >"$sandbox/bin/wl-copy" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$SANDBOX/copy-args"
cat >"$SANDBOX/copied"
FAKE
chmod +x "$sandbox/bin/"*

add() { # id kind(text|image) payload preview
	printf '%s' "$3" >"$sandbox/data/$1"
	printf '%s\t%s\n' "$1" "$4" >>"$sandbox/db"
}
card=4111111111111111
add 9 text "$(printf 'last words\nsecond line\nthird')" 'last words second line third'
add 8 text 'password=hunter2hunter2' 'password=hunter2hunter2'
add 7 text 'ghp_abcdefghijklmnopqrstuvwxyz0123456789' 'ghp_abcdefghijklmnopqrstuvwxyz0123456789'
add 6 text "$card" "$card"
add 5 text 'Tr0ub4dor&3xKq' 'Tr0ub4dor&3xKq'
add 4 text 'Canción de cuna' 'Canción de cuna'
add 3 text 'https://example.org/a/b?c=1' 'https://example.org/a/b?c=1'
add 2 text "$(printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----')" '-----BEGIN OPENSSH PRIVATE KEY----- AAAA'
printf '\x89PNG\r\n\x1a\nfakepng' >"$sandbox/data/1"
printf '1\t[[ binary data 12 KiB png 800x600 ]]\n' >>"$sandbox/db"

py() {
	PATH="$sandbox/bin:$PATH" SANDBOX="$sandbox" XDG_RUNTIME_DIR="$sandbox/run" VIVAC_LANG=en \
		/usr/bin/python3 -I -c "import sys; sys.path.insert(0, '$repo_root/lib'); from vivacpanel import clipboard as c
$1"
}

# --- the list ------------------------------------------------------------------------------------------------
out="$(py '
es = {e.id: e for e in c.entries()}
assert sorted(es) == ["1","2","3","4","5","6","7","8","9"], sorted(es)
assert [e.id for e in c.entries()][0] == "9", "newest first as cliphist lists"
t = es["9"]
assert (t.kind, t.lines, t.chars, t.first) == ("text", 3, 28, "last words"), t
assert not t.private
im = es["1"]
assert (im.kind, im.width, im.height, im.size) == ("image", 800, 600, "12 KiB"), im
assert not im.private
print("ok")')" || fail "the list: $out"

# --- secrets -------------------------------------------------------------------------------------------------
out="$(py '
es = {e.id: e for e in c.entries()}
for i in "2 5 6 7 8".split():
    assert es[i].private, ("not flagged", i)
for i in "1 3 4 9".split():
    assert not es[i].private, ("flagged", i)
assert c.shown(es["8"]) == c.MASK and "hunter" not in c.shown(es["8"])
assert c.shown(es["4"]) == "Canción de cuna"
for text, secret in [("sk-ant-api03-AbCdEf0123456789AbCdEf", True), ("AKIAIOSFODNN7EXAMPLE", True),
                     ("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVP", True),
                     ("api_key: abc123", True), ("Authorization: Bearer abcdef1234", True),
                     ("4111 1111 1111 1111", True), ("4111 1111 1111 1112", False),
                     ("hello world", False), ("/home/user/file.txt", False), ("0123456789", False),
                     ("a3f5c8e1b2d4f6a8c0e2b4d6f8a0c2e4b6d8f0a2", False)]:
    assert c.looks_secret(text) is secret, (text, secret)
print("ok")')" || fail "secrets: $out"

# --- the filter: case and accents ignored, secrets and pictures never match --------------------------------
out="$(py '
es = c.entries()
ids = lambda n: sorted(e.id for e in c.filtered(es, n))
assert ids("") == ["1","2","3","4","5","6","7","8","9"]
assert ids("CANCION") == ["4"], ids("CANCION")
assert ids("example.org") == ["3"]
assert ids("hunter") == [], "a secret matched the filter"
assert ids("ghp_") == []
assert ids("png") == [], "a picture matched a text filter"
print("ok")')" || fail "filter: $out"

# --- kinds, for the filter chips ------------------------------------------------------------------------------
out="$(py '
es = c.entries()
kinds = {e.id: c.kind_of(e) for e in es}
assert kinds == {"9":"text","8":"private","7":"private","6":"private","5":"private","4":"text","3":"link","2":"private","1":"image"}, kinds
n = c.counts(es)
assert n == {"all":9,"text":2,"link":1,"image":1,"private":5}, n
assert [e.id for e in c.by_kind(es, "link")] == ["3"]
assert [e.id for e in c.by_kind(es, "private")] == ["8","7","6","5","2"]
assert len(c.by_kind(es, "all")) == 9
assert [e.id for e in c.by_kind(c.by_kind(es, "text"), "all")] == ["9","4"]
print("ok")')" || fail "kinds: $out"

# --- copying -------------------------------------------------------------------------------------------------
py 'c.copy(next(e for e in c.entries() if e.id == "9"))' || fail 'copy failed'
[[ "$(cat "$sandbox/copied")" == "$(printf 'last words\nsecond line\nthird')" ]] || fail "copy put the wrong text: $(cat "$sandbox/copied")"
py 'c.copy(next(e for e in c.entries() if e.id == "1"))' || fail 'copy of a picture failed'
grep -q 'image/png' "$sandbox/copy-args" || fail "a picture was copied without its type: $(cat "$sandbox/copy-args")"
head -c 4 "$sandbox/copied" | grep -q PNG || fail 'the picture bytes were altered'

# --- forgetting ----------------------------------------------------------------------------------------------
py 'c.forget(next(e for e in c.entries() if e.id == "8"))' || fail 'forget failed'
[[ "$(cut -f1 "$sandbox/db" | tr '\n' ' ')" == '9 7 6 5 4 3 2 1 ' ]] || fail "forget removed the wrong entries: $(cut -f1 "$sandbox/db" | tr '\n' ' ')"
py 'c.forget_all()' || fail 'forget_all failed'
[[ ! -s "$sandbox/db" ]] || fail 'forget_all left entries'

# --- thumbnails go to the runtime dir, never beside the history ---------------------------------------------
add 1 image x '[[ binary data 12 KiB png 800x600 ]]'
printf '\x89PNG\r\n\x1a\nfakepng' >"$sandbox/data/1"
out="$(py '
e = c.entries()[0]
p = c.thumbnail(e)
assert str(p).startswith("'"$sandbox"'/run/"), p
assert p.read_bytes().startswith(b"\x89PNG")
print("ok")')" || fail "thumbnail: $out"

# --- no cliphist: an empty list that says why ---------------------------------------------------------------
out="$(PATH="/usr/bin-none:/nonexistent" /usr/bin/python3 -I -c "import sys; sys.path.insert(0, '$repo_root/lib'); from vivacpanel import clipboard as c
assert c.entries() == [] and not c.available(); print('ok')")" || fail "without cliphist: $out"

printf 'clipboard: list parsed (text lines/chars, picture size), 5 secret shapes masked and 6 non-secrets left alone, filter ignores case/accents and never matches secrets, copy keeps picture type, forget one/all, thumbnails in the runtime dir, kinds and counts for the filter chips, no cliphist\n'
