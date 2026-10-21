#!/usr/bin/env python3
"""Fail closed on common secret, identity and private-network patterns."""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

EXCLUDED_PARTS = {".git", ".audit", ".vm-test", ".vm-image", "dist", "__pycache__"}
TEXT_LIMIT = 2 * 1024 * 1024
SENSITIVE_NAMES = re.compile(
    r"(?i)(^|[._-])(id_rsa|id_ed25519|credentials?|tokens?|cookies?|secrets?|\.env)([._-]|$)"
)
RULES = {
    "private-key": re.compile(r"BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY"),
    "github-token": re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b"),
    "aws-access-key": re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "credential-assignment": re.compile(
        r"(?i)(?:token|api[_-]?key|password|passwd|secret|oauth|credential)"
        r"\s*[:=]\s*[\"']?(?!example|placeholder|changeme|\$\{|<)[^\s\"']{8,}"
    ),
    # A systemd template instance (serial-getty@ttyS0.service) has the shape of
    # an address and is not one. The unit suffixes are excluded by name rather
    # than by loosening the rule, so a real address in a .service file is still
    # caught.
    "email-address": re.compile(
        r"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\."
        r"(?!service\b|socket\b|timer\b|target\b|mount\b|slice\b|path\b|swap\b|device\b)"
        r"[A-Z]{2,}\b"
    ),
    "absolute-home-path": re.compile(r"/home/[A-Za-z0-9._-]+"),
    "private-ipv4": re.compile(
        r"(?<![\d.])(?:10(?:\.\d{1,3}){3}|127(?:\.\d{1,3}){3}|"
        r"169\.254(?:\.\d{1,3}){2}|172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2}|"
        r"192\.168(?:\.\d{1,3}){2})(?![\d.])"
    ),
    "mac-address": re.compile(r"(?i)\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\b"),
    "uuid": re.compile(
        r"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-"
        r"[89ab][0-9a-f]{3}-[0-9a-f]{12}\b"
    ),
}


def iter_files(root: Path):
    for path in sorted(root.rglob("*")):
        if not path.is_file() or any(part in EXCLUDED_PARTS for part in path.parts):
            continue
        if path.stat().st_size > TEXT_LIMIT:
            continue
        yield path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", default=".")
    args = parser.parse_args()
    root = Path(args.root).resolve()
    findings: list[tuple[str, int, str]] = []
    markers = [m for m in os.environ.get("PRIVATE_MARKERS", "").split(",") if len(m) >= 4]

    for path in iter_files(root):
        relative = path.relative_to(root).as_posix()
        if SENSITIVE_NAMES.search(path.name):
            findings.append((relative, 0, "sensitive-filename"))
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for number, line in enumerate(text.splitlines(), 1):
            for rule, pattern in RULES.items():
                if pattern.search(line):
                    findings.append((relative, number, rule))
            for marker in markers:
                if marker.casefold() in line.casefold():
                    findings.append((relative, number, "private-marker"))

    if findings:
        print(f"privacy scan failed: {len(findings)} finding(s)", file=sys.stderr)
        for path, line, rule in findings:
            location = f"{path}:{line}" if line else path
            print(f"{location}: {rule}", file=sys.stderr)
        return 1
    print("privacy scan: clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
