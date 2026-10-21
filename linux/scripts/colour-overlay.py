"""Remap palette colours inside owner-structured configs, colours only.

Each owner file is snapshotted once (a timestamped backup and a pristine
copy). Every later run renders map(pristine, base palette -> chosen palette) in
a single pass, so palettes never chain and returning to the original palette
restores the original bytes. A file whose bytes differ from what the last run
wrote was edited by its owner and is skipped with a warning until --rebase.
Colours that belong to no catalogue palette, or that map to two different
colours, are left alone. Palette values come from the catalogue files only.
"""

import argparse
import hashlib
import re
import shutil
import sys
import tempfile
import time
from pathlib import Path

HEX = re.compile(rb"#([0-9A-Fa-f]{6})([0-9A-Fa-f]{2})?(?![0-9A-Za-z])")
RGB = re.compile(rb"(\brgba?\(\s*)(\d{1,3})(\s*,\s*)(\d{1,3})(\s*,\s*)(\d{1,3})(?!\d)")
PALETTE_LINE = re.compile(r"^((?:COLOR|TERMINAL)_[A-Z_]+)=([0-9A-Fa-f]{6})\s*$")


def read_palette(path):
    palette = {}
    for line in Path(path).read_text().splitlines():
        found = PALETTE_LINE.match(line)
        if found:
            palette[found.group(1)] = found.group(2).upper()
    return palette


def catalogue(data):
    """Every palette, the default first, then the rest by name."""
    palettes = [read_palette(Path(data) / "theme.conf")]
    palettes += [read_palette(p) for p in sorted((Path(data) / "themes").glob("*.conf"))]
    return palettes


def triple(hexvalue):
    return tuple(int(hexvalue[i : i + 2], 16) for i in (0, 2, 4))


def hits(content, palette):
    values = set(palette.values())
    triples = {triple(v) for v in values}
    count = sum(m.group(1).decode().upper() in values for m in HEX.finditer(content))
    count += sum(tuple(int(m.group(i)) for i in (2, 4, 6)) in triples for m in RGB.finditer(content))
    return count


def detect_base(content, palettes):
    best = max(palettes, key=lambda p: hits(content, p))  # first wins a tie
    return best if hits(content, best) else None


def colour_map(base, chosen, prefer):
    groups = {}
    for token, value in base.items():
        groups.setdefault(value, []).append(token)
    mapping = {}
    for value, tokens in groups.items():
        targets = {chosen[t] for t in tokens if t in chosen}
        if len(targets) > 1:
            targets = {chosen[t] for t in tokens if t in chosen and t.startswith(prefer)}
        if len(targets) == 1:
            mapping[value] = targets.pop()
    return mapping


def remap(content, mapping):
    triples = {triple(k): triple(v) for k, v in mapping.items()}

    def hexed(m):
        new = mapping.get(m.group(1).decode().upper())
        if new is None:
            return m.group(0)
        new = new.encode()
        new = new.lower() if m.group(1).islower() else new
        return b"#" + new + (m.group(2) or b"")

    def rgbed(m):
        new = triples.get(tuple(int(m.group(i)) for i in (2, 4, 6)))
        if new is None:
            return m.group(0)
        return b"".join([m.group(1), str(new[0]).encode(), m.group(3), str(new[1]).encode(), m.group(5), str(new[2]).encode()])

    return RGB.sub(rgbed, HEX.sub(hexed, content))


def sha(content):
    return hashlib.sha256(content).hexdigest()


def write_atomic(target, content):
    with tempfile.NamedTemporaryFile(dir=target.parent, prefix=target.name + ".", delete=False) as tmp:
        tmp.write(content)
    shutil.copymode(target, tmp.name)
    Path(tmp.name).replace(target)


def write_state(path, content):
    """State files are replaced whole: a crash leaves the old file or the new one."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=path.name + ".", delete=False) as tmp:
        tmp.write(content)
    Path(tmp.name).replace(path)


def apply_file(target, keydir, palettes, chosen, prefer, rebase):
    if target.is_symlink():
        return "skipped (symlink, not an owner file)"
    if not target.is_file():
        return "skipped (absent)"
    if rebase:
        shutil.rmtree(keydir, ignore_errors=True)
    current = target.read_bytes()
    pristine, last = keydir / "pristine", keydir / "last"
    if pristine.exists() and not last.exists():
        # An interrupted first run: no swap was ever confirmed, so the file as it
        # is now is the starting point (the backup still holds the first bytes).
        shutil.rmtree(keydir / "pristine", ignore_errors=True)
        pristine.unlink(missing_ok=True)
    if pristine.exists():
        source = pristine.read_bytes()
        if sha(current) not in (last.read_text().strip(), sha(source)):
            print(f"colour-overlay: warning: {target} was edited since the last swap; skipped (use --rebase)", file=sys.stderr)
            return "skipped (edited)"
    else:
        source = current
    base = detect_base(source, palettes)
    if base is None:
        return "unchanged (no palette colours)"
    result = remap(source, colour_map(base, chosen, prefer))
    if result == current:
        return "unchanged"
    if not pristine.exists():
        backup = keydir / time.strftime("backup-%Y%m%dT%H%M%S")
        backup.mkdir(parents=True, exist_ok=True)
        shutil.copy2(target, backup / target.name)
        write_state(pristine, current)
    # `last` is written before the file: whichever write is cut short, the file
    # on disk is either the pristine bytes or the bytes `last` names.
    write_state(last, (sha(result) + "\n").encode())
    write_atomic(target, result)
    return "applied"


def main():
    ap = argparse.ArgumentParser()
    for name in ("data", "map", "theme-file", "config-dir", "state"):
        ap.add_argument("--" + name, required=True)
    ap.add_argument("--rebase", action="store_true")
    args = ap.parse_args()
    palettes = catalogue(args.data)
    chosen = read_palette(args.theme_file)
    config = Path(args.config_dir)
    failures = []
    for line in Path(args.map).read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        tool, pattern, prefer = line.split("\t")
        matches = sorted(config.glob(pattern)) or ([] if "*" in pattern else [config / pattern])
        for target in matches:
            relative = target.relative_to(config)
            keydir = Path(args.state) / str(relative).replace("/", "__")
            try:
                outcome = apply_file(target, keydir, palettes, chosen, prefer, args.rebase)
            except OSError as error:
                failures.append(str(relative))
                print(f"colour-overlay: error: {relative}: {error}", file=sys.stderr)
                continue
            print(f"colour-overlay: {tool}: {relative}: {outcome}")
    if failures:
        print(f"colour-overlay: {len(failures)} file(s) failed: {', '.join(failures)}", file=sys.stderr)
        return 1
    return 0


sys.exit(main())
