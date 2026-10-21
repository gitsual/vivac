"""A palette from a picture, under the corpus's rules.

    theme-from-image.py IMAGE --dir DIR [--name NAME] [--dry-run]

Reads a PNG or JPEG, and writes DIR/NAME.conf (a palette in the format of
data/themes/*.conf) with the picture beside it as NAME.png or NAME.jpg, its
wallpaper. On success the name is the one line printed on stdout; what
happened is said on stderr. --dry-run writes nothing and prints the palette
as truecolour swatches instead.

No colour is invented. Every role takes a colour from data/palette-corpus.tsv:
the picture only decides which. The Windows half (windows/lib/Picture.psm1)
runs the same steps with the same constants, so the same picture gives the
same file on both systems; shared/fixtures/theme-from-image holds one picture
and the palette both halves must make from it.

The steps:
  1. Samples: a grid of at most 64 x 64 points, the centre of each cell, read
     straight from the decoded pixels (no resampling, which no two decoders
     do alike). Points under half opacity are skipped.
  2. Distance: redmean, the measure the catalogue gate already uses, kept in
     integers (512 times its square) so both halves compare exactly.
  3. Ground (COLOR_BG): every sample votes for the nearest dark corpus colour
     (role deep or base); the most voted wins. If no complete palette can be
     built on it, the next most voted is tried.
  4. Text, then the rest, each from the corpus rows of its role, each the
     first in its order that clears its floor against the ground (the
     catalogue gate's floors: 7:1 text, 4.5:1 dim text, 3:1 accent).
  5. The accent is the picture's most salient colour: samples vote weighted
     by their chroma, and an accent whose root is a rupture (distance >= 5 in
     root-distance.tsv) from the ground's root is passed over, since a
     rupture would need a mediator nobody chose; so is one of the ground's
     own root, since a theme pairs two roots and the matrix has no such row.
  6. Urgent, info, ok and muted keep their meaning: the corpus colour nearest
     the shipped signal colour that clears the floor and stays apart from the
     accent (the gate's 60 for info, and for muted against dim text).
"""

import argparse
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

GRID = 64
OPAQUE = 128
# The catalogue gate's floors (tests/cases/test_theme_catalogue.sh), and 3:1
# for the signal colours, which are read as marks on the ground too.
TEXT_FLOOR = 7.0
DIM_FLOOR = 4.5
MARK_FLOOR = 3.0
# Surfaces are ground, not ink: under 3:1 against the base, and text on them
# still clears the dim-text floor.
SURFACE_CEILING = 3.0
# The terminal keeps a neutral ground (theme.conf says why): a deep colour
# whose channels lie within this much of each other.
NEUTRAL = 24
# The gate's separation of 60 (redmean), as 512 times its square.
APART = 512 * 60 * 60
RUPTURE = 5
ANCHORS = {"COLOR_URGENT": "BD6161", "COLOR_INFO": "6CA4B1", "COLOR_OK": "55A185", "COLOR_MUTED": "979367"}
KEYS = (
    "COLOR_BG", "COLOR_FG", "COLOR_FG_DIM", "COLOR_SURFACE", "COLOR_SURFACE_ALT", "COLOR_ACCENT",
    "COLOR_MUTED", "COLOR_URGENT", "COLOR_INFO", "COLOR_OK", "COLOR_BORDER_INACTIVE",
    "TERMINAL_BG", "TERMINAL_FG",
)
NAME = re.compile(r"[a-z][a-z0-9-]{0,31}")


class Refused(Exception):
    """A user-facing failure: an i18n key and its arguments."""

    def __init__(self, key, *args):
        super().__init__(key)
        self.key, self.args_ = key, args


# --- i18n (lib/i18n.sh's tables and rules, as vivac-link reads them) ------------------------


def read_kv(path):
    values = {}
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
    except OSError:
        return values
    for line in lines:
        if not line.strip() or line.lstrip().startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def session_language(settings):
    short = re.compile(r"[a-z]{2,3}")
    for candidate in (os.environ.get("VIVAC_LANG", ""), read_kv(settings).get("language", ""), os.environ.get("LANG", "")):
        if not candidate or candidate == "auto":
            continue
        candidate = re.split(r"[._@]", candidate)[0]
        if short.fullmatch(candidate):
            return candidate
    return "en"


