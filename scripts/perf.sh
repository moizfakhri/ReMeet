#!/bin/zsh
# Developer measurement for docs/performance.md. Usage: scripts/perf.sh <dataset-dir> [launch|idle|record|all]
# Runs the Release binary against <dataset-dir> (a storage folder with meetings/), never ~/ReMeet.
cd "${0:A:h}/.."
APP=build/Build/Products/Release/ReMeet.app/Contents/MacOS/ReMeet
D=$1; MODE=${2:-all}
ARGS=(-storageFolder $D -hasCompletedFirstLaunch YES -askWhenMeetingStarts NO -showNoteBubble YES)
OUT=$(mktemp -d)

sample() { # pid seconds label -> average CPU %, last MEM, average POWER from top
  local n=$(( $2 / 5 + 1 ))
  top -l $n -s 5 -pid $1 -stats pid,cpu,mem,power 2>/dev/null | awk -v label="$3" '
    $1 ~ /^[0-9]+$/ { c[++k]=$2; m=$3; p[k]=$4 }
    END { s=0; w=0; for (i=2;i<=k;i++) { s+=c[i]; w+=p[i] }; n=k-1;
          printf "%s: CPU avg %.2f%%, power avg %.2f, mem (top) %s over %d samples\n", label, s/n, w/n, m, n }'
  footprint $1 2>/dev/null | grep -E "^  *phys_footprint:|Footprint:" | head -2 | sed "s/^/$3 footprint: /"
}

if [[ $MODE == launch || $MODE == all ]]; then
  for i in 1 2 3 4 5; do
    $APP $ARGS --perf-open-window > $OUT/launch$i.txt 2>&1 &
    pid=$!; sleep 6; kill $pid 2>/dev/null; wait $pid 2>/dev/null
    print "run $i: $(grep -E 'PERF (launch.end|menubar.ready|window|library|document.shown)' $OUT/launch$i.txt | sed 's/PERF //' | tr '\n' ';')"
  done
fi
if [[ $MODE == idle || $MODE == all ]]; then
  $APP $ARGS > $OUT/idle.txt 2>&1 &
  pid=$!; sleep 10; sample $pid 60 "idle"; kill $pid; wait $pid 2>/dev/null
fi
if [[ $MODE == record || $MODE == all ]]; then
  $APP $ARGS --perf-record-now > $OUT/rec.txt 2>&1 &
  pid=$!; sleep 6; sample $pid 60 "recording"; kill $pid; wait $pid 2>/dev/null
fi
rm -rf $OUT
# Safety: no measurement instance may outlive this script (one once kept recording).
pkill -f -- "MacOS/ReMeet.*--perf-" 2>/dev/null
pkill -f -- "MacOS/ReMeet -storageFolder" 2>/dev/null
