#!/usr/bin/env bash
# The fakes are shell source written out literally: their $ expands when they run.
# shellcheck disable=SC2016
set -Eeuo pipefail

# vivac link, end to end on the loopback: pairing writes one private file and
# a code that round-trips; the daemon accepts a request signed as docs/bridge.md
# says and refuses a bad signature, a replayed nonce and a stale clock (401), an
# oversized body (413) and an unknown verb or protocol (404). Files land under
# Downloads/vivac-link with the path stripped and never over another; a link is
# only opened on a click; the clipboard goes through wl-copy. The requests here
# are signed by this test, not by the client, so a client and server that agree
# on a wrong signature would still fail.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
tool="$repo_root/dotfiles/bridge/.local/bin/vivac-link"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-link.XXXXXX")"
daemon=''
cleanup() {
	[[ -z "$daemon" ]] || kill "$daemon" 2>/dev/null || true
	rm -rf -- "$sandbox"
}
trap cleanup EXIT
mkdir -p "$sandbox/bin" "$sandbox/user"
calls="$sandbox/calls"
: >"$calls"
# The desktop, faked: wl-copy keeps what it was given, notify-send writes down its
# arguments and clicks "open" while $sandbox/click exists, xdg-open writes down.
cat >"$sandbox/bin/wl-copy" <<'FAKE'
#!/usr/bin/env bash
cat >"$SANDBOX/clipboard"
FAKE
cat >"$sandbox/bin/notify-send" <<'FAKE'
#!/usr/bin/env bash
if [[ "${1:-}" == --help ]]; then printf '  -A, --action=[NAME=]Text...\n'; exit 0; fi
printf 'notify %s\n' "$*" >>"$SANDBOX/calls"
[[ -e "$SANDBOX/click" ]] && printf 'open\n'
exit 0
FAKE
printf '#!/usr/bin/env bash\nprintf "open %%s\\n" "$*" >>"$SANDBOX/calls"\n' >"$sandbox/bin/xdg-open"
chmod +x "$sandbox/bin/"*

link() {
	env -u INVOCATION_ID PATH="$sandbox/bin:$PATH" SANDBOX="$sandbox" HOME="$sandbox/user" XDG_STATE_HOME="$sandbox/${STATE:-state}" \
		XDG_CONFIG_HOME="$sandbox/user/.config" VIVAC_REPO="$repo_root" VIVAC_LANG=en python3 "$tool" "$@"
}
eventually() { # eventually COMMAND... — true within two seconds
	local _
	for _ in $(seq 20); do
		"$@" && return 0
		sleep 0.1
	done
	return 1
}

# --- pairing --------------------------------------------------------------------------------------------------------
out="$(link pair)" || fail 'vivac-link pair failed'
code="$(sed -nE 's/^Pairing code: ([A-Z2-7-]+)$/\1/p' <<<"$out")"
[[ "$code" =~ ^([A-Z2-7]{5}-){10}[A-Z2-7]{2}$ ]] || fail "the pairing code is not 52 base32 characters in fives: $out"
conf="$sandbox/state/vivac/link.conf"
[[ "$(stat -c %a "$conf")" == 600 ]] || fail "link.conf is not mode 600: $(stat -c %a "$conf")"
grep -q '^port=47321$' "$conf" || fail 'link.conf has no default port'
secret="$(sed -n 's/^secret=//p' "$conf")"
[[ "$secret" == "${code//-/}" ]] || fail 'the stored secret is not the printed code'
STATE=other link pair "${code,,}" >/dev/null || fail 'pairing with the code (in lower case) failed'
[[ "$(sed -n 's/^secret=//p' "$sandbox/other/vivac/link.conf")" == "$secret" ]] || fail 'the other side stored a different secret'
if STATE=bad link pair ABCDE-FGHIJ 2>/dev/null; then fail 'a short code was accepted'; fi
[[ ! -e "$sandbox/bad/vivac/link.conf" ]] || fail 'a bad code left a link.conf behind'

# --- the daemon -------------------------------------------------------------------------------------------------
link serve --bind localhost --port 0 --no-beacon >"$sandbox/serve.log" 2>"$sandbox/serve.err" &
daemon=$!
eventually grep -q 'listening on' "$sandbox/serve.log" || fail "the daemon did not start: $(cat "$sandbox/serve.err")"
port="$(sed -nE 's/.*listening on [^ ]+:([0-9]+)$/\1/p' "$sandbox/serve.log")"
[[ "$port" =~ ^[0-9]+$ ]] || fail "no port in: $(cat "$sandbox/serve.log")"

