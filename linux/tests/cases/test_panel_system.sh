#!/usr/bin/env bash
# The fakes are shell source written out literally: their $ expands when they run.
# shellcheck disable=SC2016
set -Eeuo pipefail

# vivac-panel system, its backend without a display: /proc and /sys are the
# directories VIVAC_PROC and VIVAC_SYS name, df, ps-free process sampling and
# nvidia-smi are fakes. CPU use is a difference of two readings (total and per
# core), memory is total minus what is available, programs are grouped by name,
# the temperature is the CPU's hwmon, df lists only real filesystems once each
# and flags more than 90 % full, and with no NVIDIA card there is no GPU tab.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-system.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/bin" "$sandbox/proc/10" "$sandbox/proc/11" "$sandbox/proc/12" "$sandbox/proc/self" \
	"$sandbox/sys/class/hwmon/hwmon0" "$sandbox/sys/class/hwmon/hwmon1"

p="$sandbox/proc"
printf 'cpu  100 0 100 800 0 0 0 0 0 0\ncpu0 50 0 50 400 0 0 0 0 0 0\ncpu1 50 0 50 400 0 0 0 0 0 0\nintr 1\n' >"$sandbox/stat.1"
printf 'cpu  200 0 150 950 0 0 0 0 0 0\ncpu0 150 0 100 450 0 0 0 0 0 0\ncpu1 50 0 50 500 0 0 0 0 0 0\nintr 2\n' >"$sandbox/stat.2"
cp "$sandbox/stat.1" "$p/stat"
printf '0.52 0.40 0.31 2/900 1234\n' >"$p/loadavg"
printf 'MemTotal:       16000000 kB\nMemFree:         1000000 kB\nMemAvailable:    4000000 kB\nSwapTotal:       2000000 kB\nSwapFree:        1500000 kB\n' >"$p/meminfo"
printf 'processor\t: 0\nmodel name\t: Fake CPU 9000\ncpu MHz\t\t: 3000.000\nphysical id\t: 0\ncore id\t\t: 0\n\nprocessor\t: 1\nmodel name\t: Fake CPU 9000\ncpu MHz\t\t: 4000.000\nphysical id\t: 0\ncore id\t\t: 1\n\n' >"$p/cpuinfo"
# pid 10 and 11 are both "firefox" (comm), 12 is "bash"; utime stime are fields 14 and 15.
proc() { # pid comm utime stime rss_pages
	printf '%s (%s) S 1 1 1 0 -1 0 0 0 0 0 %s %s 0 0 20 0 1 0 1 0 0\n' "$1" "$2" "$3" "$4" >"$p/$1/stat"
	printf '%s\n' "$2" >"$p/$1/comm"
	printf '100 %s 0 0 0 0 0\n' "$5" >"$p/$1/statm"
}
proc 10 firefox 100 0 1000
proc 11 firefox 50 10 500
proc 12 bash 10 0 100
mkdir -p "$sandbox/proc2"
cp -r "$p/." "$sandbox/proc2/"
proc2() { sed -i "s/^\([0-9]*\) (\([a-z]*\)) S 1 1 1 0 -1 0 0 0 0 0 [0-9]* [0-9]*/\1 (\2) S 1 1 1 0 -1 0 0 0 0 0 $2 $3/" "$sandbox/proc2/$1/stat"; }
proc2 10 200 0
proc2 11 100 10
proc2 12 10 0
cp "$sandbox/stat.2" "$sandbox/proc2/stat"

printf 'nvme\n' >"$sandbox/sys/class/hwmon/hwmon0/name"
printf '40000\n' >"$sandbox/sys/class/hwmon/hwmon0/temp1_input"
printf 'k10temp\n' >"$sandbox/sys/class/hwmon/hwmon1/name"
printf '55500\n' >"$sandbox/sys/class/hwmon/hwmon1/temp1_input"

