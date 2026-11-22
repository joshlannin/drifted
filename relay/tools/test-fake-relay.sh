#!/bin/zsh
# End-to-end test of drifted-host through the fake relay (relay/tools/fake_relay.py). No hardware and no Bluetooth:
# drifted-host runs from the build directory with its own state dir and port, so a Drifted app already running
# on this Mac (and its table connection) is untouched.
#
# Checks: connects and handshakes through the relay; stays ready (keepalive across TCP); /status reports the relay
# and its signal; a drawing uploads and plays; recovers when the relay loses the table and when the TCP
# connection drops; /relay and /relay/command work; linking on demand (standby between jobs, a job or a switch
# takes the table, check-ins, recovery while standing by, GET /link telemetry); relay jobs, with the firmware's
# own job engine (relay/firmware/main/job.c) built for this Mac and run inside the fake relay: check-ins,
# drawings, switches and the table playlist done by the relay alone, through lost pages, a refused upload, a
# stuck table, a lost link, a session reset and no network while it works; the connection to the relay lost at
# every stage of a job (while handing it over, as it's accepted, while the relay links, handshakes and works, as
# the result comes back); a result or the table's messages lost on the way; a pattern stored wrong; a table that
# turns up late; the relay restarting in the middle of a job; drifted-host restarting in the middle of a job;
# nothing sends forbidden commands.
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

print "Link on demand: the relay lets go of the table between jobs…"
tablelink() { api GET /status | field 'd["link"]["tableLink"]'; }
R=$(api PUT /relay '{"link":"onDemand","lingerSeconds":3,"checkInMinutes":5}')
[[ "$(print -r -- $R | field 'd["link"]')" == onDemand ]] && ok "PUT /relay link=onDemand" || bad "PUT /relay: $R"
wait_for 30 '[[ "$(connection)" == standby && "$(tablelink)" == released ]]' \
  && ok "standing by: relay connected, table released" || bad "not standing by (connection $(connection), relay link $(tablelink))"
[[ "$(api GET /status | field 'd["link"]["relayConnected"] and d["link"]["mode"] == "onDemand" and "stateAt" in d')" == True ]] \
  && ok "/status says the relay is connected, the mode, and how old the state is" || bad "/status link: $(api GET /status | field 'd["link"]')"
plays=$(stat 'len(d["plays"])')
J=$(api POST '/show?wait=true' '{"name":"relay-test-3","xy":[[0.4,0],[0,0.4],[-0.4,0],[0,-0.4],[0.4,0]]}')
[[ "$(print -r -- $J | field 'd["state"]')" == done && "$(stat 'len(d["plays"])')" -gt $plays ]] \
  && ok "a drawing sent while standing by: the relay took the table, it uploaded and played" || bad "show from standby failed: $J"
wait_for 20 '[[ "$(connection)" == standby ]]' && ok "standing by again after the linger" || bad "didn't go back to standby ($(connection))"
api POST /lamp/off >/dev/null
wait_for 20 '[[ "$(stat "\"14/7\" in d.get(\"settings\", [])")" == True ]]' \
  && ok "a switch flipped while standing by reached the table" || bad "lamp off never reached the table (settings: $(stat 'd.get("settings")'))"
api POST /lamp/on >/dev/null
wait_for 20 '[[ "$(connection)" == standby ]]' || bad "didn't go back to standby after the switch ($(connection))"
kill -USR2 $RELAY_PID
wait_for 6 '[[ "$(connection)" != standby ]]' && ok "noticed the relay connection closing while standing by" || bad "didn't notice the closed connection in standby"
wait_for 30 '[[ "$(connection)" == standby && "$(tablelink)" == released ]]' \
  && ok "back to standing by without taking the table" || bad "not standing by after reconnecting ($(connection), $(tablelink))"
print "Check-ins every 12 s, then a relay restart while standing by…"
api PUT /relay '{"checkInMinutes":0.2}' >/dev/null
sleep 30
L=$(api GET /link)
[[ "$(print -r -- $L | field 'd["days"][0]["wakes"]["reasons"].get("check-in", 0) >= 2 and d["days"][0]["wakes"]["failed"] == 0')" == True ]] \
  && ok "check-ins took the table and let go again ($(print -r -- $L | field 'd["days"][0]["wakes"]["count"]') wakes, average $(print -r -- $L | field 'd["days"][0]["wakes"]["averageSeconds"]') s)" \
  || bad "check-ins: $(print -r -- $L | field 'd["days"][0]["wakes"]')"
