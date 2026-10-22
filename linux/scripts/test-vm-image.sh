#!/usr/bin/env bash
set -Eeuo pipefail

# Accept the PUBLISHED artifact, not the tree that produced it.
#
# The sealed image does not listen on the network — sshd ships installed and
# disabled — so it is accepted the way its owner will meet it: through the
# console, logging in with the published credentials.
#
# Three properties matter, and each is asserted rather than inferred. The
# credentials in the README actually work. sshd is really off, so the known
# root password is not a door left open. And two instances of the same file
# report DIFFERENT machine ids, which is the whole point of truncating it in
# the seal; if it fails, every download shares one identity.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
image="$repo_root/dist/vivac.qcow2"
# The published credentials, as the README states them.
image_user="${VM_IMAGE_USER:-user}"
boot_timeout="${VM_IMAGE_BOOT_TIMEOUT:-180}"

usage() {
	cat <<'USAGE'
Usage: scripts/test-vm-image.sh [--image PATH]

Boot the published image twice and accept it from its own console.
Works on any format QEMU reads, so the OVA's VMDK can be accepted too.
Overrides: VM_IMAGE_BOOT_TIMEOUT (seconds, default 180), VM_IMAGE_USER.
USAGE
}

while (($#)); do
	case "$1" in
	--image)
		[[ $# -ge 2 ]] || {
			printf '%s\n' '--image needs a path' >&2
			exit 2
		}
		image="$2"
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		printf 'Unknown option: %s\n' "$1" >&2
		exit 2
		;;
	esac
	shift
done

for command_name in qemu-system-x86_64 qemu-img python; do
	command -v "$command_name" >/dev/null || {
		printf 'Missing host dependency: %s\n' "$command_name" >&2
		exit 1
	}
done
[[ -f "$image" ]] || {
	printf 'No image at %s; run scripts/build-vm-image.sh first\n' "$image" >&2
	exit 1
}
qemu-img check -q "$image"
# The OVA ships the same disk in another format; accepting only the qcow2
# would leave half the release untested.
image_format="$(qemu-img info --output=json "$image" | python -c 'import json,sys; print(json.load(sys.stdin)["format"])')"

work="$(mktemp -d)"
pids=()
cleanup() {
	status=$?
	for pid in "${pids[@]:-}"; do
		[[ -n "$pid" ]] && kill "$pid" 2>/dev/null
	done
	rm -rf -- "$work"
	((status == 0)) || printf 'Published image rejected\n' >&2
}
trap cleanup EXIT

# -snapshot keeps every write in a throwaway overlay, so the artifact under
# test is the file that ships, bit for bit, and two instances cannot share
# state through it. No network device is attached at all: an image that needed
# one to be accepted would not be the image that ships.
consoles=()
for instance in 1 2; do
	console="$work/console-$instance.sock"
	consoles+=("$console")
	qemu-system-x86_64 \
		-enable-kvm -machine q35,accel=kvm -cpu host \
		-smp 2 -m 2048 -snapshot \
		-drive "if=virtio,format=$image_format,file=$image" \
		-nic none \
		-device virtio-vga -display none \
		-daemonize -pidfile "$work/qemu-$instance.pid" \
		-serial "unix:$console,server=on,wait=off"
	pids+=("$(<"$work/qemu-$instance.pid")")
done

# Talking to a getty is a conversation, not a command: the driver waits for
# each prompt instead of sleeping and hoping, and every answer comes back
# tagged so a line of boot noise cannot be mistaken for one.
report() {
	python - "$1" "$2" "$3" <<'DRIVER'
import os, re, socket, sys, time

# The guest's shell announces every command with OSC semantic-prompt sequences
# and paints its prompt with CSI colour. Neither ends in a newline, so the
# answer we asked for arrives welded to the tail of an escape sequence. Strip
# them and the console reads like a console again.
ESCAPES = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-9;?]*[A-Za-z]|\x1b[()][B0]|[\x07\r]")

path, user, deadline = sys.argv[1], sys.argv[2], float(sys.argv[3])
end = time.time() + deadline
buffer = ""

connection = None
while time.time() < end and connection is None:
    try:
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.connect(path)
    except OSError:
        connection = None
        time.sleep(1)
if connection is None:
    sys.exit("console socket never accepted a connection")
connection.settimeout(2)


def expect(needle, what):
    global buffer
    while needle not in buffer:
        if time.time() > end:
            sys.exit("timed out waiting for %s\n--- console tail ---\n%s" % (what, buffer[-2000:]))
        try:
            chunk = connection.recv(4096)
        except socket.timeout:
            # A getty already sitting at its prompt sends nothing more; a
            # newline makes it reprint rather than leaving us blocked.
            connection.sendall(b"\n")
            continue
        if not chunk:
            sys.exit("console closed")
        buffer += chunk.decode("utf-8", "replace")


def send(line):
    connection.sendall((line + "\n").encode())


def dump():
    """Keep a verbatim copy of the console when asked. A verdict built from a
    transcript is only as trustworthy as the transcript, and the last four
    failures here were all in the reading, never in the image."""
    target = os.environ.get("VM_CONSOLE_DUMP")
    if target:
        with open(target + "." + os.path.basename(path), "w") as handle:
            handle.write(buffer)


def answered(tag, shape):
    """The VALUE of tag, or None.

    A line that merely contains the tag is not an answer: the terminal echoes
    the command that asks the question, and that echo arrives first, so only a
    line that STARTS with the tag counts. Neither is an EMPTY value an answer —
    a question typed into a getty that has not finished handing over to the
    shell comes back with nothing in it, and taking that as the reply would
    freeze the first stumble into the verdict. The last answer wins, because a
    console is a transcript and the most recent line is the current truth."""
    found = None
    for line in ESCAPES.sub("", buffer).splitlines():
        line = line.strip()
        if not line.startswith(tag + "="):
            continue
        value = line[len(tag) + 1:]
        if value and shape.fullmatch(value):
            found = value
    return found


def ask(tag, command, what, shape):
    """Ask until the guest answers something of the RIGHT SHAPE.

    Four verdicts in a row were harness bugs, and every one of them was the
    same mistake wearing a new hat: a half-arrived value read as a whole one,
    so that `disabled` became `d`, then `dis`, then `disa`. The cure is not one
    more guess about where the console splits. It is to state what an answer
    looks like and refuse everything else — a fragment of a word is not a
    systemd state, and a machine id is thirty-two hex digits or it is noise."""
    global buffer

    def settled_answer():
        return answered(tag, shape)

    while settled_answer() is None:
        if time.time() > end:
            sys.exit("timed out waiting for %s\n--- console tail ---\n%s" % (what, buffer[-2000:]))
        send(command)
        deadline = time.time() + 5
        while settled_answer() is None and time.time() < deadline:
            try:
                chunk = connection.recv(4096)
            except socket.timeout:
                break
            if not chunk:
                sys.exit("console closed")
            buffer += chunk.decode("utf-8", "replace")
            dump()
    return settled_answer()


expect("login:", "the login prompt")
send(user)
expect("assword:", "the password prompt")
send(user)
# Once, rather than on every question: a shell that echoes what it is asked
# answers twice, and the first copy is not an answer.
send("stty -echo 2>/dev/null")

# One tagged line per fact, so an answer cannot be confused with the motd, the
# prompt, or another answer.
print("MACHINE_ID=" + ask("MACHINE_ID", """printf 'MACHINE_ID=%s\\n' "$(cat /etc/machine-id)" """,
                          "the machine id", re.compile(r"[0-9a-f]{32}")))
print("SSHD=" + ask("SSHD", """printf 'SSHD=%s\\n' "$(systemctl is-enabled sshd.service 2>&1)" """,
                    "the sshd state",
                    re.compile(r"enabled|disabled|masked|static|indirect|generated|alias|linked|.*[Nn]o such file.*")))
print("HOSTKEYS=" + ask("HOSTKEYS", """printf 'HOSTKEYS=%s\\n' "$(ls /etc/ssh/ssh_host_* 2>/dev/null | wc -l)" """,
                        "the host key count", re.compile(r"[0-9]+")))
DRIVER
}

declare -A seen=()
for index in 0 1; do
	instance=$((index + 1))
	answers="$(report "${consoles[$index]}" "$image_user" "$boot_timeout")" || {
		printf 'Instance %d never reached a usable console:\n%s\n' "$instance" "$answers" >&2
		exit 1
	}
	machine_id="$(sed -nE 's/^MACHINE_ID=(.+)$/\1/p' <<<"$answers" | tail -1)"
	sshd="$(sed -nE 's/^SSHD=(.+)$/\1/p' <<<"$answers" | tail -1)"
	host_keys="$(sed -nE 's/^HOSTKEYS=(.+)$/\1/p' <<<"$answers" | tail -1)"

	[[ -n "$machine_id" ]] || {
		printf 'Instance %d reported no machine id; it said:\n%s\n' "$instance" "$answers" >&2
		exit 1
	}
	[[ "$sshd" == disabled ]] || {
		printf 'Instance %d ships sshd as %q; a published root password needs a closed door\n' \
			"$instance" "$sshd" >&2
		exit 1
	}
	((host_keys == 0)) || {
		printf 'Instance %d carries %s host key files from the build\n' "$instance" "$host_keys" >&2
		exit 1
	}
	[[ -v "seen[$machine_id]" ]] && {
		printf 'Both instances report machine id %s: the seal did not clear it\n' "$machine_id" >&2
		exit 1
	}
	seen["$machine_id"]="$instance"
done

printf 'Published image accepted: %s logs in, sshd is disabled, no host keys shipped,\n' "$image_user"
printf 'and the two instances report different machine ids.\n'
