#!/usr/bin/env bash
set -Eeuo pipefail

# Every binary or image file that ships in this repository must be listed in
# data/asset-manifest.tsv with its content hash and intrinsic dimensions. The
# gate fails on three classes of problem: a file present but unlisted, a listed
# file whose bytes changed, and a listed file that no longer exists.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
manifest="${ASSET_MANIFEST:-$repo_root/data/asset-manifest.tsv}"
update=false

usage() {
	cat <<'USAGE'
Usage: scripts/check-asset-manifest.sh [--update]

Verifies data/asset-manifest.tsv against the assets in the working tree.
  --update  rewrite the manifest from the current tree instead of checking it
USAGE
}

while (($#)); do
	case "$1" in
	--update) update=true ;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		printf 'Unknown option: %s\n' "$1" >&2
		usage >&2
		exit 2
		;;
	esac
	shift
done

asset_root="${ASSET_ROOT:-$repo_root}"

# Discover assets by content, not by extension: `file` decides, exactly as the
# unexpected-binary stage of check.sh does, so the two stages cannot disagree.
discover() {
	find "$asset_root" \
		\( -path "$asset_root/.git" -o -path "$asset_root/.vm-test" -o -path "$asset_root/.vm-image" -o -path "$asset_root/dist" -o -path "$asset_root/.audit" -o -path "$asset_root/.atl" -o -path "$asset_root/data" \) -prune -o \
		-type f -print0 |
		while IFS= read -r -d '' file; do
			case "$(file -b --mime-type -- "$file")" in
			image/* | video/mp4 | application/pdf | font/* | application/octet-stream)
				printf '%s\n' "${file#"$asset_root"/}"
				;;
			esac
		done | LC_ALL=C sort
}

dimensions() {
	python3 - "$1" <<'PY'
import pathlib, re, struct, sys

path = pathlib.Path(sys.argv[1])
raw = path.read_bytes()

if raw[:8] == b"\x89PNG\r\n\x1a\n":
    width, height = struct.unpack(">II", raw[16:24])
    print(f"{width}x{height}")
elif raw[:6] in (b"GIF87a", b"GIF89a"):
    # The logical screen descriptor follows the six-byte magic: width and
    # height as little-endian 16-bit numbers, which is the frame size every
    # GIF in assets/ is encoded at.
    width, height = struct.unpack_from("<HH", raw, 6)
    print(f"{width}x{height}")
elif b"<svg" in raw[:4096]:
    head = raw[:4096].decode("utf-8", "replace")
    match = re.search(r'viewBox="\s*[\d.+-]+\s+[\d.+-]+\s+([\d.]+)\s+([\d.]+)', head)
    if match:
        width, height = match.group(1), match.group(2)
    else:
        width = (re.search(r'\bwidth="([\d.]+)', head) or [None, "unknown"])[1]
        height = (re.search(r'\bheight="([\d.]+)', head) or [None, "unknown"])[1]
    def tidy(value):
        # "1200" and "1200.0" both render as 1200; a non-numeric value passes through.
        try:
            number = float(value)
        except ValueError:
            return value
        return str(int(number)) if number.is_integer() else str(number)

    print(f"{tidy(width)}x{tidy(height)}")
elif raw[4:8] == b"ftyp":
    # MP4 keeps the frame size in each track header, as two 16.16 fixed-point
    # numbers at the end of the box. The file is walked rather than handed to
    # ffprobe so this gate keeps depending on nothing but python: an audio
    # track reports 0x0, so the first track reporting a real size wins.
    def boxes(start, end):
        at = start
        while at + 8 <= end:
            size = struct.unpack_from(">I", raw, at)[0]
            kind = raw[at + 4:at + 8]
            body = at + 8
            if size == 1:
                size = struct.unpack_from(">Q", raw, body)[0]
                body += 8
            if size == 0:
                size = end - at
            if size < 8:
                break
            yield kind, body, at + size
            at += size

    frame = "unknown"
    for kind, body, stop in boxes(0, len(raw)):
        if kind != b"moov":
            continue
        for track_kind, track, track_end in boxes(body, stop):
            if track_kind != b"trak":
                continue
            for header_kind, header, _ in boxes(track, track_end):
                if header_kind != b"tkhd":
                    continue
                # 76 bytes of timing, layer and matrix sit in front of the size
                # in a version 0 header, 88 in a version 1 one whose time
                # fields are 64 bits wide.
                at = header + (88 if raw[header] == 1 else 76)
                width, height = struct.unpack_from(">II", raw, at)
                if width >> 16 and height >> 16:
                    frame = f"{width >> 16}x{height >> 16}"
    print(frame)
else:
    print("n/a")
PY
}

emit_row() {
	local file="$1" absolute="$asset_root/$1"
	printf '%s\t%s\t%s\t%s\n' \
		"$file" \
		"$(sha256sum -- "$absolute" | cut -d' ' -f1)" \
		"$(file -b --mime-type -- "$absolute")" \
		"$(dimensions "$absolute")"
}

if $update; then
	{
		printf '# path\tsha256\ttype\tdimensions\n'
		while IFS= read -r file; do emit_row "$file"; done < <(discover)
	} >"$manifest"
	printf 'asset manifest written: %s\n' "$manifest"
	exit 0
fi

[[ -f "$manifest" ]] || {
	printf 'asset manifest missing: %s\n' "$manifest" >&2
	exit 1
}

status=0

# 1. Listed file missing from the tree, or its bytes changed.
while IFS=$'\t' read -r file expected _type _dimensions; do
	[[ "$file" == \#* || -z "$file" ]] && continue
	if [[ ! -f "$asset_root/$file" ]]; then
		printf 'asset listed in manifest but missing from tree: %s\n' "$file" >&2
		status=1
		continue
	fi
	actual="$(sha256sum -- "$asset_root/$file" | cut -d' ' -f1)"
	if [[ "$actual" != "$expected" ]]; then
		printf 'asset hash mismatch: %s\n  manifest %s\n  actual   %s\n' "$file" "$expected" "$actual" >&2
		status=1
	fi
done <"$manifest"

# 2. Asset present in the tree but absent from the manifest.
listed="$(mktemp)"
trap 'rm -f -- "$listed"' EXIT
awk -F'\t' '!/^#/ && NF { print $1 }' "$manifest" | LC_ALL=C sort >"$listed"
while IFS= read -r file; do
	if ! grep -Fxq -- "$file" "$listed"; then
		printf 'unlisted asset found in tree: %s\n' "$file" >&2
		status=1
	fi
done < <(discover)

((status == 0)) && printf 'asset manifest: verified\n'
exit "$status"
