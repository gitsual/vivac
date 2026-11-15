#!/usr/bin/env bash
# The fakes are shell source written out literally: their $ expands when they run.
# shellcheck disable=SC2016
set -Eeuo pipefail

# vivac-mcp: the phone as an MCP server over stdio (JSON-RPC 2.0, one message
# per line). Against fake termux-* commands: initialize answers with the tools
# capability; notifications get no answer; tools/list names every tool with a
# schema; read tools return the command's output; action tools run the right
# command with the arguments given and nothing else; a bad URL, an unknown
# tool or a failing command come back as isError instead of killing the
# server; an unknown method is a JSON-RPC error; wifi info drops MAC/BSSID.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
tool="$repo_root/bin/vivac-mcp"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-mcp.XXXXXX")"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/bin"
export CALLS="$sandbox/calls"
: >"$CALLS"

# Every fake writes "name args..." to $CALLS (one arg per tab) and prints
# what the real one would.
fake() {
	printf '#!/usr/bin/env bash\n(IFS=$'"'"'\\t'"'"'; printf "%%s\\t%%s\\n" "%s" "$*") >>"$CALLS"\n%s\n' "$1" "$2" >"$sandbox/bin/$1"
	chmod +x "$sandbox/bin/$1"
}
fake termux-battery-status 'echo "{\"percentage\":55,\"status\":\"DISCHARGING\"}"'
fake termux-notification-list 'echo "[{\"title\":\"Hola\",\"content\":\"mundo\",\"packageName\":\"org.thoughtcrime.securesms\"}]"'
fake termux-clipboard-get 'echo "copied text"'
fake termux-clipboard-set 'cat >/dev/null'
fake termux-location 'echo "{\"latitude\":40.4,\"longitude\":-3.7,\"accuracy\":12}"'
fake termux-wifi-connectioninfo 'echo "{\"ssid\":\"casa\",\"bssid\":\"BSSID-VALUE\",\"mac_address\":\"MAC-VALUE\",\"ip\":\"203.0.113.50\",\"rssi\":-50}"'
fake termux-notification 'true'
fake termux-vibrate 'true'
fake termux-torch 'true'
fake termux-tts-speak 'true'
fake termux-open-url 'true'
fake termux-camera-photo 'touch "${@: -1}"'
cat >"$sandbox/bin/vivac-facts" <<'FAKE'
#!/usr/bin/env bash
echo '{"model":"Pixel 8"}'
FAKE
chmod +x "$sandbox/bin/vivac-facts"

run() { printf '%s\n' "$@" |
	PATH="$sandbox/bin:$PATH" VIVAC_FACTS="$sandbox/bin/vivac-facts" VIVAC_PHOTO_DIR="$sandbox/photos" python3 "$tool"; }
# reply ID: the JSON line answering request ID
reply() { python3 -c '
import json, sys
for line in sys.argv[2].splitlines():
    m = json.loads(line)
    if m.get("id") == int(sys.argv[1]):
        print(json.dumps(m)); break
else:
    sys.exit("no reply for id " + sys.argv[1])' "$1" "$out"; }
expect() { python3 -c "import json,sys; m=json.loads(sys.argv[1]); assert $2, m" "$(reply "$1")" ||
	fail "mcp: $3"; }
call() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "$1" "$2" "$3"; }

out="$(run \
	'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' \
	'{"jsonrpc":"2.0","method":"notifications/initialized"}' \
	'{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
	'{"jsonrpc":"2.0","id":3,"method":"ping"}' \
	"$(call 4 battery '{}')" \
	"$(call 5 device_info '{}')" \
	"$(call 6 notifications '{}')" \
	"$(call 7 wifi '{}')" \
	"$(call 8 notify '{"title":"Hermes","body":"hola"}')" \
	"$(call 9 open_url '{"url":"file:///etc/passwd"}')" \
	"$(call 10 nope '{}')" \
	'{"jsonrpc":"2.0","id":11,"method":"resources/list"}' \
	"$(call 12 clipboard_set '{"text":"x"}')" \
	"$(call 13 photo '{"camera":"front"}')" \
	"$(call 14 vibrate '{"ms":99999}')" \
	'not json at all' \
	"$(call 15 clipboard_get '{}')")" || fail "vivac-mcp exited non-zero"

lines="$(printf '%s\n' "$out" | grep -c .)"
# 15 requests; the notification gets nothing; the garbage line gets a parse error.
[[ "$lines" == 16 ]] || fail "expected 16 answers, got $lines: $out"

expect 1 'm["result"]["protocolVersion"] == "2025-06-18" and "tools" in m["result"]["capabilities"] and m["result"]["serverInfo"]["name"] == "vivac-phone"' 'initialize'
expect 2 'set(t["name"] for t in m["result"]["tools"]) == {"device_info","battery","location","notifications","clipboard_get","wifi","notify","clipboard_set","vibrate","torch","tts_speak","photo","open_url"} and all(t["inputSchema"]["type"] == "object" and t["description"] for t in m["result"]["tools"])' 'tools/list'
expect 2 'all(t["annotations"]["readOnlyHint"] is (t["name"] in {"device_info","battery","location","notifications","clipboard_get","wifi"}) for t in m["result"]["tools"])' 'readOnlyHint marks exactly the read tools (Hermes asks before the rest on a trust: untrusted server)'
expect 3 'm["result"] == {}' 'ping'
expect 4 '"55" in m["result"]["content"][0]["text"] and not m["result"].get("isError")' 'battery'
expect 5 '"Pixel 8" in m["result"]["content"][0]["text"]' 'device_info'
expect 6 '"mundo" in m["result"]["content"][0]["text"]' 'notifications'
expect 7 '"casa" in m["result"]["content"][0]["text"] and "BSSID-VALUE" not in m["result"]["content"][0]["text"] and "MAC-VALUE" not in m["result"]["content"][0]["text"]' 'wifi drops MAC and BSSID'
expect 8 'not m["result"].get("isError")' 'notify'
expect 9 'm["result"]["isError"] is True' 'open_url refuses non-http'
expect 10 'm["result"]["isError"] is True' 'unknown tool'
expect 11 'm["error"]["code"] == -32601' 'unknown method'
expect 12 'not m["result"].get("isError")' 'clipboard_set'
expect 13 '"/photos/" in m["result"]["content"][0]["text"] and m["result"]["content"][0]["text"].endswith(".jpg")' 'photo returns its path'
expect 15 '"copied text" in m["result"]["content"][0]["text"]' 'clipboard_get'
printf '%s\n' "$out" | grep -q '"code": -32700' || fail "mcp: garbage line must get a parse error"

calls="$(cat "$CALLS")"
tab=$'\t'
grep -qxF "termux-notification${tab}--title${tab}Hermes${tab}--content${tab}hola" <<<"$calls" || fail "notify ran: $calls"
grep -q '^termux-open-url' <<<"$calls" && fail "open_url ran a refused URL"
grep -q "^termux-camera-photo${tab}-c${tab}1${tab}" <<<"$calls" || fail "photo front camera must be -c 1: $calls"
grep -qxF "termux-vibrate${tab}-d${tab}5000" <<<"$calls" || fail "vibrate must be capped at 5000 ms: $calls"

# A failing command is an isError result, not a dead server.
fake termux-battery-status 'echo boom >&2; exit 3'
out="$(run "$(call 1 battery '{}')" '{"jsonrpc":"2.0","id":2,"method":"ping"}')"
expect 1 'm["result"]["isError"] is True and "boom" in m["result"]["content"][0]["text"]' 'failing command'
expect 2 'm["result"] == {}' 'server alive after a failing command'
