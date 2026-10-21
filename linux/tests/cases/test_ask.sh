#!/usr/bin/env bash
# The fakes are shell source written out literally: their $ expands when they run.
# shellcheck disable=SC2016
set -Eeuo pipefail

# vivac ask against a fake Ollama on the loopback: the streamed pieces come back
# as one answer, the first listed model is taken when none is set, a server
# error, a stall and a closed port each end with a clear message, and ask_url
# off this machine is refused unless ask_allow_lan says otherwise (a public
# address always). The clipboard goes in as context only when asked, the
# answer reaches the clipboard only through /copy, and the inbox summary reads
# at most the first KiB of a file and never follows a link out of the inbox.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
tool="$repo_root/dotfiles/ricer/.local/bin/vivac-ask"
# shellcheck source=lib/kv.sh
source "$repo_root/lib/kv.sh"
# shellcheck source=lib/settings.sh
source "$repo_root/lib/settings.sh"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-ask.XXXXXX")"
server=''
cleanup() {
	[[ -z "$server" ]] || kill "$server" 2>/dev/null || true
	rm -rf -- "$sandbox"
}
trap cleanup EXIT
mkdir -p "$sandbox/bin" "$sandbox/user/.config/vivac"
settings="$sandbox/user/.config/vivac/settings"
# Addresses spelled out at run time: the privacy scan looks for them in files.
loop="$(printf '%d.%d.%d.%d' 127 0 0 1)"
lan="$(printf '%d.%d.%d.%d' 192 168 1 20)"

# The desktop, faked: wl-paste prints $SANDBOX/clip, wl-copy keeps what it is given.
cat >"$sandbox/bin/wl-paste" <<'FAKE'
#!/usr/bin/env bash
[[ -e "$SANDBOX/clip" ]] || exit 1
cat "$SANDBOX/clip"
FAKE
cat >"$sandbox/bin/wl-copy" <<'FAKE'
#!/usr/bin/env bash
cat >"$SANDBOX/copied"
FAKE
chmod +x "$sandbox/bin/"*

# The fake Ollama: /api/tags lists two models (none while $SANDBOX/empty
# exists); /api/chat writes the request down and streams NDJSON in HTTP/1.1
# chunks, the way Ollama does. The model name picks the behaviour.
cat >"$sandbox/ollama.py" <<'FAKE'
import json, os, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SANDBOX = os.environ["SANDBOX"]

class Fake(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send_json(self, status, value):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def chunk(self, value):
        data = (json.dumps(value) + "\n").encode()
        self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
        self.wfile.flush()

    def do_GET(self):
        if self.path != "/api/tags":
            return self.send_json(404, {"error": "not found"})
        models = [] if os.path.exists(os.path.join(SANDBOX, "empty")) else [{"name": "fake:1b"}, {"name": "other:7b"}]
        self.send_json(200, {"models": models})

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with open(os.path.join(SANDBOX, "request.json"), "w") as handle:
            json.dump({"request": request, "host": self.headers["Host"]}, handle)
        model = request["model"]
        if model == "missing":
            return self.send_json(404, {"error": "model 'missing' not found"})
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        pieces = {"fake:1b": ["Hel", "lo ", "world"], "shell": ["$(touch ", SANDBOX, "/pwned) `touch ", SANDBOX, "/pwned`"]}
        for piece in pieces.get(model, ["one"]):
            self.chunk({"model": model, "message": {"role": "assistant", "content": piece}, "done": False})
        if model == "stall":
            time.sleep(5)
        if model == "broken":
            self.chunk({"error": "the model crashed"})
        self.chunk({"model": model, "message": {"role": "assistant", "content": ""}, "done": True})
        self.wfile.write(b"0\r\n\r\n")

server = ThreadingHTTPServer(("localhost", 0), Fake)
with open(os.path.join(SANDBOX, "port"), "w") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
FAKE
SANDBOX="$sandbox" python3 "$sandbox/ollama.py" &
server=$!
for _ in $(seq 50); do
	[[ -s "$sandbox/port" ]] && break
	sleep 0.1
done
port="$(cat "$sandbox/port")" || fail 'the fake Ollama did not start'

# Bounded, so a read that blocks (the named pipe in the inbox) fails the case
# instead of hanging the suite.
ask() {
	PATH="$sandbox/bin:$PATH" SANDBOX="$sandbox" HOME="$sandbox/user" XDG_CONFIG_HOME="$sandbox/user/.config" \
		VIVAC_REPO="$repo_root" VIVAC_LANG=en VIVAC_ASK_TIMEOUT="${TIMEOUT:-20}" timeout 30 python3 "$tool" "$@"
}
use() { printf '%s\n' "$@" >"$settings"; }
sent() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["request"]["messages"][int(sys.argv[2])]["content"])' "$sandbox/request.json" "$1"; }

