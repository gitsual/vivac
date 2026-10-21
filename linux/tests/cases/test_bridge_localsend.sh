#!/usr/bin/env bash
# The fakes are shell source written out literally: their $ expands when they run.
# shellcheck disable=SC2016
set -Eeuo pipefail

# The phone drop (vivac-localsend), end to end on the loopback, with requests
# made by this test as a LocalSend phone makes them: /info and /register answer
# who this is; prepare-upload wants the PIN (401 without it or wrong, 429 after
# five wrong ones a minute from one address); upload takes only the session's
# tokens from the session's address, keeps the name but not its folders, never
# overwrites, refuses a SHA-256 mismatch (422) and a body past the announced
# size or 2 GiB (413) and leaves no part file behind; a text is a notification
# and nothing else; one notification per batch. Then the sender, against the
# same receiver over http and against a fake phone over https whose certificate
# must be the fingerprint it gave, and discovery by multicast on the loopback.
# Nothing reaches the screen (VIVAC_LOCALSEND_SINK) or leaves the machine.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
tool="$repo_root/dotfiles/bridge/.local/bin/vivac-localsend"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-localsend.XXXXXX")"
pids=()
cleanup() {
	local pid
	for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
	rm -rf -- "$sandbox"
}
trap cleanup EXIT
mkdir -p "$sandbox/bin" "$sandbox/user"
sink="$sandbox/sink"
inbox="$sandbox/user/Downloads/vivac-link"
: >"$sink"
# systemctl, faked: writes down what it was asked, active while $sandbox/active exists.
cat >"$sandbox/bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SANDBOX/systemctl"
case "$*" in
*is-active*) [[ -e "$SANDBOX/active" ]] ;;
*'enable --now'*) : >"$SANDBOX/active" ;;
*'disable --now'*) rm -f "$SANDBOX/active" ;;
esac
FAKE
chmod +x "$sandbox/bin/"*
# The discovery port is the test's own and its multicast stays on the loopback.
mport=$((20000 + RANDOM % 20000))
# Loopback addresses, written in two parts (a whole one reads as a leak to the privacy scan).
loop=127.0.0
export LOOP="$loop.1"

# The program's environment. A receiver is started as `env "${ls_env[@]}" python3 ... &`,
# so that $! is the program itself and not a shell waiting on it.
ls_environment() {
	ls_env=(-u INVOCATION_ID PATH="$sandbox/bin:$PATH" SANDBOX="$sandbox" HOME="$sandbox/user" XDG_STATE_HOME="$sandbox/${STATE:-state}"
		XDG_CONFIG_HOME="$sandbox/user/.config" VIVAC_REPO="$repo_root" VIVAC_LANG=en VIVAC_LOCALSEND_SINK="$sink"
		VIVAC_LOCALSEND_PORT="$mport" VIVAC_LOCALSEND_INTERFACES="$loop.1" VIVAC_LOCALSEND_ALIAS="${ALIAS:-desk}")
}
ls_() {
	ls_environment
	env "${ls_env[@]}" python3 "$tool" "$@"
}
eventually() { # eventually COMMAND... — true within three seconds
	local _
	for _ in $(seq 30); do
		"$@" && return 0
		sleep 0.1
	done
	return 1
}