# The test's own signer: request VERB BODY_FILE [options] prints the HTTP status.
cat >"$sandbox/request.py" <<'PY'
import base64, hashlib, hmac, http.client, json, os, secrets, sys, time
from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
verb, body_file, *options = sys.argv[1:]
body = open(body_file, "rb").read() if body_file != "-" else b""
opts = dict(o.split("=", 1) for o in options)
shared = base64.b32decode(os.environ["SECRET"] + "=" * (-len(os.environ["SECRET"]) % 8))
seal_key = hmac.new(shared, b"vivac-link v2 encrypt", hashlib.sha256).digest()
sign_key = hmac.new(shared, b"vivac-link v2 sign", hashlib.sha256).digest()
if "name" in opts:
    body = opts["name"].encode() + b"\0" + body
if "raw" not in opts:
    # AES-256-CBC, PKCS#7, the IV in front: docs/bridge.md, "Requests".
    iv = secrets.token_bytes(16)
    padder = padding.PKCS7(128).padder()
    encryptor = Cipher(algorithms.AES(seal_key), modes.CBC(iv)).encryptor()
    body = iv + encryptor.update(padder.update(body) + padder.finalize()) + encryptor.finalize()
stamp = str(int(time.time()) + int(opts.get("skew", 0)))
nonce = opts.get("nonce") or secrets.token_hex(16)
message = f"v2\n{opts.get('signverb', verb)}\n{stamp}\n{nonce}\n{hashlib.sha256(body).hexdigest()}"
sign = hmac.new(sign_key, message.encode(), hashlib.sha256).hexdigest()
if "badsign" in opts:
    sign = sign[:-1] + ("0" if sign[-1] != "0" else "1")
if "tamper" in opts:
    # Signed as sent, then changed on the way: the signature no longer matches.
    body = body[:-1] + bytes([body[-1] ^ 1])
headers = {"X-Vivac-Time": stamp, "X-Vivac-Nonce": nonce, "X-Vivac-Sign": sign}
connection = http.client.HTTPConnection("localhost", int(os.environ["PORT"]), timeout=10)
path = opts.get("path", f"/v2/{verb}")
if "length" in opts:
    # Only the headers: the receiver must answer from Content-Length alone.
    connection.putrequest("POST", path)
    connection.putheader("Content-Length", opts["length"])
    for name, value in headers.items():
        connection.putheader(name, value)
    connection.endheaders()
else:
    connection.request("POST", path, body=body, headers=headers)
response = connection.getresponse()
answer = response.read()
print(response.status)
if "show" in opts:
    # A 200 is sealed and signed over this request's nonce.
    expected = hmac.new(sign_key, f"v2 answer\n{nonce}\n{hashlib.sha256(answer).hexdigest()}".encode(), hashlib.sha256).hexdigest()
    assert hmac.compare_digest(expected, response.getheader("X-Vivac-Sign", "")), "the answer is not signed"
    decryptor = Cipher(algorithms.AES(seal_key), modes.CBC(answer[:16])).decryptor()
    unpadder = padding.PKCS7(128).unpadder()
    plain = unpadder.update(decryptor.update(answer[16:]) + decryptor.finalize()) + unpadder.finalize()
    print(json.dumps(json.loads(plain)))
PY
request() { SECRET="$secret" PORT="$port" python3 "$sandbox/request.py" "$@"; }
printf 'hello from windows\n' >"$sandbox/clip"

# clip: onto the clipboard through wl-copy, and said so without showing the text.
[[ "$(request clip "$sandbox/clip")" == 200 ]] || fail 'a signed clip was not accepted'
cmp -s "$sandbox/clip" "$sandbox/clipboard" || fail 'the clip did not reach wl-copy as sent'
eventually grep -q 'notify .*put text on your clipboard' "$calls" || fail "the clip was not announced: $(cat "$calls")"
grep -q 'hello from windows' "$calls" && fail 'the clipboard text was shown in a notification'

# 401: a wrong signature, a replay, a clock too far either way, a signature for another verb.
[[ "$(request clip "$sandbox/clip" badsign=1)" == 401 ]] || fail 'a bad signature was not refused'
nonce="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
[[ "$(request clip "$sandbox/clip" nonce="$nonce")" == 200 ]] || fail 'a fresh nonce was refused'
[[ "$(request clip "$sandbox/clip" nonce="$nonce")" == 401 ]] || fail 'a replayed nonce was not refused'
[[ "$(request clip "$sandbox/clip" skew=-90)" == 401 ]] || fail 'a request 90 s old was not refused'
[[ "$(request clip "$sandbox/clip" skew=90)" == 401 ]] || fail 'a request 90 s ahead was not refused'
[[ "$(request clip "$sandbox/clip" skew=-30)" == 200 ]] || fail 'a request 30 s old was refused'
[[ "$(request clip "$sandbox/clip" signverb=ping)" == 401 ]] || fail 'a signature made for another verb was accepted'
[[ "$(request clip "$sandbox/clip" nonce=NOT-A-NONCE)" == 401 ]] || fail 'a malformed nonce was accepted'
[[ "$(request clip "$sandbox/clip" tamper=1)" == 401 ]] || fail 'a body changed after signing was accepted'
# Signed, but not sealed: a sender with the keys who skips the encryption is refused too.
[[ "$(request clip "$sandbox/clip" raw=1)" == 400 ]] || fail 'an unsealed body was accepted'

