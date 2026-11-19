#!/bin/zsh
# End-to-end test of drifted-host through the fake relay (relay/tools/fake_relay.py). No hardware and no Bluetooth:
# drifted-host runs from the build directory with its own state dir and port, so a Drifted app already running
# on this Mac (and its table connection) is untouched.
#
# Checks: connects and handshakes through the relay; stays ready (keepalive across TCP); /status reports the relay
# and its signal; a drawing uploads and plays; recovers when the relay loses the table and when the TCP
# connection drops; /relay and /relay/command work; nothing sends forbidden commands.
#
# Usage: relay/tools/test-fake-relay.sh        (RELAY_PORT / HTTP_PORT override the ports; KEEP=1 keeps the logs)
set -uo pipefail
cd "$(dirname "$0")/../.."
RELAY_PORT=${RELAY_PORT:-18766}
HTTP_PORT=${HTTP_PORT:-18765}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/drifted-relay-test.XXXXXX")
STATE=$WORK/state
mkdir -p "$STATE"
TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(16))')
failed=0

print "Building drifted-host…"
swift build --product drifted-host >"$WORK/build.log" 2>&1 || { print -u2 "build failed; see $WORK/build.log"; exit 1; }
BIN="$(swift build --show-bin-path)/drifted-host"

print "{\"enabled\": true, \"host\": \"127.0.0.1\", \"port\": $RELAY_PORT, \"token\": \"$TOKEN\"}" >"$STATE/relay.json"
python3 relay/tools/fake_relay.py --token "$TOKEN" --port "$RELAY_PORT" --stats "$WORK/stats.json" >"$WORK/relay.log" 2>&1 &
RELAY_PID=$!
sleep 0.5
"$BIN" --port "$HTTP_PORT" --state "$STATE" >"$WORK/host.log" 2>&1 &
HOST_PID=$!