[[ "$(print -r -- $L | field 'd["mode"] == "relay, on demand" and d["days"][0]["seconds"]["standby"] > 0 and d["days"][0]["seconds"]["linked"] > 0 and d["days"][0]["jobs"]["count"] >= 3 and d["days"][0]["uploads"]["count"] >= 3 and d["days"][0]["drops"]["total"] >= 3 and len(d["recent"]) > 5')" == True ]] \
  && ok "GET /link: time per phase, wakes, jobs, uploads, drops and recent events" || bad "GET /link: $L"
api PUT /relay '{"checkInMinutes":5}' >/dev/null
wait_for 30 '[[ "$(connection)" == standby ]]' || bad "not standing by before the restart ($(connection))"
kill $RELAY_PID; wait $RELAY_PID 2>/dev/null
python3 relay/tools/fake_relay.py --token "$TOKEN" --port "$RELAY_PORT" --stats "$WORK/stats.json" >"$WORK/relay-restarted.log" 2>&1 &
RELAY_PID=$!
wait_for 40 '[[ "$(connection)" == standby && "$(tablelink)" == released ]]' \
  && ok "a restarted relay (which takes the table by itself) was told to let go again" || bad "after the relay restart: $(connection), $(tablelink)"
J=$(api POST '/show?wait=true' '{"name":"relay-test-4","xy":[[0.2,0],[0,0.2],[-0.2,0],[0,-0.2],[0.2,0]]}')
[[ "$(print -r -- $J | field 'd["state"]')" == done ]] && ok "a drawing after the restart" || bad "show after the restart failed: $J"
api POST /disconnect >/dev/null
sleep 2
[[ "$(connection)" != standby && "$(connection)" != ready ]] && ok "/disconnect lets go of the relay too" || bad "still $(connection) after /disconnect"
api POST /connect >/dev/null
wait_for 30 '[[ "$(connection)" == standby || "$(connection)" == ready ]]' && ok "/connect brings it back" || bad "not back after /connect ($(connection))"
R=$(api PUT /relay '{"link":"always"}')
wait_for 40 '[[ "$(connection)" == ready ]]' && ok "back to always linked: ready and staying" || bad "not ready after link=always ($(connection))"
sleep 6
[[ "$(connection)" == ready ]] || bad "didn't stay ready with link=always ($(connection))"
[[ "$(stat 'len(d["forbidden"])')" == 0 ]] || bad "forbidden: $(stat 'd["forbidden"]')"

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