cat >"$sandbox/bin/df" <<'FAKE'
#!/usr/bin/env bash
cat <<'OUT'
Filesystem     Type          1-blocks        Used   Available Capacity Mounted on
dev            devtmpfs   33513369600           0 33513369600       0% /dev
tmpfs          tmpfs      33666953216     3813376 33663139840       1% /run
efivarfs       efivarfs        131072       50109       75843      40% /sys/firmware/efi/efivars
/dev/sda2      btrfs     114764546048 68529565696 44418306048      61% /
/dev/sda2      btrfs     114764546048 68529565696 44418306048      61% /home
/dev/sda1      vfat        2042806272   469135360  1573670912      23% /boot/efi
/dev/nvme1n1p1 ext4     3936818806784 3351998910464 384763867136   90% /home/me/data
/dev/nvme0n1p3 ntfs3     499289944064 461928353792 37361590272     93% /mnt/win
tmpfs          tmpfs        6733389824      851968  6732537856       1% /run/user/1000
OUT
FAKE
cat >"$sandbox/bin/nvidia-smi" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
*query-gpu*) echo "Fake GPU 4080, 40, 2000, 16000, 55.50, 120.50, 320.00, [N/A], 1800" ;;
*pmon*)
	printf '# gpu pid type sm mem enc dec jpg ofa fb ccpm command\n# Idx # C/G %% %% %% %% %% %% MB MB name\n'
	printf '    0   1069     C      -      -      -      -      -      -   1322      0    python\n'
	printf '    0   8981     G      0      0      -      -      -      -     75      0    Hyprland\n'
	printf '    0  45010     G      -      -      -      -      -      -     39      0    kitty\n'
	;;
esac
FAKE
chmod +x "$sandbox/bin/"*
export VIVAC_PROC="$p" VIVAC_SYS="$sandbox/sys" VIVAC_DF="$sandbox/bin/df" VIVAC_NVIDIA_SMI="$sandbox/bin/nvidia-smi"
mkdir -p "$sandbox/topo"
for pair in "0 0" "1 1" "2 0" "3 1"; do
	set -- $pair
	mkdir -p "$sandbox/topo/devices/system/cpu/cpu$1/topology"
	printf '%s\n' "$2" >"$sandbox/topo/devices/system/cpu/cpu$1/topology/core_id"
	printf '0\n' >"$sandbox/topo/devices/system/cpu/cpu$1/topology/physical_package_id"
done
export TOPO="$sandbox/topo"
export PROC2="$sandbox/proc2" STAT1="$sandbox/stat.1" STAT2="$sandbox/stat.2"