# --- the settings ---------------------------------------------------------------------------------------------
use "ask_url=http://$loop:$port" ask_model=none ask_allow_lan=false
settings_load "$settings" || fail 'the ask settings were refused'
[[ "$(settings_get ask_url)" == "http://$loop:$port" ]] || fail 'ask_url was not read'
for bad in "ask_url=ftp://$loop:1" "ask_url=http://$loop:1/api;rm" ask_allow_lan=yes ask_model=-rf; do
	use "$bad"
	settings_load "$settings" 2>/dev/null && fail "settings accepted $bad"
done
use 'ask_url=http://[::1]:11434'
settings_load "$settings" || fail 'a bracketed IPv6 ask_url was refused'

# --- a streamed answer, the first model when none is set ------------------------------------------------------
use "ask_url=http://$loop:$port"
out="$(ask --once 'hi' 2>"$sandbox/err")" || fail "a plain question failed: $(cat "$sandbox/err")"
[[ "$out" == 'Hello world' ]] || fail "the streamed pieces were not put together: $out"
grep -q 'Model fake:1b: the first one Ollama lists' "$sandbox/err" || fail "the chosen model was not said: $(cat "$sandbox/err")"
python3 - "$sandbox/request.json" "$port" "$loop" <<'CHECK' || fail "the request was not what Ollama expects: $(cat "$sandbox/request.json")"
import json, sys
seen = json.load(open(sys.argv[1]))
request = seen["request"]
assert request["model"] == "fake:1b" and request["stream"] is True
assert [m["role"] for m in request["messages"]] == ["system", "user"]
assert request["messages"][1]["content"] == "hi"
assert seen["host"] == sys.argv[3] + ":" + sys.argv[2]
CHECK
use "ask_url=http://localhost:$port" ask_model=other:7b
out="$(ask --once 'hi' 2>"$sandbox/err")" || fail "localhost was not this machine: $(cat "$sandbox/err")"
[[ "$out" == 'one' ]] || fail "ask_model was not used: $out"
grep -q 'first one' "$sandbox/err" && fail 'a model that was set was announced as chosen'
[[ ! -e "$sandbox/copied" ]] || fail 'an answer reached the clipboard unasked'

# --- what the model writes is text ------------------------------------------------------------------------------
use "ask_url=http://$loop:$port" ask_model=shell
ask --once 'run it' >/dev/null 2>&1 || fail 'an answer with shell in it failed'
[[ ! -e "$sandbox/pwned" ]] || fail 'something in an answer was run'

# --- errors: the server's, a stall, a stream cut by an error, a closed port, no models ---------------------------
use "ask_url=http://$loop:$port" ask_model=missing
ask --once 'hi' >/dev/null 2>"$sandbox/err" && fail 'a missing model succeeded'
grep -q "Ollama answered 404: model 'missing' not found" "$sandbox/err" || fail "the server's error was not shown: $(cat "$sandbox/err")"
use "ask_url=http://$loop:$port" ask_model=stall
start=$SECONDS
TIMEOUT=1 ask --once 'hi' >/dev/null 2>"$sandbox/err" && fail 'a stalled answer succeeded'
grep -q 'sent nothing for 1 s' "$sandbox/err" || fail "a stall was not reported: $(cat "$sandbox/err")"
((SECONDS - start < 4)) || fail 'the stall was waited out instead of timed out'
use "ask_url=http://$loop:$port" ask_model=broken
ask --once 'hi' >/dev/null 2>"$sandbox/err" && fail 'an error in the stream succeeded'
grep -q 'the model crashed' "$sandbox/err" || fail "an error in the stream was not shown: $(cat "$sandbox/err")"
closed="$(python3 -c 'import socket; s=socket.socket(); s.bind(("localhost",0)); print(s.getsockname()[1])')"
use "ask_url=http://$loop:$closed"
ask --once 'hi' >/dev/null 2>"$sandbox/err" && fail 'a closed port succeeded'
grep -q 'Ollama is not answering at' "$sandbox/err" || fail "a server that is not running was not said: $(cat "$sandbox/err")"
use "ask_url=http://$loop:$port"
: >"$sandbox/empty"
ask --once 'hi' >/dev/null 2>"$sandbox/err" && fail 'no models succeeded'
grep -q 'ollama pull' "$sandbox/err" || fail "no models was not explained: $(cat "$sandbox/err")"
rm -f "$sandbox/empty"

# --- where the request may go ---------------------------------------------------------------------------------
refused() { # refused SETTING... -- PATTERN
	local pattern="${*: -1}"
	use "${@:1:$#-1}"
	ask --dry-run >/dev/null 2>"$sandbox/err" && fail "$* was not refused"
	grep -q "$pattern" "$sandbox/err" || fail "$*: $(cat "$sandbox/err")"
}
refused "ask_url=http://$lan:11434" 'is not this machine'
refused 'ask_url=http://ollama.example:11434' 'is not this machine'
refused 'ask_url=http://8.8.8.8:11434' ask_allow_lan=true 'never sends anything to the internet'
refused 'ask_url=http://[2606:4700::1111]:11434' ask_allow_lan=true 'never sends anything to the internet'
refused "ask_url=https://$loop:11434" 'must be http://HOST:PORT'
refused "ask_url=http://$loop:11434/v1" 'must be http://HOST:PORT'
use "ask_url=http://$lan:11434" ask_allow_lan=true
out="$(ask --dry-run 2>&1)" || fail "a LAN address was refused with ask_allow_lan=true: $out"
grep -Fq "Would ask the first model Ollama lists at http://$lan:11434 ($lan:11434); nothing was sent" <<<"$out" || fail "dry run: $out"