# 413 on the declared length alone (the limit plus what sealing adds: 1057 bytes);
# 404 for an unknown verb, protocol or method.
[[ "$(request clip - length=66594)" == 413 ]] || fail 'a clip over 64 KiB was not refused'
[[ "$(request notify - length=66594)" == 413 ]] || fail 'a notify over 64 KiB was not refused'
[[ "$(request file - length=67109922)" == 413 ]] || fail 'a file over 64 MiB was not refused'
head -c 65536 /dev/zero | tr '\0' a >"$sandbox/limit"
[[ "$(request clip "$sandbox/limit")" == 200 ]] || fail 'a clip of exactly 64 KiB was refused'
printf 'a' >>"$sandbox/limit"
[[ "$(request clip "$sandbox/limit")" == 400 ]] || fail 'a clip one byte over 64 KiB, sealed, was accepted'
[[ "$(request run "$sandbox/clip")" == 404 ]] || fail 'an unknown verb was not refused with 404'
[[ "$(request clip "$sandbox/clip" path=/v1/clip)" == 404 ]] || fail 'another protocol version was not refused with 404'
[[ "$(python3 -c '
import http.client, sys
connection = http.client.HTTPConnection("localhost", int(sys.argv[1]), timeout=10)
connection.request("GET", "/v2/ping")
print(connection.getresponse().status)' "$port")" == 404 ]] || fail 'a GET was answered'

# file: the path stripped, never over an existing file, no hidden file made.
inbox="$sandbox/user/Downloads/vivac-link"
printf 'payload\n' >"$sandbox/payload"
[[ "$(request file "$sandbox/payload" name=../../.ssh/authorized_keys)" == 200 ]] || fail 'a signed file was not accepted'
[[ "$(request file "$sandbox/payload" name='..\..\Windows\authorized_keys')" == 200 ]] || fail 'a file with a Windows path was not accepted'
[[ "$(request file "$sandbox/payload" name=.bashrc)" == 200 ]] || fail 'a dot file was not accepted'
[[ "$(request file "$sandbox/payload" name='résumé 2026.pdf')" == 200 ]] || fail 'a UTF-8 name was not accepted'
[[ -f "$inbox/authorized_keys" && -f "$inbox/authorized_keys (2)" ]] || fail "files did not land side by side: $(ls -A "$inbox")"
[[ -f "$inbox/bashrc" && -f "$inbox/résumé 2026.pdf" ]] || fail "names were not made safe as expected: $(ls -A "$inbox")"
[[ ! -e "$sandbox/user/.ssh" && ! -e "$sandbox/user/.bashrc" ]] || fail 'a received file escaped Downloads/vivac-link'
[[ "$(find "$inbox" -type f | wc -l)" == 4 ]] || fail "unexpected files in the inbox: $(ls -A "$inbox")"
cmp -s "$sandbox/payload" "$inbox/authorized_keys" || fail 'the received file is not what was sent'
eventually grep -q 'notify .*sent résumé 2026.pdf' "$calls" || fail "the file was not announced: $(cat "$calls")"

# url: a notification, opened only on a click; only http and https.
: >"$calls"
printf 'https://example.org/a?b=c' >"$sandbox/url"
[[ "$(request url "$sandbox/url")" == 200 ]] || fail 'a signed url was not accepted'
eventually grep -q 'notify .*--action=open=Open .*sent a link https://example.org/a?b=c' "$calls" || fail "the link was not offered: $(cat "$calls")"
sleep 0.3
grep -q '^open' "$calls" && fail 'a link was opened without a click'
: >"$sandbox/click"
[[ "$(request url "$sandbox/url")" == 200 ]] || fail 'a second url was not accepted'
eventually grep -Fxq 'open https://example.org/a?b=c' "$calls" || fail "a clicked link was not opened: $(cat "$calls")"
rm -f "$sandbox/click"
printf 'javascript:alert(1)' >"$sandbox/url"
[[ "$(request url "$sandbox/url")" == 400 ]] || fail 'a javascript: link was accepted'
printf 'file:///etc/passwd' >"$sandbox/url"
[[ "$(request url "$sandbox/url")" == 400 ]] || fail 'a file: link was accepted'

# notify and ping.
: >"$calls"
printf '{"title":"Build done","body":"$(id) stays text"}' >"$sandbox/note"
[[ "$(request notify "$sandbox/note")" == 200 ]] || fail 'a signed notify was not accepted'
eventually grep -Fq 'notify --app-name=vivac -- Build done $(id) stays text' "$calls" || fail "the notification was not shown as sent: $(cat "$calls")"
answer="$(request ping - show=1)"
[[ "$(head -1 <<<"$answer")" == 200 ]] || fail 'a signed ping was not answered'
python3 -c '
import json, sys
a = json.loads(sys.argv[1])
assert a["ok"] is True and a["os"] == "linux" and a["protocol"] == 2 and a["name"] and a["version"] and "mac" in a, a
' "$(tail -1 <<<"$answer")" || fail "the ping answer lacks name, system or version: $answer"

# --- the client, against the same daemon --------------------------------------------------------------------------
printf 'peer=localhost:%s\n' "$port" >>"$conf"
[[ "$(link ping)" == *'(linux, vivac '* ]] || fail 'vivac-link ping did not print the answer'
[[ "$(link status)" == *"Peer: localhost:$port"* ]] || fail 'vivac-link status did not name the peer'
link send-clip 'from the client' >/dev/null || fail 'vivac-link send-clip failed'
[[ "$(cat "$sandbox/clipboard")" == 'from the client' ]] || fail 'send-clip did not reach the clipboard'
printf 'data' >"$sandbox/a report.txt"
link send-file "$sandbox/a report.txt" >/dev/null || fail 'vivac-link send-file failed'
cmp -s "$sandbox/a report.txt" "$inbox/a report.txt" || fail 'send-file did not deliver the file under its name'
link notify Title Body >/dev/null || fail 'vivac-link notify failed'
if link send-url 'ftp://example.org' 2>/dev/null; then fail 'send-url accepted an ftp link'; fi
# A client paired with another code is refused.
STATE=stranger link pair >/dev/null
printf 'peer=localhost:%s\n' "$port" >>"$sandbox/stranger/vivac/link.conf"
if STATE=stranger link ping 2>"$sandbox/err"; then fail 'a client with another pairing was answered'; fi
grep -q 'refused it' "$sandbox/err" || fail "the refusal was not explained: $(cat "$sandbox/err")"

# An answer not signed with the pairing's keys is not taken: a stand-in on the port.
python3 -c '
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        data = b"\0" * 32
        self.send_response(200); self.send_header("Content-Length", "32"); self.send_header("X-Vivac-Sign", "0" * 64); self.end_headers(); self.wfile.write(data)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("localhost", 0), H); print(s.server_address[1], flush=True); s.handle_request()' >"$sandbox/fake.port" &
eventually test -s "$sandbox/fake.port" || fail 'the stand-in did not start'
sed -i "s/^peer=.*/peer=localhost:$(cat "$sandbox/fake.port")/" "$conf"
if link ping 2>"$sandbox/err"; then fail 'an unsigned answer was taken'; fi
grep -q 'not trusted' "$sandbox/err" || fail "the unsigned answer was not explained: $(cat "$sandbox/err")"

# wake: needs the address a ping learnt; sends the magic packet (6 x FF, the address x 16).
if link wake 2>"$sandbox/err"; then fail 'wake ran without a known address'; fi
grep -q 'not known yet' "$sandbox/err" || fail "wake did not say why: $(cat "$sandbox/err")"
# Put together, not written out: a hardware address in the tree is what the privacy scan looks for.
printf '%s:%s\n' 0a:1b:2c 3d:4e:5f >"$sandbox/state/vivac/link-peer-mac"
python3 -c '
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("localhost", 0)); print(s.getsockname()[1], flush=True)
s.settimeout(5); data, _ = s.recvfrom(200)
print(data.hex(), flush=True)' >"$sandbox/wol" &
eventually test -s "$sandbox/wol" || fail 'the packet listener did not start'
VIVAC_WAKE_TARGET="localhost:$(head -1 "$sandbox/wol")" link wake >/dev/null || fail 'vivac-link wake failed'
eventually test "$(wc -l <"$sandbox/wol")" -ge 2 || fail 'no magic packet arrived'
[[ "$(sed -n 2p "$sandbox/wol")" == "ffffffffffff$(printf '0a1b2c3d4e5f%.0s' {1..16})" ]] || fail "the magic packet is wrong: $(sed -n 2p "$sandbox/wol")"

kill "$daemon" 2>/dev/null || true
wait "$daemon" 2>/dev/null || true
daemon=''
printf 'vivac link: pairing round-trips, sealed and signed requests accepted, answers verified, wake sent, 401/413/404 as specified, files confined, links only on a click\n'