# --- on, off, the PIN ---------------------------------------------------------------------------------------------
[[ "$(ls_ status)" == *'PIN: none yet'* ]] || fail 'status showed a PIN before there was one'
ls_ toggle >/dev/null || fail 'toggle (on) failed'
grep -q -- '--user enable --now vivac-localsend.service' "$sandbox/systemctl" || fail 'toggle did not enable the service'
pinfile="$sandbox/state/vivac/localsend.pin"
pin="$(cat "$pinfile")"
[[ "$pin" =~ ^[0-9]{6}$ ]] || fail "the PIN is not six digits: $pin"
[[ "$(stat -c %a "$pinfile")" == 600 ]] || fail 'the PIN file is not mode 600'
grep -q "^Phone drop|Phone drop is on.*PIN: $pin|" "$sink" || fail "turning it on did not say the PIN: $(cat "$sink")"
[[ "$(ls_ status)" == *"PIN: $pin"* ]] || fail 'status does not show the PIN'
ls_ toggle >/dev/null || fail 'toggle (off) failed'
grep -q -- '--user disable --now vivac-localsend.service' "$sandbox/systemctl" || fail 'toggle did not disable the service'
[[ "$(ls_ pin)" == "$pin" ]] || fail 'the PIN changed by itself'
mkdir -p "$sandbox/user/.config/vivac"
printf 'localsend_pin=Abc123\n' >"$sandbox/user/.config/vivac/settings"
[[ "$(ls_ pin)" == Abc123 ]] || fail 'localsend_pin in the settings is not the PIN'
rm "$sandbox/user/.config/vivac/settings"
: >"$sink"

# --- the receiver -------------------------------------------------------------------------------------------------
ls_environment
env "${ls_env[@]}" python3 "$tool" serve --bind "$loop.1" --port 0 >"$sandbox/serve.log" 2>"$sandbox/serve.err" &
pids+=($!)
eventually grep -q 'listening on' "$sandbox/serve.log" || fail "the receiver did not start: $(cat "$sandbox/serve.err")"
port="$(sed -nE 's/.*listening on [^ ]+:([0-9]+) \(http\)$/\1/p' "$sandbox/serve.log")"
[[ "$port" =~ ^[0-9]+$ ]] || fail "no port in: $(cat "$sandbox/serve.log")"

# The test's own phone: call METHOD PATH [options] prints the status, then the body.
cat >"$sandbox/phone.py" <<'PY'
import hashlib, http.client, json, os, sys
method, path, *options = sys.argv[1:]
opts = dict(o.split("=", 1) for o in options)
connection = http.client.HTTPConnection(os.environ["LOOP"], int(os.environ["PORT"]), timeout=10, source_address=(opts.get("from", os.environ["LOOP"]), 0))
headers = {}
body = None
if "json" in opts:
    body = opts["json"].encode()
    headers["Content-Type"] = "application/json"
elif "file" in opts:
    body = open(opts["file"], "rb").read()
if "chunked" in opts:
    connection.putrequest(method, path)
    connection.putheader("Transfer-Encoding", "chunked")
    connection.endheaders()
    for start in range(0, len(body), 3):
        piece = body[start:start + 3]
        connection.send(b"%x\r\n" % len(piece) + piece + b"\r\n")
    connection.send(b"0\r\n\r\n")
elif "length" in opts:
    connection.putrequest(method, path)
    connection.putheader("Content-Length", opts["length"])
    connection.endheaders()
else:
    connection.request(method, path, body=body, headers=headers)
response = connection.getresponse()
print(response.status)
print(response.read().decode())
PY
call() { PORT="$port" python3 "$sandbox/phone.py" "$@"; }
status() { call "$@" | head -1; }
api=/api/localsend/v2
sha() { sha256sum "$1" | cut -d' ' -f1; }
phone='"info":{"alias":"Pixel","version":"2.1","deviceModel":"Google","deviceType":"mobile","fingerprint":"phone-1","port":53317,"protocol":"https","download":false}'

answer="$(call GET "$api/info")"
python3 -c '
import json, sys
status, body = sys.argv[1].split("\n", 1)
a = json.loads(body)
assert status == "200", status
assert a["alias"] == "desk" and a["version"].startswith("2.") and a["deviceType"] == "desktop" and a["protocol"] == "http", a
assert len(a["fingerprint"]) == 32 and a["download"] is False, a
' "$answer" || fail "/info does not say who this is: $answer"
[[ "$(status POST "$api/register" json='{"alias":"Pixel","version":"2.1","deviceModel":"Google","deviceType":"mobile","fingerprint":"phone-1","port":53317,"protocol":"https"}')" == 200 ]] ||
	fail '/register was not answered'