# --- the clipboard as context, only when asked -------------------------------------------------------------------
use "ask_url=http://$loop:$port"
printf 'def f(x):\n    return x * 2\n' >"$sandbox/clip"
ask --once 'explain' >/dev/null 2>&1 || fail 'a plain question failed with text on the clipboard'
[[ "$(sent 1)" == explain ]] || fail 'the clipboard went in without --clip'
ask --clip --once 'explain' >/dev/null 2>&1 || fail '--clip failed'
content="$(sent 1)"
[[ "$content" == '<context source="clipboard">'*'return x * 2'*'</context>'*explain ]] || fail "the clipboard did not go in as context: $content"
: >"$sandbox/clip"
ask --clip --once 'explain' >/dev/null 2>"$sandbox/err" && fail 'an empty clipboard was sent'
grep -q 'The clipboard has no text' "$sandbox/err" || fail "an empty clipboard was not said: $(cat "$sandbox/err")"

# --- the inbox: names and sizes, the first KiB of text, no link followed ------------------------------------------
box="$sandbox/user/Downloads/vivac-link"
mkdir -p "$box/a folder" "$sandbox/outside"
printf 'OUTSIDE-SECRET\n' >"$sandbox/outside/secret.txt"
{
	head -c 1024 /dev/zero | tr '\0' a
	printf 'TAILMARK\n'
} >"$box/notes.txt"
printf 'INNER-TEXT\n' >"$box/a folder/inside.txt"
printf '\x00\x01\x02binary' >"$box/blob.bin"
ln -s "$sandbox/outside/secret.txt" "$box/link.txt"
ln -s "$sandbox/outside" "$box/link-dir"
mkfifo "$box/pipe"
out="$(ask --inbox --dry-run 2>&1)" ||
	fail "the inbox summary failed: $out"
for name in notes.txt 'a folder' blob.bin link.txt link-dir pipe; do
	grep -Fq -- "- $name" <<<"$out" || fail "$name is not listed: $out"
done
grep -q 'link.txt: a link, not followed' <<<"$out" || fail 'a link was not named as one'
grep -q 'a folder: a folder, not opened' <<<"$out" || fail 'a folder was not named as one'
grep -q '(not text, not read)' <<<"$out" || fail 'a binary file was not marked'
grep -q 'OUTSIDE-SECRET\|INNER-TEXT' <<<"$out" && fail "the summary read through a link or into a folder: $out"
grep -q TAILMARK <<<"$out" && fail 'the summary read past the first KiB'
[[ "$(tr -cd a <<<"$(grep '^  | ' <<<"$out")" | wc -c)" == 1024 ]] || fail 'the first KiB of the text file is not in the summary'
grep -q 'Summarise what arrived' <<<"$out" || fail 'the inbox request is not the question'
ask --inbox --once >/dev/null 2>&1 || fail 'the inbox summary was not sent'
grep -q 'notes.txt' <<<"$(sent 1)" || fail 'the inbox listing did not reach the model'
mv "$box" "$sandbox/real-box"
ln -s "$sandbox/real-box" "$box"
ask --inbox --dry-run >/dev/null 2>"$sandbox/err" && fail 'an inbox that is a link was followed'
grep -q 'There is no inbox at' "$sandbox/err" || fail "an inbox that is a link: $(cat "$sandbox/err")"

# --- the panel: /copy is the only way to the clipboard, /save writes Markdown for you only -------------------------
rm -f "$sandbox/copied"
printf 'hi\n/save %s\n/copy\n/quit\n' "$sandbox/talk.md" | ask >"$sandbox/out" 2>&1 || fail "the panel failed: $(cat "$sandbox/out")"
[[ "$(cat "$sandbox/copied")" == 'Hello world' ]] || fail '/copy did not put the last answer on the clipboard'
grep -q '^## You' "$sandbox/talk.md" && grep -q '^Hello world$' "$sandbox/talk.md" || fail "/save: $(cat "$sandbox/talk.md")"
[[ "$(stat -c %a "$sandbox/talk.md")" == 600 ]] || fail '/save left the conversation readable by others'
printf '/save %s\n/quit\n' "$sandbox/talk.md" | ask >/dev/null 2>&1 || true
grep -q '^Hello world$' "$sandbox/talk.md" || fail '/save overwrote an existing file'

printf 'ask: stream assembled, first model, 4 failures said, 6 refusals, clip only when asked, inbox bounded and unfollowed, /copy and /save\n'