cleanup() {
  kill $HOST_PID $RELAY_PID 2>/dev/null
  wait $HOST_PID $RELAY_PID 2>/dev/null
  if (( failed )) || [[ -n "${KEEP:-}" ]]; then print "Logs kept in $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

ok() { print "  ✓ $1"; }
bad() { print -u2 "  ✘ $1"; failed=1; }

api() {   # api METHOD PATH [JSON]
  local auth="Authorization: Bearer $(cat "$STATE/token" 2>/dev/null)"
  if [[ $# -ge 3 ]]; then
    curl -s -m 60 -X "$1" -H "$auth" -H "Content-Type: application/json" -d "$3" "http://127.0.0.1:$HTTP_PORT$2"
  else
    curl -s -m 60 -X "$1" -H "$auth" "http://127.0.0.1:$HTTP_PORT$2"
  fi
}
# jq-free JSON access: field 'expr' evaluated with the document as d
field() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null; }
connection() { api GET /status | field 'd["connection"]'; }
stat() { python3 -c "import json; d=json.load(open('$WORK/stats.json')); print($1)"; }

wait_for() {   # wait_for SECONDS 'shell condition'
  local deadline=$(( SECONDS + $1 ))
  while (( SECONDS < deadline )); do eval "$2" && return 0; sleep 0.5; done
  return 1
}

print "Waiting for drifted-host to reach the table through the fake relay…"
if wait_for 40 '[[ "$(connection)" == ready ]]'; then ok "ready through the relay"; else bad "never ready (connection: $(connection))"; fi

S=$(api GET /status)
[[ "$(print -r -- $S | field 'd["link"]["via"]')" == relay ]] && ok "/status link.via = relay" || bad "/status link: $(print -r -- $S | field 'd.get("link")')"
[[ "$(print -r -- $S | field 'd["link"]["rssi"]')" == -58 && "$(print -r -- $S | field 'd["rssi"]')" == -58 ]] \
  && ok "/status reports the relay's signal to the table (-58 dBm)" || bad "rssi missing: $(print -r -- $S | field 'd["link"]')"
[[ "$(print -r -- $S | field 'd["device"]')" == KS0000000001 ]] && ok "table name comes through" || bad "device: $(print -r -- $S | field 'd["device"]')"
[[ "$(print -r -- $S | field 'd["storedPatterns"]')" == 3 ]] && ok "init dump parsed (3 stored patterns)" || bad "storedPatterns: $(print -r -- $S | field 'd["storedPatterns"]')"

print "Holding the session for 12 s (the table resets after 2 s without host frames)…"
resets=$(stat 'd["sessionResets"]')
sleep 12
[[ "$(connection)" == ready && "$(stat 'd["sessionResets"]')" == "$resets" ]] \
  && ok "stayed ready, no session resets; longest host silence $(stat 'd["maxHostSilenceMs"]') ms" \
  || bad "session reset while idle (resets $(stat 'd["sessionResets"]'))"

print "Drawing a circle…"
CIRCLE='{"name":"relay-test","xy":[[0.3,0],[0,0.3],[-0.3,0],[0,-0.3],[0.3,0]]}'
J=$(api POST '/show?wait=true' "$CIRCLE")
if [[ "$(print -r -- $J | field 'd["state"]')" == done ]]; then ok "show: uploaded to $(print -r -- $J | field 'd["result"]["id"]') and playing"; else bad "show failed: $J"; fi
[[ "$(stat 'len(d["uploadsStored"])')" -ge 1 && "$(stat 'len(d["plays"])')" -ge 1 ]] && ok "fake table stored and drew it" || bad "table didn't store/draw"

print "Relay loses the table for 3 s…"
kill -USR1 $RELAY_PID
wait_for 6 '[[ "$(connection)" != ready ]]' && ok "drifted-host noticed the dropped link" || bad "didn't notice the dropped link"
wait_for 40 '[[ "$(connection)" == ready ]]' && ok "ready again after the relay relinked" || bad "not ready after relink ($(connection))"

print "TCP connection to the relay drops…"
kill -USR2 $RELAY_PID
wait_for 6 '[[ "$(connection)" != ready ]]' && ok "drifted-host noticed the closed connection" || bad "didn't notice the closed connection"
wait_for 40 '[[ "$(connection)" == ready ]]' && ok "reconnected and handshook again" || bad "not ready after reconnect ($(connection))"

J=$(api POST '/show?wait=true' '{"name":"relay-test-2","xy":[[0.5,0],[0,0.5],[-0.5,0],[0,-0.5],[0.5,0]]}')
[[ "$(print -r -- $J | field 'd["state"]')" == done ]] && ok "a second drawing after reconnecting" || bad "second show failed: $J"

R=$(api GET /relay)
[[ "$(print -r -- $R | field 'd["tokenSet"] and d["connected"] and d["active"]')" == True ]] && ok "GET /relay" || bad "GET /relay: $R"
R=$(api POST /relay/command '{"command":"scan"}')
[[ "$(print -r -- $R | field 'd["ok"] and len(d["tables"])')" == 1 ]] && ok "POST /relay/command scan" || bad "scan: $R"
R=$(api POST /relay/command '{"command":"release"}')
[[ "$(print -r -- $R | field '"error" in d')" == True ]] && ok "release is refused on /relay/command (use /disconnect)" || bad "release allowed: $R"
R=$(api PUT /relay '{"token":"short"}')
[[ "$(print -r -- $R | field '"error" in d')" == True ]] && ok "PUT /relay rejects a short token" || bad "short token accepted: $R"

print "Disconnect (release) and connect again…"
api POST /disconnect >/dev/null
wait_for 6 '[[ "$(connection)" != ready ]]' && ok "released" || bad "still ready after /disconnect"
grep -q "command 'release'" "$WORK/relay.log" && ok "relay was told to release the table" || bad "relay never got release"
api POST /connect >/dev/null
wait_for 40 '[[ "$(connection)" == ready ]]' && ok "ready again after /connect" || bad "not ready after /connect"

print "Firmware update through Drifted, then straight to the relay (relay/ota.py)…"
head -c 300000 /dev/urandom >"$WORK/fw.bin"
OUT=$(python3 relay/ota.py --drifted "http://127.0.0.1:$HTTP_PORT" --drifted-token "$(cat "$STATE/token")" --firmware "$WORK/fw.bin" 2>&1)
[[ "$OUT" == *"back with firmware 0.1.0-fake+ota"* && "$(stat 'd.get("ota")')" == 300000 ]] && ok "ota.py --drifted: served, relay restarted with the new version" || bad "ota.py --drifted: $OUT"
wait_for 40 '[[ "$(connection)" == ready ]]' && ok "Drifted ready again after the relay restarted" || bad "not ready after the update ($(connection))"
OUT=$(python3 relay/ota.py --relay 127.0.0.1 --port "$RELAY_PORT" --token "$TOKEN" --firmware "$WORK/fw.bin" 2>&1)
[[ "$OUT" == *"back with firmware 0.1.0-fake+ota"* ]] && ok "ota.py --relay: direct update" || bad "ota.py --relay: $OUT"
wait_for 40 '[[ "$(connection)" == ready ]]' && ok "Drifted took the relay back afterwards" || bad "not ready after the direct update ($(connection))"

[[ "$(stat 'len(d["forbidden"])')" == 0 ]] && ok "no forbidden commands reached the table" || bad "forbidden: $(stat 'd["forbidden"]')"
print "Fake table: $(stat '"%d handshakes, %d session resets, %d uploads stored, %d writes dropped before a handshake, %d pages paced" % (d["handshakes"], d["sessionResets"], len(d["uploadsStored"]), d["droppedBeforeHandshake"], d["pagesPaced"])')"

print "A table that asks for a handshake only once per link (the relay's 8 s relink fallback)…"
kill $RELAY_PID; wait $RELAY_PID 2>/dev/null
python3 relay/tools/fake_relay.py --token "$TOKEN" --port "$RELAY_PORT" --stats "$WORK/stats.json" --no-reask >"$WORK/relay-noreask.log" 2>&1 &
RELAY_PID=$!
wait_for 40 '[[ "$(connection)" == ready ]]' && ok "ready on a fresh link" || bad "not ready with --no-reask ($(connection))"
kill -USR2 $RELAY_PID
wait_for 6 '[[ "$(connection)" != ready ]]'
wait_for 45 '[[ "$(connection)" == ready ]]' && [[ "$(stat 'd.get("gateTimeouts", 0)')" -ge 1 ]] \
  && ok "no handshake request after the reset, so the relay relinked; ready again" \
  || bad "didn't recover (connection $(connection), gate timeouts $(stat 'd.get("gateTimeouts", 0)'))"
print "Fake table: $(stat '"%d handshakes, %d session resets, %d writes dropped before a handshake" % (d["handshakes"], d["sessionResets"], d["droppedBeforeHandshake"])')"
[[ "$(stat 'len(d["forbidden"])')" == 0 ]] || bad "forbidden: $(stat 'd["forbidden"]')"

if (( failed )); then print -u2 "FAIL"; exit 1; fi
print "PASS"
