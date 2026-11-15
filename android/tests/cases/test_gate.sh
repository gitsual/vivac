#!/usr/bin/env bash
set -Eeuo pipefail

# vivac-gate: the only command Hermes' SSH key may run on the phone
# (authorized_keys command="vivac-gate"). It reads $SSH_ORIGINAL_COMMAND and
# lets through exactly two things: "vivac-mcp" (execs the MCP server) and
# "vivac-photo-get NAME" for a NAME shaped like the photos vivac-mcp takes,
# which streams that file from the photo folder. Everything else (a shell, a
# path, ../, another file name, no command) is refused with exit 1 and
# nothing on stdout.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
gate="$repo_root/bin/vivac-gate"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-gate.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/photos" "$sandbox/bin"
printf 'JPEGDATA' >"$sandbox/photos/photo-20261115-123456.jpg"
printf 'secret' >"$sandbox/other.txt"
printf '#!/usr/bin/env bash\necho mcp-ran\n' >"$sandbox/bin/vivac-mcp"
chmod +x "$sandbox/bin/vivac-mcp"
export VIVAC_PHOTO_DIR="$sandbox/photos" VIVAC_MCP="$sandbox/bin/vivac-mcp"

g() { SSH_ORIGINAL_COMMAND="$1" bash "$gate"; }

[[ "$(g vivac-mcp)" == mcp-ran ]] || fail "vivac-mcp not let through"
[[ "$(g 'vivac-photo-get photo-20261115-123456.jpg')" == JPEGDATA ]] || fail "photo not streamed"

for bad in '' 'sh' 'bash -i' 'vivac-mcp; sh' 'vivac-mcp extra' 'cat /etc/passwd' \
	'vivac-photo-get ../other.txt' 'vivac-photo-get other.txt' \
	'vivac-photo-get photo-20261115-123456.jpg extra' 'vivac-photo-get photo-2026111-123456.jpg' \
	'vivac-photo-get /abs/photo-20261115-123456.jpg' 'vivac-photo-get photo-20261115-999999.jpg'; do
	if out="$(g "$bad" 2>/dev/null)"; then fail "gate let through: '$bad'"; fi
	[[ -z "$out" ]] || fail "gate wrote to stdout for '$bad'"
done
if out="$(SSH_ORIGINAL_COMMAND='' bash "$gate" 2>/dev/null)"; then fail "gate let an empty command through"; fi