out="$(/usr/bin/python3 - "$repo_root/lib" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1])
from vivacpanel import system as s
a = s.read_cpu()
os.environ["VIVAC_PROC"] = os.environ["PROC2"]
b = s.read_cpu()
total, cores = s.cpu_usage(a, b)
print("cpu", round(total), [round(c) for c in cores])
os.environ["VIVAC_PROC"] = os.environ["PROC2"].replace("proc2", "proc")
print("load", s.loadavg())
print("info", s.cpu_info())
print("temp", s.temperature())
m = s.memory()
print("mem", m.total, m.used, m.available, m.swap_total, m.swap_used)
pa = s.read_procs()
print("procs", sorted((n, t, r) for n, t, r in pa.values()))
os.environ["VIVAC_PROC"] = os.environ["PROC2"]
pb = s.read_procs()
print("topcpu", [(n, round(v, 1)) for n, v in s.top_cpu(pa, pb, 1.0, 2, clk=100)])
print("topmem", [(n, v) for n, v in s.top_mem(pb, 5)])
print("disks", [(d.mount, d.fstype, round(d.percent), d.alert) for d in s.disks()])
g = s.gpu()
print("gpu", g.name, g.load, g.mem_used, g.mem_total, g.temp, g.power, g.power_limit, g.fan, g.clock)
print("gpuprocs", [(p.pid, p.name, p.kind, p.mb) for p in g.procs])
print("tabs", s.available_tabs())
os.environ["VIVAC_NVIDIA_SMI"] = "/nonexistent/nvidia-smi"
print("nogpu", s.gpu(), s.available_tabs())
bar = s.bar_summary(50.0, m, s.disks(), 55.5, None)
print("bar", bar["text"], bar["class"], bar["tooltip"].replace("\n", " | "))
calm = s.bar_summary(12.0, s.Mem(100, 40, 60, 0, 0), [], 45.0, None)
print("calm", calm["class"])
print("fmt", s.human_bytes(1536 * 1024 * 1024), s.human_bytes(500 * 1024), s.human_bytes(3 * 1024**4))
print("heat", s.heat_alpha(0), round(s.heat_alpha(48), 2), s.heat_alpha(100))
print("stats", s.history_stats([]), s.history_stats([10, 50, 20, 50, 5]), s.history_stats([10, 50, 20, 50, 5], 1.0)[2])
print("split", s.split_seconds(80), s.split_seconds(4))
print("stack", s.stack_parts([("a", 50), ("b", 25), ("c", 5)], 100, 2), s.stack_parts([("a", 1)], 0, 2))
print("cols fallback", s.thread_columns([1.0, 2.0]))
topo = os.environ["TOPO"]
os.environ["VIVAC_SYS"] = topo
# Intel-style numbering: cpu0 and cpu2 are one core, cpu1 and cpu3 the other
print("cols topology", s.thread_columns([10.0, 20.0, 30.0, 40.0]))
PY
)"
grep -qF "cpu 50 [75, 0]" <<<"$out" || fail "cpu use is a difference of two readings: $out"
grep -qF "load (0.52, 0.4, 0.31)" <<<"$out" || fail "load average: $out"
grep -qF "info {'model': 'Fake CPU 9000', 'cores': 2, 'threads': 2, 'mhz': 3500}" <<<"$out" || fail "cpu info: $out"
grep -qF "temp 55.5" <<<"$out" || fail "the CPU's hwmon is k10temp, not the disk's: $out"
grep -qF "mem 16384000000 12288000000 4096000000 2048000000 512000000" <<<"$out" || fail "memory: $out"
grep -qF "procs [('bash', 10, 409600), ('firefox', 60, 2048000), ('firefox', 100, 4096000)]" <<<"$out" || fail "process readings: $out"
grep -qF "topcpu [('firefox', 75.0), ('bash', 0.0)]" <<<"$out" || fail "programs grouped by name, percent of the machine: $out"
grep -qF "topmem [('firefox', 6144000), ('bash', 409600)]" <<<"$out" || fail "memory per program: $out"
grep -qF "disks [('/', 'btrfs', 61, False), ('/boot/efi', 'vfat', 23, False), ('/home/me/data', 'ext4', 90, False), ('/mnt/win', 'ntfs3', 93, True)]" <<<"$out" || fail "disks: $out"
grep -qF "gpu Fake GPU 4080 40 2000 16000 55.5 120.5 320.0 None 1800" <<<"$out" || fail "gpu: $out"
grep -qF "gpuprocs [(1069, 'python', 'C', 1322), (8981, 'Hyprland', 'G', 75), (45010, 'kitty', 'G', 39)]" <<<"$out" || fail "gpu processes: $out"
grep -qF "tabs ['cpu', 'memory', 'disk', 'gpu']" <<<"$out" || fail "tabs: $out"
grep -qF "nogpu None ['cpu', 'memory', 'disk']" <<<"$out" || fail "no NVIDIA card, no GPU tab: $out"
grep -qE "^bar .* 50% warning " <<<"$out" || fail "one chip for the whole system: cpu shown, a nearly full disk makes it a warning: $out"
grep -qF "/mnt/win 93%" <<<"$out" || fail "the bar tooltip names the full disk: $out"
grep -qF "75%" <<<"$(grep '^bar' <<<"$out")" || fail "memory in the bar tooltip: $out"
grep -qF "calm ok" <<<"$out" || fail "a quiet machine is ok: $out"
grep -qF "fmt 1.5 GB 500 KB 3.0 TB" <<<"$out" || fail "sizes: $out"
grep -qF "heat 0.14 0.98 1.0" <<<"$out" || fail "tile fill grows with use: $out"
grep -qF "stats (0.0, 0.0, 0.0) (50, 27.0, 2.0) 1.0" <<<"$out" || fail "peak, mean and time since the (latest) peak: $out"
grep -qF "split (1, 20) (0, 4)" <<<"$out" || fail "seconds as minutes and seconds: $out"
grep -qF "stack [('a', 0.5), ('b', 0.25)] []" <<<"$out" || fail "stack parts are fractions of the total: $out"
grep -qF "cols fallback [[1.0], [2.0]]" <<<"$out" || fail "no topology, no SMT: one column per thread: $out"
grep -qF "cols topology [[10.0, 30.0], [20.0, 40.0]]" <<<"$out" || fail "one column per core, its siblings by topology: $out"
printf 'ok: system panel backend\n'
