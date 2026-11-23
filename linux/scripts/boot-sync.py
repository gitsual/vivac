#!/usr/bin/python3 -I
"""Carry the theme onto the EFI system partition: HackBGRT's boot logo and
GRUB's theme. The Linux twin of windows/scripts/boot-sync.ps1.

Runs as root, from vivac-boot-sync.service, installed under
/usr/local/lib/vivac where only root can change it; never run from the
checkout.

It reads the stage (/var/lib/vivac/boot-stage, written by the user with
scripts/boot-stage.sh) and trusts none of it: the palette is a fixed list of
keys whose values must be six hex digits, the size must be a plausible
screen, and each picture is decoded and encoded anew, so what reaches the
partition is a file this script wrote. The GRUB theme (theme.txt and its
frame pieces) is written here from the palette alone.

Writes only <esp>/EFI/HackBGRT/splash.bmp (and only when that folder is
already there) and <esp>/grub/themes/vivac/ on the partition. Everything is
rendered in memory before the first byte is written, so a stage that fails
any check leaves the partition exactly as it was.

Differences from the PowerShell original, all on purpose:
  * the palette file is held to a closed list of keys: a line naming any
    other key is a rejection, not something to skip;
  * the stage is opened without following links (a symlink, a device or a
    fifo in place of a file is refused), and a picture that decodes to more
    than 64 megapixels is refused before it is expanded;
  * the theme folder is updated file by file (write beside, rename over)
    instead of emptied first, so an interrupted run never leaves GRUB
    without a theme.txt; fonts already in the folder are kept when no other
    theme on the partition offers any.
"""
import argparse
import io
import os
import re
import stat
import sys
import time
import warnings

from PIL import Image, ImageDraw

KEYS = ('COLOR_BG', 'COLOR_FG', 'COLOR_FG_DIM', 'COLOR_SURFACE',
        'COLOR_SURFACE_ALT', 'COLOR_ACCENT', 'COLOR_MUTED',
        'COLOR_BORDER_INACTIVE')
ALLOWED = set(KEYS) | {'WIDTH', 'HEIGHT', 'THEME'}
MAX_PALETTE = 4096
MAX_PICTURE = 40 * 1024 * 1024
MAX_PIXELS = 64_000_000
Image.MAX_IMAGE_PIXELS = MAX_PIXELS
warnings.simplefilter('error', Image.DecompressionBombWarning)

_log_path = None


def log(message):
    line = '%s  %s' % (time.strftime('%Y-%m-%dT%H:%M:%S'), message)
    if _log_path:
        try:
            fd = os.open(_log_path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o644)
            with os.fdopen(fd, 'a', encoding='ascii', errors='replace') as f:
                f.write(line + '\n')
        except OSError as e:
            print('boot-sync: cannot log to %s: %s' % (_log_path, e), file=sys.stderr)
    print(line)


class Reject(Exception):
    pass


# ---------------------------------------------------------------- the stage

def read_stage_file(stage_fd, name, limit):
    """Bytes of a regular file inside the stage, never through a link."""
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=stage_fd)
    except OSError as e:
        raise Reject('%s cannot be opened (%s)' % (name, e.strerror))
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise Reject('%s is not a regular file' % name)
        if st.st_size > limit:
            raise Reject('%s is too large' % name)
        data = b''
        while len(data) <= limit:
            chunk = os.read(fd, 1 << 20)
            if not chunk:
                break
            data += chunk
        if len(data) > limit:
            raise Reject('%s is too large' % name)
        return data
    finally:
        os.close(fd)


