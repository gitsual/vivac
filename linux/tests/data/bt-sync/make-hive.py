#!/usr/bin/env python3
"""make-hive.py TOOL REG OUT [--dirty]: a SYSTEM hive holding what REG holds.

The test's stand-in for a Windows partition: an empty hive is written here,
byte by byte (a regf header, one hive bin, a root key and its security cell),
then filled through python-hivex, the library vivac-bt-sync reads it with.
The keys go under ControlSet002 with Select\\Current=2, so the control set has
to be looked up rather than assumed. --dirty leaves the two header sequence
numbers different, as a hive Windows did not finish writing is.
"""

import importlib.machinery
import importlib.util
import struct
import sys

import hivex

sys.dont_write_bytecode = True  # no __pycache__ beside the tool in the checkout
tool, reg, out = sys.argv[1:4]
dirty = "--dirty" in sys.argv[4:]


def cell(body: bytes) -> bytes:
    """A used cell: negative size first, padded to eight bytes."""
    size = (len(body) + 4 + 7) // 8 * 8
    return struct.pack("<i", -size) + body + b"\0" * (size - 4 - len(body))


# Offsets are from the start of the first hive bin, 4096 bytes into the file.
NK_AT = 0x20
name = b"ROOT"
security = struct.pack("<BBHIIII", 1, 0, 0x8004, 0, 0, 0, 0)  # empty self-relative descriptor
nk_body = b"nk" + struct.pack(
    "<HQIIIIIIIIIIHHIIIIHH", 0x2C, 0, 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF,
    0, 0xFFFFFFFF, 0, 0, 0, 0, 0, 0, len(name), 0
) + name
nk = cell(nk_body)
SK_AT = NK_AT + len(nk)
nk = cell(nk_body[:44] + struct.pack("<I", SK_AT) + nk_body[48:])
sk = cell(b"sk" + struct.pack("<HIIII", 0, SK_AT, SK_AT, 1, len(security)) + security)
used = nk + sk
free = 4096 - 32 - len(used)
hbin = b"hbin" + struct.pack("<III", 0, 4096, 0) + b"\0" * 16 + used + struct.pack("<i", free) + b"\0" * (free - 4)
header = bytearray(4096)
header[0:4] = b"regf"
struct.pack_into("<IIQIIIIIII", header, 4, 1, 2 if dirty else 1, 0, 1, 3, 0, 1, NK_AT, 4096, 1)
struct.pack_into("<I", header, 0x1FC, 0)
checksum = 0
for (word,) in struct.iter_unpack("<I", bytes(header[:0x1FC])):
    checksum ^= word
struct.pack_into("<I", header, 0x1FC, checksum)
with open(out, "wb") as handle:
    handle.write(bytes(header) + hbin)

# The .reg sections, read with the tool's own value parser.
loader = importlib.machinery.SourceFileLoader("btsync", tool)
spec = importlib.util.spec_from_loader("btsync", loader)
btsync = sys.modules["btsync"] = importlib.util.module_from_spec(spec)
loader.exec_module(btsync)
sections, current = {}, None
for line in open(reg, encoding="utf-8").read().replace("\\\n  ", "").splitlines():
    if line.startswith("["):
        parts = line.strip("[]").split("\\")
        at = [p.lower() for p in parts].index("services")
        current = sections.setdefault(("ControlSet002", *parts[at:]), [])
    elif current is not None and btsync.REG_VALUE.match(line):
        match = btsync.REG_VALUE.match(line)
        kind, data = btsync.reg_data(match.group(2))
        current.append({"key": match.group(1), "t": kind, "value": data})
sections[("Select",)] = [{"key": "Current", "t": 4, "value": (2).to_bytes(4, "little")}]

hive = hivex.Hivex(out, write=True)
for path in sorted(sections):
    node = hive.root()
    for part in path:
        node = hive.node_get_child(node, part) or hive.node_add_child(node, part)
    hive.node_set_values(node, sections[path])
hive.commit(out)
if dirty:
    # hivex makes the hive whole again when it commits: undo that, with the
    # header checksum Windows would have written for it.
    with open(out, "r+b") as handle:
        header = bytearray(handle.read(0x200))
        struct.pack_into("<I", header, 8, struct.unpack_from("<I", header, 4)[0] + 1)
        checksum = 0
        for (word,) in struct.iter_unpack("<I", bytes(header[:0x1FC])):
            checksum ^= word
        struct.pack_into("<I", header, 0x1FC, checksum)
        handle.seek(0)
        handle.write(header)