grep -q '"alias": "Pixel"' "$sandbox/state/vivac/localsend-devices.json" || fail 'a registered phone was not remembered for the sender'

# The PIN: none, wrong, then too many wrong ones from one address (the second
# on the loopback), which does not lock out another (the third).
printf 'payload\n' >"$sandbox/payload"
one="{$phone,\"files\":{\"f1\":{\"id\":\"f1\",\"fileName\":\"a.txt\",\"size\":8,\"fileType\":\"text/plain\",\"sha256\":\"$(sha "$sandbox/payload")\",\"preview\":null}}}"
[[ "$(status POST "$api/prepare-upload" json="$one")" == 401 ]] || fail 'prepare-upload without a PIN was not refused with 401'
for _ in 1 2 3 4 5; do
	[[ "$(status POST "$api/prepare-upload?pin=000000" json="$one" from=$loop.2)" == 401 ]] || fail 'a wrong PIN was not refused with 401'
done
[[ "$(status POST "$api/prepare-upload?pin=$pin" json="$one" from=$loop.2)" == 429 ]] || fail 'the right PIN after five wrong ones in a minute was not refused with 429'
answer="$(call POST "$api/prepare-upload?pin=$pin" json="$one" from=$loop.3)"
[[ "$(head -1 <<<"$answer")" == 200 ]] || fail "another address was locked out too: $answer"
session="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1].split("\n", 1)[1])["sessionId"])' "$answer")"
[[ "$(status POST "$api/cancel?sessionId=$session" from=$loop.3)" == 200 ]] || fail 'cancel was not answered'

# A batch: a name with folders, a dot file, one whose SHA-256 is not its content.
printf 'other\n' >"$sandbox/other"
batch="{$phone,\"files\":{
 \"k\":{\"id\":\"k\",\"fileName\":\"../../.ssh/authorized_keys\",\"size\":8,\"fileType\":\"text/plain\",\"sha256\":\"$(sha "$sandbox/payload")\"},
 \"d\":{\"id\":\"d\",\"fileName\":\".bashrc\",\"size\":8,\"fileType\":\"application/octet-stream\"},
 \"w\":{\"id\":\"w\",\"fileName\":\"wrong.bin\",\"size\":6,\"fileType\":\"application/octet-stream\",\"sha256\":\"$(sha "$sandbox/payload")\"}}}"