def parse_palette(data):
    try:
        text = data.decode('ascii')
    except UnicodeDecodeError:
        raise Reject('palette.conf is not plain ASCII')
    kv = {}
    for raw in text.split('\n'):
        line = raw.rstrip('\r')
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        m = re.fullmatch(r'([A-Z_]+)=(.*)', line)
        if not m:
            raise Reject('palette.conf: a line is not KEY=value')
        key, value = m.group(1), m.group(2).strip()
        if key not in ALLOWED:
            raise Reject('palette.conf: %s is not a key of the contract' % key)
        if key in kv:
            raise Reject('palette.conf: %s appears twice' % key)
        kv[key] = value
    p = {}
    for k in KEYS:
        if k not in kv or not re.fullmatch(r'[0-9A-Fa-f]{6}', kv[k]):
            raise Reject('palette.conf: %s is missing or not a colour' % k)
        p[k] = kv[k].upper()
    for k in ('WIDTH', 'HEIGHT'):
        if k not in kv or not re.fullmatch(r'[0-9]{3,4}', kv[k]):
            raise Reject('palette.conf: %s is not a size' % k)
        p[k] = int(kv[k])
    if not (640 <= p['WIDTH'] <= 7680 and 480 <= p['HEIGHT'] <= 4320):
        raise Reject('palette.conf: implausible screen size')
    p['THEME'] = kv['THEME'] if re.fullmatch(r'[a-z0-9-]{1,40}', kv.get('THEME', '')) else ''
    return p


def rgb(hexstr):
    return tuple(int(hexstr[i:i + 2], 16) for i in (0, 2, 4))


def read_picture(data, name, width, height, flat):
    """Decoded, and drawn onto a fresh RGB picture of exactly the screen's size."""
    try:
        src = Image.open(io.BytesIO(data))
        if src.format != 'PNG':
            raise Reject('%s is not a PNG' % name)
        if src.width * src.height > MAX_PIXELS:
            raise Reject('%s is too large to decode' % name)
        src.load()
    except Reject:
        raise
    except (Image.DecompressionBombError, Image.DecompressionBombWarning):
        raise Reject('%s is too large to decode' % name)
    except Exception as e:  # truncated, corrupt, anything Pillow chokes on
        raise Reject('%s does not decode (%s)' % (name, type(e).__name__))
    src = src.convert('RGBA')
    base = Image.new('RGBA', src.size, rgb(flat) + (255,))
    base.alpha_composite(src)
    return base.convert('RGB').resize((width, height), Image.BICUBIC)


# --------------------------------------------------------- the GRUB theme

def frame_pieces(prefix, fill, border, stroke, radius):
    """A rounded frame cut into GRUB's nine pieces (<prefix>nw.png ... se.png):
    corners of the radius, edges and centre two pixels wide, stretched by GRUB."""
    k = 8
    r = radius
    s = 2 * r + 2
    big = Image.new('RGBA', (s * k, s * k), (0, 0, 0, 0))
    d = ImageDraw.Draw(big)
    last = s * k - 1
    if stroke > 0:
        d.rounded_rectangle([0, 0, last, last], radius=r * k, fill=border)
        i = stroke * k
        d.rounded_rectangle([i, i, last - i, last - i], radius=(r - stroke) * k, fill=fill)
    else:
        d.rounded_rectangle([0, 0, last, last], radius=r * k, fill=fill)
    bmp = big.resize((s, s), Image.BOX)
    cuts = {
        'nw': (0, 0, r, r), 'n': (r, 0, 2, r), 'ne': (r + 2, 0, r, r),
        'w': (0, r, r, 2), 'c': (r, r, 2, 2), 'e': (r + 2, r, r, 2),
        'sw': (0, r + 2, r, r), 's': (r, r + 2, 2, r), 'se': (r + 2, r + 2, r, r),
    }
    out = {}
    for name, (x, y, w, h) in cuts.items():
        out['%s%s.png' % (prefix, name)] = png_bytes(bmp.crop((x, y, x + w, y + h)))
    return out


def png_bytes(img):
    buf = io.BytesIO()
    img.save(buf, 'PNG')
    return buf.getvalue()


def font_name(data):
    """The name a PFF2 font file declares (its NAME section), which is what a
    GRUB theme refers to it by."""
    i = 0
    while i + 8 <= len(data):
        tag = data[i:i + 4]
        length = int.from_bytes(data[i + 4:i + 8], 'big')
        if tag == b'NAME':
            return data[i + 8:i + 8 + length].decode('ascii', 'replace').rstrip('\0')
        if tag == b'DATA':
            break
        i += 8 + length
    return None


