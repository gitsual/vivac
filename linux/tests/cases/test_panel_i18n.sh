#!/usr/bin/env bash
set -Eeuo pipefail
# A panel that calls T("key") with no arguments must not get a text with a
# {1} placeholder: it would show up literally on screen ("Connected to {1}").
repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
/usr/bin/python3 -I - "$repo_root" <<'PY'
import re, sys
from pathlib import Path
root = Path(sys.argv[1])
call = re.compile(r"""\bT\(\s*["']([\w.]+)["']\s*\)""")
bad = []
for conf in sorted((root / "i18n").glob("*.conf")):
    table = {}
    for line in conf.read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1)
            table[k.strip()] = v
    for src in sorted((root / "lib" / "vivacpanel").glob("*.py")):
        for key in set(call.findall(src.read_text(encoding="utf-8"))):
            if re.search(r"\{\d+\}", table.get(key, "")):
                bad.append(f"{conf.name}: {key} used without arguments in {src.name}")
if bad:
    sys.exit("\n".join(bad))
PY
