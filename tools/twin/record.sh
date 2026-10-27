#!/bin/bash
# record.sh PATTERN.json [NAME]
# Draw a pattern on the table and keep everything the twin needs: the path, a photo before and after, a
# 5 fps video of the drawing (track.py finds the ball in it), the table's progress over time, and which run
# came before (the twin replays runs in order to know what was already in the sand).
#
# Runs go to $DRIFTED_RUNS (default ~/Library/Application Support/Drifted/runs), one folder per run.
# Camera: $DRIFTED_CAMERA (default "Logitech BRIO"), captured with ffmpeg's avfoundation input.
set -euo pipefail

pattern=$1
name=${2:-$(basename "$pattern" .json)}
runs=${DRIFTED_RUNS:-"$HOME/Library/Application Support/Drifted/runs"}
camera=${DRIFTED_CAMERA:-"Logitech BRIO"}
api=${DRIFTED_API:-http://localhost:8765}
token=$(cat "$HOME/Library/Application Support/Drifted/token")
auth="Authorization: Bearer $token"

mkdir -p "$runs"
prev=$(ls -1 "$runs" 2>/dev/null | tail -1 || true)
dir="$runs/$(date +%Y%m%d-%H%M%S)-$name"
mkdir -p "$dir"
cp "$pattern" "$dir/path.json"

snap() {
  ffmpeg -loglevel error -f avfoundation -pixel_format nv12 -framerate 30 -video_size 1920x1080 \
    -i "$camera" -frames:v 1 -y "$1"
}

snap "$dir/before.jpg"
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
python3 -c 'import time; print(time.time())' > "$dir/video.start"
ffmpeg -loglevel error -f avfoundation -pixel_format nv12 -framerate 30 -video_size 1920x1080 -i "$camera" \
  -vf fps=5 -c:v h264_videotoolbox -b:v 2M -y "$dir/video.mp4" < /dev/null &
video=$!
curl -s -m300 -XPOST -H "$auth" -H 'Content-Type: application/json' --data @"$pattern" "$api/show?wait=true" > "$dir/show.json"
sleep 10
while :; do
  s=$(curl -s -m3 -H "$auth" "$api/status" || true)
  state=$(printf '%s' "$s" | python3 -c "import json,sys
try:
    s=json.load(sys.stdin); st=s.get('state',{}); print(s.get('connection'), st.get('drawing'), st.get('progress'))
except Exception: print('unreachable')")
  printf '%s %s\n' "$(python3 -c 'import time; print(time.time())')" "$state" >> "$dir/progress.log"
  case "$state" in
    "ready False"*) break ;;
    ready*) sleep 5 ;;
    *) echo "table problem: $state" >&2; break ;;
  esac
done
sleep 3
kill -INT $video; wait $video || true
snap "$dir/after.jpg"
printf '%s' "$s" > "$dir/status.json"
python3 - "$dir" "$prev" "$started" "$name" <<'EOF'
import json, sys
d, prev, started, name = sys.argv[1:]
raw = open(f'{d}/show.json').read()
try:
    show = json.loads(raw)
except ValueError:
    show = raw
json.dump({'name': name, 'previous': prev or None, 'started': started, 'show': show},
          open(f'{d}/meta.json', 'w'), indent=1)
EOF
echo "$dir"
# a failed upload means nothing was drawn: say so, so a caller can retry instead of carrying on
if grep -q '"state":"failed"' "$dir/show.json"; then
  echo "not drawn: $(cat "$dir/show.json")" >&2
  exit 3
fi