def collect_fonts(themes_dir, own_dir):
    """{declared name: (file name, bytes)} from the other themes on the
    partition (GRUB ships DejaVu with its starfield theme); the files already
    in our own folder when no other theme has any."""
    def scan(dirs):
        found = {}
        for d in dirs:
            for root, subdirs, files in os.walk(d):
                subdirs.sort()
                for f in sorted(files):
                    if not f.endswith('.pf2'):
                        continue
                    path = os.path.join(root, f)
                    if os.path.islink(path) or os.path.getsize(path) > 8 * 1024 * 1024:
                        continue
                    with open(path, 'rb') as fh:
                        data = fh.read()
                    name = font_name(data)
                    if name and name not in found:
                        found[name] = (f, data)
        return found
    others = [os.path.join(themes_dir, e) for e in sorted(os.listdir(themes_dir))
              if os.path.join(themes_dir, e) != own_dir and os.path.isdir(os.path.join(themes_dir, e))
              and not os.path.islink(os.path.join(themes_dir, e))] if os.path.isdir(themes_dir) else []
    found = scan(others)
    return found or (scan([own_dir]) if os.path.isdir(own_dir) else {})


def select_font(fonts, style, size):
    best, gap = None, 999
    for n in fonts:
        m = re.fullmatch(r'(.*) %s (\d+)' % style, n)
        if not m:
            continue
        d = abs(int(m.group(2)) - size)
        if d < gap:
            best, gap = n, d
    if best is None and style != 'Regular':
        return select_font(fonts, 'Regular', size)
    return best


def theme_text(p, fonts):
    item = select_font(fonts, 'Regular', 16)
    small = select_font(fonts, 'Regular', 12)
    title = select_font(fonts, 'Bold', 16)

    def font_line(n):
        return 'font = "%s"' % n if n else ''
    item_font = sel_font = term_font = ''
    if item:
        item_font = 'item_font = "%s"' % item
        sel_font = 'selected_item_font = "%s"' % item
        term_font = 'terminal-font: "%s"' % item
    return '''# vivac: written by boot-sync from the theme '%(THEME)s'. Rewritten on
# every theme switch, on either system; changes made here do not last.
title-text: ""
desktop-image: "background.png"
desktop-color: "#%(COLOR_BG)s"
%(term_font)s
terminal-box: "menu_*.png"

+ label {
  left = 0 top = 21%% width = 100%% height = 32
  align = "center" text = "vivac" color = "#%(COLOR_ACCENT)s"
  %(title_font)s
}
+ boot_menu {
  left = 31%% top = 28%% width = 38%% height = 44%%
  %(item_font)s
  %(sel_font)s
  item_color = "#%(COLOR_FG)s"
  selected_item_color = "#%(COLOR_BG)s"
  item_height = 34 item_padding = 14 item_spacing = 6
  icon_width = 0 icon_height = 0 item_icon_space = 0
  menu_pixmap_style = "menu_*.png"
  selected_item_pixmap_style = "select_*.png"
  scrollbar = false
}
+ progress_bar {
  id = "__timeout__"
  left = 31%% top = 76%% width = 38%% height = 4
  show_text = false
  fg_color = "#%(COLOR_ACCENT)s" bg_color = "#%(COLOR_SURFACE)s" border_color = "#%(COLOR_SURFACE)s"
}
+ label {
  id = "__timeout__"
  left = 0 top = 79%% width = 100%% height = 24
  align = "center" color = "#%(COLOR_FG_DIM)s"
  text = "@TIMEOUT_NOTIFICATION_MIDDLE@"
  %(small_font)s
}
+ label {
  left = 0 top = 93%% width = 100%% height = 24
  align = "center" color = "#%(COLOR_MUTED)s"
  text = "Enter: boot   -   e: edit   -   c: console"
  %(small_font)s
}
''' % dict(p, term_font=term_font, item_font=item_font, sel_font=sel_font,
           title_font=font_line(title), small_font=font_line(small))


def grub_theme_files(p, background, themes_dir, own_dir):
    """Every file the theme folder will hold, as {name: bytes}, none written yet."""
    files = {'background.png': png_bytes(background)}
    # ReGreet's frame (system/etc/greetd/regreet.css in the source): the
    # surface at 92%, a two-pixel inactive border, twelve-pixel corners; the
    # selected entry is the accent, as its suggested-action button.
    files.update(frame_pieces('menu_', rgb(p['COLOR_SURFACE']) + (235,), rgb(p['COLOR_BORDER_INACTIVE']) + (255,), 2, 12))
    files.update(frame_pieces('select_', rgb(p['COLOR_ACCENT']) + (255,), rgb(p['COLOR_ACCENT']) + (255,), 0, 8))
    fonts = collect_fonts(themes_dir, own_dir)
    names = {}
    for name, (fname, data) in fonts.items():
        files[fname] = data
        names[name] = fname
    files['theme.txt'] = theme_text(p, names).encode('utf-8')
    return files, len(fonts)