print "Relay jobs: the relay does the table work by itself (the firmware's job engine)…"
if cc -shared -O1 -o "$WORK/libdriftjob.dylib" relay/firmware/main/job.c 2>"$WORK/cc.log"; then
  kill $RELAY_PID; wait $RELAY_PID 2>/dev/null
  print '{}' >"$WORK/faults.json"
  fault() { print -r -- "$1" >"$WORK/faults.json"; sleep 0.1; }
  python3 relay/tools/fake_relay.py --token "$TOKEN" --port "$RELAY_PORT" --stats "$WORK/stats.json" \
    --engine "$WORK/libdriftjob.dylib" --faults "$WORK/faults.json" >"$WORK/relay-jobs.log" 2>&1 &
  RELAY_PID=$!
  linkfield() { api GET /status | field "d[\"link\"][\"$1\"]"; }
  jobstats() { api GET /link | field "d[\"days\"][0].get(\"relayJobs\", {})$1"; }
  drawing() {   # drawing N: a spiral no other test has drawn, about 12 pages
    python3 -c "import json, math; n = 240; print(json.dumps({'name': 'job-$1', 'xy': [[(0.1 + 0.6 * i / n) * math.cos(i * 0.12 + $1), (0.1 + 0.6 * i / n) * math.sin(i * 0.12 + $1)] for i in range(n)]}))"
  }
  shown() { print -r -- "$1" | field 'd["state"] == "done" and d["result"]["uploaded"]'; }
  wakes=$(grep -c "link: taking the table" "$WORK/host.log")
  api PUT /relay '{"link":"onDemand","lingerSeconds":3,"checkInMinutes":5}' >/dev/null
  wait_for 40 '[[ "$(connection)" == standby && "$(linkfield jobs)" == True ]]' \
    && ok "standing by, and /status says the relay runs jobs" || bad "not standing by with jobs (connection $(connection), jobs $(linkfield jobs))"
  wait_for 30 '[[ "$(jobstats "[\"reasons\"].get(\"check-in\", 0)")" -ge 1 && "$(api GET /status | field "d[\"storedPatterns\"]")" == 3 ]]' \
    && ok "a check-in by the relay alone: its report brought the table's pattern list (3) and state" \
    || bad "check-in job: $(jobstats '') storedPatterns $(api GET /status | field 'd["storedPatterns"]')"
  [[ "$(api GET /status | field '"stateAt" in d and d["link"]["lastLinked"] is not None')" == True && "$(stat 'd.get("jobWrites", 0)')" -gt 0 ]] \
    && ok "the relay answered the table's handshake itself ($(stat 'd.get("jobWrites", 0)') writes, none from the host)" || bad "no job writes"

  D1=$(drawing 1)
  J=$(api POST '/show?wait=true' "$D1")
  [[ "$(shown "$J")" == true && "$(stat 'len(d["uploadsStored"])')" == 1 && "$(stat 'len(d["plays"])')" == 1 ]] \
    && ok "show: uploaded to $(print -r -- $J | field 'd["result"]["id"]') and playing, all by the relay" || bad "show by job failed: $J"
  J=$(api POST '/show?wait=true' "$D1")
  [[ "$(shown "$J")" == false && "$(stat 'len(d["uploadsStored"])')" == 1 && "$(stat 'len(d["plays"])')" == 2 ]] \
    && ok "the same drawing again: played from its slot, no upload" || bad "second show: $J"
  api POST /lamp/off >/dev/null
  wait_for 20 '[[ "$(stat "\"14/7\" in d.get(\"settings\", [])")" == True ]]' && ok "a switch reached the table through a job" || bad "lamp off never reached the table"
  api POST /lamp/on >/dev/null
  api POST /power/off >/dev/null
  wait_for 20 '[[ "$(stat "d.get(\"settings\", []).count(\"14/16\")")" -ge 1 ]]' || bad "power off never reached the table"
  J=$(api POST '/show?wait=true' "$(drawing 2)")
  [[ "$(shown "$J")" == true && "$(api GET /power | field 'd["on"]')" == True && "$(stat "d.get(\"settings\", []).count(\"14/16\")")" -ge 2 ]] \
    && ok "a drawing while switched off: the job turns the table on first" || bad "show while off: $J"

  fault '{"losePages": [2, 4], "ignorePlays": 1}'
  J=$(api POST '/show?wait=true' "$(drawing 3)")
  [[ "$(shown "$J")" == true && "$(stat 'd["uploadsMissing"]')" -ge 1 ]] \
    && ok "lost pages and an ignored play: the relay sent the pages again and played until it started" || bad "lost pages: $J"
  fault '{"loseLastPage": true}'
  J=$(api POST '/show?wait=true' "$(drawing 4)")
  [[ "$(shown "$J")" == true ]] && ok "the last page lost (an empty missing list): resent, stored" || bad "last page lost: $J"
  fault '{"rejectNextStart": true}'
  J=$(api POST '/show?wait=true' "$(drawing 5)")
  [[ "$(shown "$J")" == true ]] && grep -q "refusing an upload" "$WORK/relay-jobs.log" \
    && ok "the table refused the slot at Start: the relay used the next one ($(print -r -- $J | field 'd["result"]["id"]'))" || bad "refused start: $J"
  fault '{"dropLinkAtPage": 5}'
  J=$(api POST '/show?wait=true' "$(drawing 6)")
  [[ "$(shown "$J")" == true && "$(jobstats '["stepsRestarted"]')" -ge 1 ]] \
    && ok "the Bluetooth link lost mid-upload: the relay linked again and redid the upload" || bad "lost link: $J $(jobstats '')"
  fault '{"resetAtPage": 5}'
  J=$(api POST '/show?wait=true' "$(drawing 7)")
  [[ "$(shown "$J")" == true && "$(jobstats '["stepsRestarted"]')" -ge 2 ]] \
    && ok "the table restarted its session mid-upload: handshake again, upload again" || bad "session reset: $J"
  fault '{"stallWifi": true}'
  J=$(api POST '/show?wait=true' "$(drawing 8)")
  [[ "$(shown "$J")" == true && "$(stat 'd.get("stalls", 0)')" -ge 1 ]] \
    && ok "no network at all while the relay had the table: the job ran, and the result was collected afterwards" || bad "stalled Wi-Fi: $J (stalls $(stat 'd.get("stalls", 0)'))"
  fault '{"dropHostDuringData": true}'
  J=$(api POST '/show?wait=true' "$(drawing 10)")
  [[ "$(shown "$J")" == true && "$(stat 'd.get("dataDrops", 0)')" == 1 ]] && grep -q "of the pattern; sending the rest" "$WORK/host.log" \
    && ok "the connection lost while handing the pattern over: the relay said how much it had, and the rest followed" || bad "interrupted hand-over: $J"
  print "The connection to the relay lost at each stage of a job…"
  n=20
  for stage in 'dropHostAfter begin "right after its steps arrived"' 'dropHostAfter run "right after it was told to run"' \
               'dropHostAtState linking "as the relay began linking"' 'dropHostAtState handshake "during the handshake"' \
               'dropHostAtState running "as the steps began"' 'dropHostAtState done "as it finished"'; do
    parts=(${(Q)${(z)stage}})
    n=$(( n + 1 ))
    stored=$(stat 'len(d["uploadsStored"])'); cuts=$(stat 'd.get("hostCuts", 0)')
    fault "{\"${parts[1]}\": \"${parts[2]}\"}"
    J=$(api POST '/show?wait=true' "$(drawing $n)")
    [[ "$(shown "$J")" == true && "$(stat 'd.get("hostCuts", 0)')" == $(( cuts + 1 )) && "$(stat 'len(d["uploadsStored"])')" == $(( stored + 1 )) ]] \
      && ok "${parts[3]}: the job was done once, and its result collected" \
      || bad "connection lost ${parts[3]}: $J (cuts $(stat 'd.get("hostCuts", 0)'), uploads $(stat 'len(d["uploadsStored"])') from $stored)"
  done
  stored=$(stat 'len(d["uploadsStored"])')
  fault '{"loseResult": true}'
  J=$(api POST '/show?wait=true' "$(drawing 27)")
  [[ "$(shown "$J")" == true && "$(stat 'len(d["uploadsStored"])')" == $(( stored + 1 )) ]] \
    && ok "the result lost on its way: asked for again, the job not run twice" || bad "lost result: $J"
  fault '{"loseTableData": true}'
  J=$(api POST '/show?wait=true' "$(drawing 28)")
  [[ "$(shown "$J")" == true && "$(stat 'd.get("tableDataLost", 0)')" -ge 1 && "$(stat 'len(d["uploadsStored"])')" == $(( stored + 2 )) ]] \
    && ok "the table's messages missing from the result: fetched again" || bad "lost table data: $J"
  fault '{"corruptData": true}'
  J=$(api POST '/show?wait=true' "$(drawing 29)")
  [[ "$(shown "$J")" == true ]] && grep -q "didn.t arrive intact" "$WORK/relay-jobs.log" \
    && ok "a pattern stored wrong on the relay: caught by its checksum before anything was sent to the table, and sent again" || bad "corrupt data: $J"
  toggles=$(stat 'd.get("settings", []).count("14/3")')
  fault '{"dropHostAtState": "running"}'
  J=$(api POST /pause)
  [[ "$(print -r -- $J | field 'd["state"]')" == done && "$(stat 'd.get("settings", []).count("14/3")')" == $(( toggles + 1 )) ]] \
    && ok "play/pause (a toggle) with the connection lost mid-job: reached the table exactly once" || bad "pause: $J ($(stat 'd.get("settings", []).count("14/3")') sent)"
  fault '{"tableAbsent": true}'
  sent=$(stat 'd.get("settings", []).count("14/7")')
  api POST /lamp/off >/dev/null
  sleep 15
  [[ "$(stat 'd.get("settings", []).count("14/7")')" == $sent ]] || bad "a command reached a table that wasn't there"
  fault '{}'
  wait_for 45 '[[ "$(stat "d.get(\"settings\", []).count(\"14/7\")")" -gt $sent ]]' \
    && ok "the table out of reach for 15 s after a switch was flipped: the relay kept trying and delivered it" || bad "late table: lamp off never arrived"
  api POST /lamp/on >/dev/null
  wait_for 20 '[[ "$(stat "d.get(\"settings\", []).count(\"14/7\")")" -gt $(( sent + 1 )) ]]' || bad "lamp on never arrived"

  fault '{"stuck": true}'
  resets=$(stat 'd.get("unstuck", 0)')
  api POST /lamp/off >/dev/null
  wait_for 40 '[[ "$(stat "d.get(\"unstuck\", 0)")" -gt $resets && "$(stat "d.get(\"settings\", []).count(\"14/7\")")" -ge 5 ]]' \
    && ok "a table stuck half-way through an old handshake (never asking for a new one): answered, and the job went through" \
    || bad "stuck table: unstuck $(stat 'd.get("unstuck", 0)'), settings $(stat 'd.get("settings")')"
  api POST /lamp/on >/dev/null
  fault '{}'

  api PUT /playlist '{"active":true,"onTable":true,"shuffle":false,"ids":[1,2,3]}' >/dev/null
  wait_for 30 '[[ "$(stat "len(d.get(\"playlists\", {}).get(\"drifted_mix\", []))")" == 3 ]]' \
    && ok "the table's own playlist written by a job" || bad "table playlist not written: $(stat 'd.get("playlists")')"
  J=$(api POST /next)
  [[ "$(print -r -- $J | field 'd["state"] == "done" and d["result"]["playlist"]')" == drifted_mix && "$(stat 'd["plays"][-1] == d["playlists"]["drifted_mix"][0]')" == True \
     && "$(stat '"14/11" in d["settings"] and "14/10" in d["settings"]')" == True ]] \
    && ok "next: list rewritten, loop on, random off, selected, and its first pattern drawing" || bad "next by job: $J"
  fault '{"ignorePlaylist": true}'
  J=$(api POST /next)
  [[ "$(print -r -- $J | field 'd["state"] == "done" and d["result"]["playlist"]')" == "not written" && "$(stat 'd["plays"][-1]')" == "$(print -r -- $J | field 'd["result"]["id"]')" ]] \
    && ok "the table didn't confirm the list: the job fell back to playing the pattern directly" || bad "playlist fallback: $J"
  fault '{}'
  api PUT /playlist '{"active":false}' >/dev/null
  sleep 2

  print "The lamp: the user's colour is kept, and put back when the table loses it; seasons hand it back…"
  lampcolor() { api GET /status | field "d[\"lampColor\"][\"$1\"]"; }
  owed() { python3 -c "import json; print(json.load(open('$STATE/switches.json')).get('lampOwed', False))"; }
  checkin() { api PUT /relay '{"checkInMinutes":5}' >/dev/null; }   # any PUT /relay has the relay look at the table
  logged() { grep -c "$1" "$WORK/host.log"; }
  restored() { wait_for 20 "[[ \"\$(logged 'the relay did lamp restore')\" -ge $1 ]]"; sleep 1; }   # the Nth lamp job is over
  J=$(api PUT /settings '{"color":"#FFD27A"}')
  [[ "$(print -r -- $J | field 'd["state"]')" == done && "$(stat 'd["lamp"]')" == "Temp #ffd27a" && "$(lampcolor color)" == "#ffd27a" ]] \
    && ok "a colour set through /settings is on the table and remembered as the user's" || bad "set colour: $J, table $(stat 'd.get("lamp")'), remembered $(api GET /status | field 'd.get("lampColor")')"
  checkin
  wait_for 30 '[[ "$(owed)" == False ]]' && ok "the next look at the table confirmed it" || bad "the colour was never confirmed (owed $(owed))"
  fault '{"lampDefault": true}'
  checkin
  wait_for 40 '[[ "$(logged "back on its default colour")" == 1 && "$(stat "d[\"lamp\"]")" == "Temp #ffd27a" ]]' \
    && ok "the table fell back to its stock colour: the user's colour went back on at the check-in" \
    || bad "fallback not repaired: table $(stat 'd.get("lamp")'), log $(grep "lamp:" "$WORK/host.log" | tail -2)"
  restored 1
  checkin
  wait_for 30 '[[ "$(owed)" == False ]]' || bad "the restored colour was never confirmed"
  [[ "$(lampcolor color)" == "#ffd27a" && "$(logged "lamp restore")" -ge 1 ]] || bad "remembered colour changed: $(api GET /status | field 'd.get("lampColor")')"
  fault '{"lampSet": "c2"}'
  checkin
  wait_for 30 '[[ "$(lampcolor name)" == c2 ]]' && [[ "$(stat 'd["lamp"]')" == "c2 #ff00ff" ]] \
    && ok "a colour picked somewhere else (the HoMedics app) is followed, not fought" || bad "c2 not adopted: $(api GET /status | field 'd.get("lampColor")'), table $(stat 'd.get("lamp")')"
  api PUT /settings '{"color":"#FFD27A"}' >/dev/null
  checkin; wait_for 30 '[[ "$(owed)" == False ]]' || bad "colour not confirmed before the season"
  TODAY=$(date +%m-%d)
  api PUT /schedule "{\"enabled\":true,\"weatherAt\":null,\"playlistAt\":null,\"seasons\":[{\"name\":\"Testday\",\"start\":\"$TODAY\",\"end\":\"$TODAY\",\"ids\":[],\"weight\":1,\"colors\":[\"#FF7518\"]}]}" >/dev/null
  wait_for 40 '[[ "$(stat "d[\"lamp\"]")" == "Temp #ff7518" ]]' && [[ "$(lampcolor color)" == "#ffd27a" ]] \
    && ok "a season put its colour on the lamp; the user's colour is still the one remembered" || bad "season lamp: table $(stat 'd.get("lamp")'), remembered $(api GET /status | field 'd.get("lampColor")')"
  checkin; sleep 12
  [[ "$(lampcolor color)" == "#ffd27a" && "$(stat 'd["lamp"]')" == "Temp #ff7518" ]] \
    && ok "a look at the table during the season: the season's colour isn't taken for the user's" || bad "season colour adopted: $(api GET /status | field 'd.get("lampColor")')"
  fault '{"lampDefault": true}'
  checkin
  wait_for 40 '[[ "$(logged "putting the Testday colour")" == 1 && "$(stat "d[\"lamp\"]")" == "Temp #ff7518" ]]' \
    && ok "the table fell back during the season: the season's colour went back on, not the user's" \
    || bad "season fallback: table $(stat 'd.get("lamp")'), log $(grep "lamp:" "$WORK/host.log" | tail -2)"
  restored 2
  fault '{"ignoreLamp": 2}'
  api PUT /schedule '{"seasons":[]}' >/dev/null
  wait_for 40 '[[ "$(logged "season over; lamp back to #ffd27a")" == 1 ]]' && restored 3 || bad "season end never sent the lamp"
  checkin; sleep 12
  [[ "$(stat 'd["lamp"]')" == "Temp #ff7518" && "$(lampcolor color)" == "#ffd27a" && "$(owed)" == True && "$(logged "set somewhere else")" == 1 ]] \
    && ok "the hand-back after the season was lost on the way: the season's colour isn't taken for the user's" \
    || bad "lost hand-back: table $(stat 'd.get("lamp")'), remembered $(api GET /status | field 'd.get("lampColor")'), owed $(owed)"
  api PUT /settings '{"color":"#FFD27A"}' >/dev/null
  checkin
  wait_for 30 '[[ "$(owed)" == False && "$(stat "d[\"lamp\"]")" == "Temp #ffd27a" ]]' && ok "set again: back on the user's colour" || bad "colour not back: $(stat 'd.get("lamp")')"
  api PUT /schedule '{"enabled":false}' >/dev/null
  fault '{}'

  [[ "$(grep -c "link: taking the table" "$WORK/host.log")" == "$wakes" && "$(connection)" == standby ]] \
    && ok "the host never took the table itself: standing by throughout" || bad "the host took the table ($(connection))"
  api PUT /relay '{"jobs":false}' >/dev/null
  J=$(api POST '/show?wait=true' "$(drawing 9)")
  [[ "$(shown "$J")" == true && "$(grep -c "link: taking the table" "$WORK/host.log")" -gt "$wakes" ]] \
    && ok "\"jobs\": false goes back to driving the table live through the relay" || bad "jobs off: $J"
  api PUT /relay '{"jobs":true}' >/dev/null
  wait_for 30 '[[ "$(connection)" == standby ]]' || bad "not standing by after jobs back on ($(connection))"
  L=$(api GET /link)
  [[ "$(print -r -- $L | field 'd["mode"] == "relay, jobs" and d["days"][0]["relayJobs"]["count"] >= 15 and d["days"][0]["relayJobs"]["failed"] == 0 and d["days"][0]["relayJobs"]["tableReady"]["averageSeconds"] > 0 and d["days"][0]["uploads"]["pagesResent"] >= 2')" == True ]] \
    && ok "GET /link: $(print -r -- $L | field 'd["days"][0]["relayJobs"]["count"]') relay jobs, none failed, table ready after $(print -r -- $L | field 'd["days"][0]["relayJobs"]["tableReady"]["averageSeconds"]') s on average" \
    || bad "GET /link relayJobs: $(print -r -- $L | field 'd["days"][0].get("relayJobs")')"
  [[ "$(stat 'len(d["forbidden"])')" == 0 ]] || bad "forbidden: $(stat 'd["forbidden"]')"
  print "Fake table: $(stat '"%d handshakes, %d uploads stored, %d plays, %d writes by jobs" % (d["handshakes"], len(d["uploadsStored"]), len(d["plays"]), d.get("jobWrites", 0))')"

  print "The relay restarts in the middle of a job…"
  jobstate() { api GET "/jobs/$1" | field 'd["state"]'; }
  pages=$(stat 'd.get("pages", 0)')
  J=$(api POST /show "$(drawing 40)")
  ID=$(print -r -- $J | field 'd["id"]')
  wait_for 15 '[[ "$(stat "d.get(\"pages\", 0)")" -ge $(( pages + 8 )) ]]' || bad "the upload never started ($J)"
  before=$(( $(stat 'd.get("pages", 0)') - pages ))
  kill -9 $RELAY_PID; wait $RELAY_PID 2>/dev/null
  python3 relay/tools/fake_relay.py --token "$TOKEN" --port "$RELAY_PORT" --stats "$WORK/stats.json" \
    --engine "$WORK/libdriftjob.dylib" --faults "$WORK/faults.json" >"$WORK/relay-jobs-2.log" 2>&1 &
  RELAY_PID=$!
  wait_for 90 '[[ "$(jobstate $ID)" == done || "$(jobstate $ID)" == failed ]]'
  [[ "$(jobstate $ID)" == done && "$(stat 'len(d["uploadsStored"])')" == 1 && "$(stat 'len(d["plays"])')" == 1 ]] && grep -q "no longer has the job" "$WORK/host.log" \
    && ok "killed after $before pages of an upload: drifted-host noticed the job was gone and gave it to the restarted relay, which did it" \
    || bad "relay restart mid-job: job $(jobstate $ID), uploads $(stat 'len(d["uploadsStored"])'), plays $(stat 'len(d["plays"])')"

  print "drifted-host restarts in the middle of a job…"
  pages=$(stat 'd.get("pages", 0)')
  J=$(api POST /show "$(drawing 41)")
  wait_for 15 '[[ "$(stat "d.get(\"pages\", 0)")" -ge $(( pages + 8 )) ]]' || bad "the second upload never started ($J)"
  kill -9 $HOST_PID; wait $HOST_PID 2>/dev/null
  wait_for 30 '[[ "$(stat "len(d[\"uploadsStored\"])")" == 2 && "$(stat "len(d[\"plays\"])")" == 2 ]]' \
    && ok "with nobody listening the relay finished the job anyway: stored and drawing" || bad "the relay didn't finish alone (uploads $(stat 'len(d["uploadsStored"])'))"
  "$BIN" --port "$HTTP_PORT" --state "$STATE" >>"$WORK/host.log" 2>&1 &
  HOST_PID=$!
  wait_for 40 '[[ "$(connection)" == standby && "$(linkfield jobs)" == True ]]' && ok "drifted-host back, standing by" || bad "drifted-host didn't come back ($(connection))"
  J=$(api POST '/show?wait=true' "$(drawing 42)")
  [[ "$(shown "$J")" == true && "$(stat 'len(d["uploadsStored"])')" == 3 ]] && ok "and the next drawing goes through" || bad "show after the host restart: $J"
  [[ "$(stat 'len(d["forbidden"])')" == 0 ]] || bad "forbidden: $(stat 'd["forbidden"]')"
else
  bad "couldn't build the job engine (relay/firmware/main/job.c): $(cat "$WORK/cc.log")"
fi

if (( failed )); then print -u2 "FAIL"; exit 1; fi
print "PASS"