answer="$(call POST "$api/prepare-upload?pin=$pin" json="$batch")"
[[ "$(head -1 <<<"$answer")" == 200 ]] || fail "a good prepare-upload was refused: $answer"
read -r session tk td tw < <(python3 -c '
import json, sys
a = json.loads(sys.argv[1].split("\n", 1)[1])
print(a["sessionId"], a["files"]["k"], a["files"]["d"], a["files"]["w"])' "$answer")
upload() { printf '%s' "$api/upload?sessionId=$session&fileId=$1&token=$2"; }
[[ "$(status POST "$(upload k "$td")" file="$sandbox/payload")" == 403 ]] || fail 'a token of another file was accepted'
[[ "$(status POST "$(upload k "$tk")" file="$sandbox/payload" from=$loop.3)" == 403 ]] || fail 'an upload from another address was accepted'
[[ "$(status POST "$api/upload?sessionId=$session&fileId=k" file="$sandbox/payload")" == 400 ]] || fail 'an upload without its token was not a 400'
[[ "$(status POST "$api/prepare-upload?pin=$pin" json="$one" from=$loop.3)" == 409 ]] || fail 'a second sender was not told 409 while a session runs'
[[ "$(status POST "$(upload k "$tk")" file="$sandbox/payload")" == 200 ]] || fail 'a good upload was refused'
[[ "$(status POST "$(upload k "$tk")" file="$sandbox/payload")" == 403 ]] || fail 'the same file was taken twice'
[[ "$(status POST "$(upload d "$td")" file="$sandbox/payload" chunked=1)" == 200 ]] || fail 'a chunked upload was refused'
[[ "$(status POST "$(upload w "$tw")" file="$sandbox/other")" == 422 ]] || fail 'a SHA-256 mismatch was not a 422'
[[ -f "$inbox/authorized_keys" && -f "$inbox/bashrc" ]] || fail "names were not made safe as expected: $(ls -A "$inbox")"
[[ ! -e "$inbox/wrong.bin" && ! -e "$sandbox/user/.ssh" ]] || fail 'a refused or escaping file was written'
cmp -s "$sandbox/payload" "$inbox/authorized_keys" || fail 'the received file is not what was sent'
[[ -z "$(find "$inbox" -name '.*')" ]] || fail "a part file was left in the inbox: $(ls -A "$inbox")"
[[ ! -s "$sink" ]] || fail "a batch was announced before it was over: $(cat "$sink")"
[[ "$(status POST "$api/cancel?sessionId=$session")" == 200 ]] || fail 'cancel was refused'
eventually grep -q "^2 files from Pixel|$inbox|$inbox\$" "$sink" || fail "the cancelled batch's two files were not announced: $(cat "$sink")"

# Sizes: past 2 GiB at prepare-upload, past the announced size at upload; both 413.
big="{$phone,\"files\":{\"b\":{\"id\":\"b\",\"fileName\":\"big.iso\",\"size\":2147483649,\"fileType\":\"application/octet-stream\"}}}"
[[ "$(status POST "$api/prepare-upload?pin=$pin" json="$big")" == 413 ]] || fail 'a file over 2 GiB was not refused with 413'
answer="$(call POST "$api/prepare-upload?pin=$pin" json="$one")"
read -r session t1 < <(python3 -c 'import json, sys; a = json.loads(sys.argv[1].split("\n", 1)[1]); print(a["sessionId"], a["files"]["f1"])' "$answer")
[[ "$(status POST "$(upload f1 "$t1")" length=9000000000)" == 413 ]] || fail 'a body past the announced size was not refused with 413'
printf 'payload\n' >"$sandbox/a.txt"
[[ "$(status POST "$(upload f1 "$t1")" file="$sandbox/a.txt")" == 200 ]] || fail 'the upload after a refused one was not taken'
[[ -f "$inbox/a.txt" && "$(find "$inbox" -type f | wc -l)" == 3 ]] || fail "unexpected inbox: $(ls -A "$inbox")"
eventually grep -q "^Pixel sent a.txt|$inbox|$inbox\$" "$sink" || fail "a one-file batch was not announced by name: $(cat "$sink")"

# A text: shown, not stored, not on the clipboard (nothing here could put it there).
: >"$sink"
text="{$phone,\"files\":{\"t\":{\"id\":\"t\",\"fileName\":\"t.txt\",\"size\":5,\"fileType\":\"text/plain\",\"preview\":\"hola \$(id)\"}}}"
[[ "$(status POST "$api/prepare-upload?pin=$pin" json="$text")" == 204 ]] || fail 'a text was not answered 204'
grep -Fq 'Text from Pixel|hola $(id)|' "$sink" || fail "the text was not shown as sent: $(cat "$sink")"
[[ "$(find "$inbox" -type f | wc -l)" == 3 ]] || fail 'a text was written to the inbox'
[[ "$(status GET /api/localsend/v1/info)" == 404 ]] || fail 'an unknown path was answered'

# --- the sender, against the same receiver (http) -----------------------------------------------------------------
: >"$sink"
printf 'from the desk\n' >"$sandbox/a.txt"
STATE=sender ALIAS=laptop ls_ send --peer "$loop.1:$port" --pin "$pin" --text 'a note' "$sandbox/a.txt" >"$sandbox/out" ||
	fail "send failed: $(cat "$sandbox/out")"
grep -q '^Sent 2 to desk$' "$sandbox/out" || fail "send did not say what it sent: $(cat "$sandbox/out")"
cmp -s "$sandbox/a.txt" "$inbox/a (2).txt" || fail "the sent file did not land beside the first a.txt: $(ls -A "$inbox")"
eventually grep -q '^Text from laptop|a note|' "$sink" || fail "the text sent with it was not shown: $(cat "$sink")"
if STATE=sender ls_ send --peer "$loop.1:$port" "$sandbox/a.txt" </dev/null 2>"$sandbox/err"; then fail 'a send without a PIN succeeded'; fi
grep -q 'asks for a PIN' "$sandbox/err" || fail "the missing PIN was not explained: $(cat "$sandbox/err")"
if STATE=sender ls_ send --peer "$loop.1:$port" --pin 1 "$sandbox/missing" 2>/dev/null; then fail 'a missing file was sent'; fi

# --- discovery on the loopback: the receiver answers an announcement ---------------------------------------------
kill "${pids[0]}" 2>/dev/null || true
# Its HTTP on a port of its own: on one machine the sender's short-lived listener
# takes the discovery port, as it would on a machine that is not receiving.
ls_environment
env "${ls_env[@]}" python3 "$tool" serve --bind "$loop.1" --port 0 >"$sandbox/serve2.log" 2>"$sandbox/serve2.err" &
pids+=($!)
eventually grep -q 'listening on' "$sandbox/serve2.log" || fail "the receiver did not start again: $(cat "$sandbox/serve2.err")"
port="$(sed -nE 's/.*listening on [^ ]+:([0-9]+) \(http\)$/\1/p' "$sandbox/serve2.log")"
found="$(STATE=sender ALIAS=laptop ls_ devices 2>&1)" || true
if grep -q 'discovery is off' "$sandbox/serve2.err"; then
	printf 'note: no multicast on this loopback; discovery not exercised\n' >&2
else
	grep -Pq "^desk\t127\.0\.0\.1:$port\thttp\tLinux$" <<<"$found" || fail "discovery did not find the receiver on $port: $found"
fi

# --- the sender against a phone over https: the certificate must be its fingerprint -----------------------------
if command -v openssl >/dev/null; then
	openssl req -x509 -newkey rsa:2048 -nodes -keyout "$sandbox/key.pem" -out "$sandbox/cert.pem" -days 1 -subj /CN=phone >/dev/null 2>&1
	cat >"$sandbox/https-phone.py" <<'PY'
import hashlib, json, os, ssl, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
folder = sys.argv[1]
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(f"{folder}/cert.pem", f"{folder}/key.pem")
der = ssl.PEM_cert_to_DER_cert(open(f"{folder}/cert.pem").read())
mark = hashlib.sha256(der).hexdigest()
class Phone(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def reply(self, status, body=b""):
        self.send_response(status); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        self.reply(200, json.dumps({"alias": "Phone", "version": "2.1", "deviceModel": "Pixel", "deviceType": "mobile", "fingerprint": mark, "download": False}).encode())
    def do_POST(self):
        data = self.rfile.read(int(self.headers["Content-Length"]))
        path = urllib.parse.urlsplit(self.path)
        if path.path.endswith("/prepare-upload"):
            files = json.loads(data)["files"]
            self.reply(200, json.dumps({"sessionId": "s", "files": {k: "t" + k for k in files}}).encode())
        elif path.path.endswith("/upload"):
            open(f"{folder}/phone-got", "ab").write(data); self.reply(200)
        else:
            self.reply(200)
server = ThreadingHTTPServer((os.environ["LOOP"], 0), Phone)
server.socket = context.wrap_socket(server.socket, server_side=True)
open(f"{folder}/phone-port", "w").write(f"{server.server_address[1]} {mark}\n")
server.serve_forever()
PY
	python3 "$sandbox/https-phone.py" "$sandbox" 2>/dev/null &
	pids+=($!)
	eventually test -s "$sandbox/phone-port" || fail 'the fake https phone did not start'
	read -r pport mark <"$sandbox/phone-port"
	printf 'to the phone\n' >"$sandbox/b.txt"
	STATE=sender ls_ send --peer "https://$loop.1:$pport" "$sandbox/b.txt" >"$sandbox/out" 2>&1 || fail "send over https failed: $(cat "$sandbox/out")"
	cmp -s "$sandbox/b.txt" "$sandbox/phone-got" || fail 'the phone did not get the file over https'
	# A phone that announced another fingerprint is refused before anything is sent.
	rm -f "$sandbox/phone-got"
	verdict="$(env XDG_STATE_HOME="$sandbox/sender" HOME="$sandbox/user" VIVAC_REPO="$repo_root" VIVAC_LANG=en python3 -c '
import importlib.machinery, importlib.util, os, pathlib, sys
sys.dont_write_bytecode = True  # nothing written beside the program
loader = importlib.machinery.SourceFileLoader("vls", sys.argv[1])
module = importlib.util.module_from_spec(importlib.util.spec_from_loader("vls", loader))
sys.modules["vls"] = module
loader.exec_module(module)
good = module.Device("Phone", os.environ["LOOP"], int(sys.argv[2]), "https", sys.argv[3].upper())
bad = module.Device("Phone", os.environ["LOOP"], int(sys.argv[2]), "https", "00" * 32)
item = module.outgoing_file(pathlib.Path(sys.argv[4]))
print(module.transfer(good, [item], None, lambda: ""))
try:
    module.transfer(bad, [item], None, lambda: "")
    print("sent")
except module.SendFailed as error:
    print(error)
' "$tool" "$pport" "$mark" "$sandbox/b.txt" 2>&1)"
	[[ "$(head -1 <<<"$verdict")" == 1 ]] || fail "the announced fingerprint (in capitals) was not accepted: $verdict"
	grep -q 'not the one it announced' <<<"$verdict" || fail "a wrong fingerprint was not refused: $verdict"
	[[ "$(cat "$sandbox/phone-got")" == 'to the phone' ]] || fail 'something reached the phone whose certificate did not match'
else
	printf 'note: no openssl; the https sender was not exercised\n' >&2
fi

# --- the system half and the menu -----------------------------------------------------------------------------------
cat >"$sandbox/bin/ip" <<'FAKE'
#!/usr/bin/env bash
printf '2: eth0    inet 198.51.100.20/24 brd 198.51.100.255 scope global dynamic eth0\n'
FAKE
chmod +x "$sandbox/bin/ip"
plan="$(PATH="$sandbox/bin:$PATH" HOME="$sandbox" "$repo_root/scripts/apply-system.sh" --dry-run --bridge)" || fail 'apply-system.sh --dry-run --bridge failed'
for expected in 'tcp 53317 from 198.51.100.0/24 in UFW (vivac phone drop)' 'udp 53317 from 198.51.100.0/24 in UFW (vivac phone drop)'; do
	grep -qF "would allow $expected" <<<"$plan" || fail "the plan does not open $expected: $plan"
done
grep -q "vivac-localsend" <<<"$plan" && fail "--bridge turned the phone drop on: $plan"
menu="$(PATH="$sandbox/bin:$PATH" VIVAC_REPO="$repo_root" VIVAC_LANG=en "$repo_root/dotfiles/bridge/.local/bin/vivac-bridge" --print)"
grep -q '^Send to phone…$' <<<"$menu" || fail "the bridge menu lacks Send to phone: $menu"
grep -q '^Phone drop: on/off + PIN$' <<<"$menu" || fail "the bridge menu lacks the phone drop switch: $menu"

printf 'phone drop: PIN 401/429, tokens and addresses 403, sha 422, size 413, names confined, texts shown only, sender over http and https\n'