# --------------------------------------------------------------- the writes

def replace_file(directory, name, data):
    tmp = os.path.join(directory, '.new-' + name)
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o644)
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
    except BaseException:
        os.unlink(tmp)
        raise
    os.replace(tmp, os.path.join(directory, name))


def write_theme(directory, files):
    os.makedirs(directory, exist_ok=True)
    # theme.txt last: GRUB reads it first, so it never meets pieces that are
    # not there yet.
    for name in sorted(files, key=lambda n: n == 'theme.txt'):
        replace_file(directory, name, files[name])
    for entry in os.listdir(directory):
        path = os.path.join(directory, entry)
        if entry not in files and (os.path.isfile(path) or os.path.islink(path)):
            os.unlink(path)


def splash_bmp(img):
    """24-bit with the 54-byte header HackBGRT reads."""
    buf = io.BytesIO()
    img.convert('RGB').save(buf, 'BMP')
    data = buf.getvalue()
    if data[:2] != b'BM' or int.from_bytes(data[10:14], 'little') != 54 or int.from_bytes(data[28:30], 'little') != 24:
        raise Reject('the boot logo did not encode as a 24-bit BMP')
    # GDI+ leaves biSizeImage at 0 (valid for an uncompressed bitmap); so do we,
    # so the file is the one Windows would have written.
    return data[:34] + bytes(4) + data[38:]


def sync(stage, esp):
    if not os.path.isdir(esp):
        raise Reject('%s is not a directory' % esp)
    try:
        stage_fd = os.open(stage, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError as e:
        raise Reject('the stage cannot be opened (%s)' % e.strerror)
    try:
        p = parse_palette(read_stage_file(stage_fd, 'palette.conf', MAX_PALETTE))
        splash = read_picture(read_stage_file(stage_fd, 'splash.png', MAX_PICTURE), 'splash.png', p['WIDTH'], p['HEIGHT'], p['COLOR_BG'])
        background = read_picture(read_stage_file(stage_fd, 'background.png', MAX_PICTURE), 'background.png', p['WIDTH'], p['HEIGHT'], p['COLOR_BG'])
    finally:
        os.close(stage_fd)

    hb = os.path.join(esp, 'EFI', 'HackBGRT')
    grub = os.path.join(esp, 'grub')
    themes = os.path.join(grub, 'themes')
    own = os.path.join(themes, 'vivac')
    bmp = splash_bmp(splash) if os.path.isdir(hb) and not os.path.islink(hb) else None
    theme = None
    if os.path.isdir(grub) and not os.path.islink(grub):
        theme = grub_theme_files(p, background, themes, own)
    # Everything is rendered; only now does anything touch the partition.
    if bmp is not None:
        replace_file(hb, 'splash.bmp', bmp)
    else:
        log('no EFI/HackBGRT on the partition: boot logo left alone')
    if theme is not None:
        write_theme(own, theme[0])
        log('grub theme written (%d fonts)' % theme[1])
    else:
        log('no grub on the partition: GRUB theme left alone')
    log("synced theme '%s' at %dx%d" % (p['THEME'], p['WIDTH'], p['HEIGHT']))


def main(argv=None):
    global _log_path
    ap = argparse.ArgumentParser(description='Carry the vivac theme onto the EFI system partition.')
    ap.add_argument('--stage', default='/var/lib/vivac/boot-stage')
    ap.add_argument('--esp', required=True, help='the mounted EFI system partition')
    ap.add_argument('--log', help='file to append the log to')
    a = ap.parse_args(argv)
    _log_path = a.log
    try:
        sync(a.stage, a.esp)
    except Reject as e:
        log('failed: %s' % e)
        return 1
    except Exception as e:
        log('failed: %s: %s' % (type(e).__name__, e))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
