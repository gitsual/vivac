#!/usr/bin/env python3
"""Render hardware-specific PipeWire rules locally without publishing IDs."""

from __future__ import annotations

import argparse
from pathlib import Path


def render(template: Path, destination: Path, marker: str, value: str) -> None:
    if not value or any(ch in value for ch in '\n\r"'):
        raise SystemExit("invalid PipeWire node name")
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(template.read_text().replace(marker, value))
    print(f"wrote {destination}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mic-node")
    parser.add_argument("--sink-node")
    args = parser.parse_args()
    if not args.mic_node and not args.sink_node:
        parser.error("provide --mic-node and/or --sink-node; discover names with: wpctl status -n")

    root = Path(__file__).resolve().parent.parent
    config = Path.home() / ".config" / "wireplumber" / "wireplumber.conf.d"
    if args.mic_node:
        render(root / "profiles/audio/studio-usb-mic.conf.template", config / "90-local-studio-mic.conf", "@MIC_NODE@", args.mic_node)
    if args.sink_node:
        render(root / "profiles/audio/analog-headroom.conf.template", config / "91-local-analog-headroom.conf", "@SINK_NODE@", args.sink_node)
    print("restart with: systemctl --user restart pipewire pipewire-pulse wireplumber")


if __name__ == "__main__":
    main()