class Text:
    def __init__(self, directory, language):
        self.reference = read_kv(Path(directory) / "en.conf")
        self.table = read_kv(Path(directory) / f"{language}.conf") if language != "en" else {}

    def get(self, key, *args):
        text = self.table.get(key) or self.reference.get(key) or f"[{key}]"
        for index, arg in enumerate(args, 1):
            text = text.replace("{%d}" % index, str(arg))
        return text


# --- decoding ------------------------------------------------------------------------------


def kind_of(path):
    with open(path, "rb") as handle:
        head = handle.read(8)
    if head == b"\x89PNG\r\n\x1a\n":
        return "png"
    if head[:3] == b"\xff\xd8\xff":
        return "jpg"
    return None


def decode_png(data):
    """Width, height and RGBA rows of an 8- or 16-bit, non-interlaced PNG. Gamma and
    colour profile chunks are ignored, as the Windows decoder is told to ignore them."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    pos, idat, palette, alpha = 8, bytearray(), None, None
    width = height = depth = colour = interlace = None
    while pos + 8 <= len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            width, height, depth, colour, _, _, interlace = struct.unpack(">IIBBBBB", body)
        elif kind == b"PLTE":
            palette = body
        elif kind == b"tRNS":
            alpha = body
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
    if width is None or interlace != 0 or depth not in (8, 16) or colour not in (0, 2, 3, 4, 6):
        return None
    if colour == 3 and (depth != 8 or palette is None):
        return None
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[colour]
    bpp = channels * depth // 8
    stride = width * bpp
    raw = zlib.decompress(bytes(idat))
    rows, previous = [], bytearray(stride)
    for y in range(height):
        start = y * (stride + 1)
        kind, line = raw[start], bytearray(raw[start + 1:start + 1 + stride])
        if kind == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 255
        elif kind == 2:
            for i in range(stride):
                line[i] = (line[i] + previous[i]) & 255
        elif kind == 3:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + previous[i]) >> 1)) & 255
        elif kind == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = previous[i]
                c = previous[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line)
        previous = line
    step = depth // 8

    def pixel(x, y):
        line = rows[y]
        values = [line[(x * channels + k) * step] for k in range(channels)]  # high byte of 16-bit
        if colour == 0:
            return values[0], values[0], values[0], 255
        if colour == 4:
            return values[0], values[0], values[0], values[1]
        if colour == 2:
            return values[0], values[1], values[2], 255
        if colour == 3:
            index = values[0]
            r, g, b = palette[index * 3:index * 3 + 3]
            a = alpha[index] if alpha is not None and index < len(alpha) else 255
            return r, g, b, a
        return values[0], values[1], values[2], values[3]

    return width, height, pixel


def decode_pixdata(path):
    """Any picture gdk-pixbuf reads (it comes with librsvg), through its GdkPixdata dump:
    a 24-byte header, then raw or run-length 8-bit RGB or RGBA rows."""
    tool = shutil.which("gdk-pixbuf-pixdata")
    if not tool:
        return None
    with tempfile.TemporaryDirectory() as work:
        out = Path(work) / "picture.pixdata"
        done = subprocess.run([tool, str(path), str(out)], capture_output=True, timeout=120)
        if done.returncode != 0 or not out.exists():
            return None
        data = out.read_bytes()
    if len(data) < 24 or data[:4] != b"GdkP":
        return None
    _, _, kind, stride, width, height = struct.unpack(">6I", data[:24])
    channels = 4 if kind & 0xFF == 2 else 3
    body = data[24:]
    if kind >> 24 == 2:  # run-length: a count byte, then one pixel repeated or that many literal
        flat, pos = bytearray(), 0
        while pos < len(body) and len(flat) < width * height * channels:
            count = body[pos]
            pos += 1
            if count & 128:
                flat += body[pos:pos + channels] * (count - 128)
                pos += channels
            else:
                flat += body[pos:pos + channels * count]
                pos += channels * count
        body, stride = bytes(flat), width * channels

    def pixel(x, y):
        at = y * stride + x * channels
        r, g, b = body[at], body[at + 1], body[at + 2]
        return r, g, b, body[at + 3] if channels == 4 else 255

    return width, height, pixel


def decode(path):
    """gdk-pixbuf first (fast, PNG and JPEG); a pure-Python PNG reader when it is absent.
    VIVAC_PICTURE_DECODER=python|pixbuf forces one, for the tests."""
    forced = os.environ.get("VIVAC_PICTURE_DECODER", "")
    if forced != "python":
        decoded = decode_pixdata(path)
        if decoded or forced == "pixbuf":
            return decoded
    if kind_of(path) == "png":
        return decode_png(Path(path).read_bytes())
    return None


def samples(width, height, pixel):
    nx, ny = min(GRID, width), min(GRID, height)
    out = []
    for j in range(ny):
        y = (2 * j + 1) * height // (2 * ny)
        for i in range(nx):
            x = (2 * i + 1) * width // (2 * nx)
            r, g, b, a = pixel(x, y)
            if a >= OPAQUE:
                out.append((r, g, b))
    return out


# --- the corpus and its measures -----------------------------------------------------------


def rgb(hexvalue):
    return int(hexvalue[0:2], 16), int(hexvalue[2:4], 16), int(hexvalue[4:6], 16)


def d2(a, b):
    """512 x redmean squared: (2 + r/256, 4, 2 + (255 - r)/256) over the mean red, in integers."""
    r1, g1, b1 = a
    r2, g2, b2 = b
    return (1024 + r1 + r2) * (r1 - r2) ** 2 + 2048 * (g1 - g2) ** 2 + (1534 - r1 - r2) * (b1 - b2) ** 2


def channel(component):
    component /= 255
    return component / 12.92 if component <= 0.03928 else ((component + 0.055) / 1.055) ** 2.4


def luminance(hexvalue):
    r, g, b = rgb(hexvalue)
    return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)


def ratio(a, b):
    first, second = luminance(a), luminance(b)
    return (max(first, second) + 0.05) / (min(first, second) + 0.05)


def rows_of(path):
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if line.strip() and not line.startswith("#"):
            yield line.split("\t")


class Corpus:
    def __init__(self, data):
        self.order, self.role = [], {}
        for fields in rows_of(Path(data) / "palette-corpus.tsv"):
            if fields[0] not in self.role:  # a colour listed twice keeps its first row
                self.order.append(fields[0])
                self.role[fields[0]] = fields[2]
        self.index = {hexvalue: i for i, hexvalue in enumerate(self.order)}
        self.root = {fields[0]: fields[1] for fields in rows_of(Path(data) / "corpus-roots.tsv")}
        self.distance = {}
        for a, b, d in rows_of(Path(data) / "root-distance.tsv"):
            self.distance[(a, b)] = self.distance[(b, a)] = int(d)

    def of(self, *roles):
        return [c for c in self.order if self.role[c] in roles]

    def apart(self, a, b):
        return 0 if a == b else self.distance[(a, b)]


def ranked(points, candidates, corpus, weight=None, near=None):
    """Candidates by the votes of the samples nearest each, most first; ties by nearness
    to NEAR when given, then by corpus order."""
    if not candidates:
        return []
    triples = [(c, rgb(c)) for c in candidates]
    votes = {c: 0 for c in candidates}
    counts = {c: 0 for c in candidates}
    for point in points:
        best, best_d = None, None
        for c, t in triples:
            d = d2(point, t)
            if best_d is None or d < best_d:
                best, best_d = c, d
        votes[best] += weight(point) if weight else 1
        counts[best] += 1
    return sorted(candidates, key=lambda c: (-votes[c], -counts[c], d2(rgb(c), rgb(near)) if near else 0, corpus.index[c]))


def nearest_first(candidates, anchor, corpus):
    return sorted(candidates, key=lambda c: (d2(rgb(c), rgb(anchor)), corpus.index[c]))


def chroma(point):
    return max(point) - min(point)


def attempt(points, bg, corpus):
    """The palette on ground BG, or None when some role has nothing that clears its floor."""
    lum = luminance
    p = {"COLOR_BG": bg}
    fg = [c for c in corpus.of("text") if ratio(c, bg) >= TEXT_FLOOR]
    if not fg:
        return None
    p["COLOR_FG"] = p["TERMINAL_FG"] = ranked(points, fg, corpus)[0]
    fg = p["COLOR_FG"]

    dim = [c for c in corpus.of("text") if c != fg and lum(c) < lum(fg) and ratio(c, bg) >= DIM_FLOOR]
    if not dim:
        return None
    p["COLOR_FG_DIM"] = nearest_first(dim, fg, corpus)[0]

    # The terminal's ground is a darker, neutral neighbour of the base, or the base itself.
    deeper = [c for c in corpus.of("deep") if c != bg and lum(c) <= lum(bg) and chroma(rgb(c)) <= NEUTRAL
              and ratio(fg, c) >= TEXT_FLOOR]
    p["TERMINAL_BG"] = nearest_first(deeper, bg, corpus)[0] if deeper else bg

    surfaces = [c for c in corpus.of("surface", "raised", "base")
                if c != bg and lum(c) > lum(bg) and ratio(c, bg) < SURFACE_CEILING and ratio(fg, c) >= DIM_FLOOR]
    if len(surfaces) < 3:
        return None
    p["COLOR_SURFACE"], p["COLOR_SURFACE_ALT"], p["COLOR_BORDER_INACTIVE"] = ranked(points, surfaces, corpus, near=bg)[:3]

    home = corpus.root[bg]
    accents = [c for c in corpus.of("accent")
               if c in corpus.root and corpus.root[c] != home and corpus.apart(home, corpus.root[c]) < RUPTURE
               and ratio(c, bg) >= MARK_FLOOR and c not in (fg, p["COLOR_FG_DIM"])]
    if not accents:
        return None
    accent = p["COLOR_ACCENT"] = ranked(points, accents, corpus, weight=chroma)[0]

    marks = [c for c in corpus.of("accent", "urgent") if c != accent and ratio(c, bg) >= MARK_FLOOR]
    if not marks:
        return None
    p["COLOR_URGENT"] = nearest_first(marks, ANCHORS["COLOR_URGENT"], corpus)[0]
    info = [c for c in marks if corpus.role[c] == "accent" and c != p["COLOR_URGENT"] and d2(rgb(c), rgb(accent)) >= APART]
    if not info:
        return None
    p["COLOR_INFO"] = nearest_first(info, ANCHORS["COLOR_INFO"], corpus)[0]
    ok = [c for c in marks if corpus.role[c] == "accent" and c not in (p["COLOR_URGENT"], p["COLOR_INFO"])]
    if not ok:
        return None
    p["COLOR_OK"] = nearest_first(ok, ANCHORS["COLOR_OK"], corpus)[0]
    muted = [c for c in corpus.of("muted", "accent")
             if c != accent and ratio(c, bg) >= MARK_FLOOR and d2(rgb(c), rgb(p["COLOR_FG_DIM"])) >= APART]
    if not muted:
        return None
    p["COLOR_MUTED"] = nearest_first(muted, ANCHORS["COLOR_MUTED"], corpus)[0]
    return p


def palette_from(points, corpus):
    grounds = [c for c in corpus.of("deep", "base") if c in corpus.root]
    for bg in ranked(points, grounds, corpus):
        made = attempt(points, bg, corpus)
        if made:
            return made
    raise Refused("picture.no_palette")


# --- the file ------------------------------------------------------------------------------


def name_for(image, wanted):
    if wanted:
        if not NAME.fullmatch(wanted):
            raise Refused("picture.bad_name", wanted)
        return wanted
    stem = re.sub(r"[^a-z0-9]+", "-", Path(image).stem.lower()).strip("-")
    if stem and not stem[0].isalpha():
        stem = "picture-" + stem
    stem = stem[:32].rstrip("-")
    return stem or "picture"


def title_for(name):
    return " ".join(word[:1].upper() + word[1:] for word in name.split("-") if word)


def verdict(distance):
    return "affinity" if distance <= 2 else "tension" if distance <= 4 else "rupture"


def render(name, wallpaper, p, corpus):
    dominant, accent = corpus.root[p["COLOR_BG"]], corpus.root[p["COLOR_ACCENT"]]
    distance = corpus.apart(dominant, accent)
    lines = [
        f"# {title_for(name)} - a palette made from a picture (vivac theme from-image).",
        "# Every colour is the corpus colour the picture voted for that clears its floor.",
        f"# @title: {title_for(name)}",
        "# @essence: Picture",
        f"# @dominant: {dominant}",
        f"# @accent: {accent}",
        f"# @distance: {distance}",
        f"# @verdict: {verdict(distance)}",
        f"# @wallpaper: {wallpaper}",
    ]
    lines += [f"{key}={p[key]}" for key in KEYS]
    return "\n".join(lines) + "\n"


def swatches(name, p, corpus, text, target):
    floors = {"COLOR_FG": "COLOR_BG", "COLOR_FG_DIM": "COLOR_BG", "COLOR_ACCENT": "COLOR_BG", "TERMINAL_FG": "TERMINAL_BG"}
    out = [title_for(name)]
    for key in KEYS:
        r, g, b = rgb(p[key])
        note = f"  {ratio(p[key], p[floors[key]]):.1f}:1" if key in floors else ""
        out.append(f"  \x1b[48;2;{r};{g};{b}m      \x1b[0m  {key:<22}{p[key]}{note}")
    dominant, accent = corpus.root[p["COLOR_BG"]], corpus.root[p["COLOR_ACCENT"]]
    distance = corpus.apart(dominant, accent)
    out.append(text.get("picture.roots", dominant, accent, distance, verdict(distance)))
    out.append(text.get("picture.would_write", target))
    return "\n".join(out)


def write_atomic(path, payload):
    scratch = Path(tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")[1])
    try:
        scratch.write_bytes(payload)
        os.replace(scratch, path)
    except BaseException:
        scratch.unlink(missing_ok=True)
        raise


def main(argv):
    parser = argparse.ArgumentParser(prog="theme-from-image")
    parser.add_argument("image")
    parser.add_argument("--dir", required=True, help="where user palettes live")
    parser.add_argument("--name")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--data", default=str(Path(__file__).resolve().parent.parent / "data"))
    args = parser.parse_args(argv)

    data = Path(args.data)
    settings = Path(os.environ.get("SETTINGS_FILE") or Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "vivac" / "settings")
    text = Text(os.environ.get("I18N_DIR") or data.parent / "i18n", session_language(settings))
    try:
        image = Path(args.image)
        kind = kind_of(image) if image.is_file() else None
        decoded = decode(image) if kind else None
        if not decoded:
            raise Refused("picture.unreadable", image)
        points = samples(*decoded)
        if not points:
            raise Refused("picture.unreadable", image)
        name = name_for(image, args.name)
        shipped = {"bad-romance"} | {p.stem for p in (data / "themes").glob("*.conf")}
        if name in shipped:
            raise Refused("picture.taken", name)
        corpus = Corpus(data)
        palette = palette_from(points, corpus)
    except Refused as refused:
        print("vivac-theme: " + text.get(refused.key, *refused.args_), file=sys.stderr)
        return 1

    folder = Path(args.dir)
    wallpaper = f"{name}.{kind}"
    conf = folder / f"{name}.conf"
    if args.dry_run:
        print(swatches(name, palette, corpus, text, conf))
        return 0
    folder.mkdir(parents=True, exist_ok=True)
    # The picture first: a palette that names a wallpaper not there yet would
    # be worn for a moment with the fallback background.
    write_atomic(folder / wallpaper, image.read_bytes())
    for other in ("png", "jpg"):
        if other != kind:
            (folder / f"{name}.{other}").unlink(missing_ok=True)
    write_atomic(conf, render(name, wallpaper, palette, corpus).encode("utf-8"))
    print("vivac-theme: " + text.get("picture.wrote", name, conf), file=sys.stderr)
    print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
