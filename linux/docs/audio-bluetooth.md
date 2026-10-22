# Audio and Bluetooth architecture

The workstation uses PipeWire, PipeWire-Pulse and WirePlumber with three layers:

1. a balanced 48/96 kHz graph for normal desktop use and studio capture;
2. larger Pulse compatibility buffers to prevent underruns under gaming/CPU load;
3. WirePlumber Bluetooth codec and role policy.

Hardware node names are deliberately not published. Run `wpctl status -n`, then render local rules:

```bash
./scripts/configure-audio.py --mic-node '<local microphone node>'
./scripts/configure-audio.py --sink-node '<local analog sink node>'
systemctl --user restart pipewire pipewire-pulse wireplumber
```

For unstable Bluetooth gaming, replace the balanced rule locally with `profiles/audio/bluetooth-gaming.conf`. It forces A2DP/SBC and intentionally disables headset microphone roles. The balanced profile keeps A2DP, SBC-XQ, AAC and headset roles available.

The BlueZ system profile enables reconnection and privacy while changing the live machine's permissive `JustWorksRepairing=always` choice to the safer `confirm` policy. Apply it only after review:

```bash
./scripts/apply-system.sh --dry-run
sudo ./scripts/apply-system.sh
```
