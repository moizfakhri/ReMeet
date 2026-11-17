#!/bin/zsh
# Developer check: runs every app self-test against the Release build and prints a summary.
# Usage: scripts/selftests.sh [speech-test-dir]
cd "${0:A:h}/.."
APP=build/Build/Products/Release/ReMeet.app/Contents/MacOS/ReMeet
tests=(bubble compress player search backends processmonitor tapfilter)
[[ -n "$1" ]] && tests+=("speech $1 --summarize")
fail=0
for t in $tests; do
  out=$($APP --selftest ${=t} 2>&1)
  passed=$(print -r -- "$out" | grep -c '^PASS')
  failed=$(print -r -- "$out" | grep -c '^FAIL')
  printf '%-14s %2d passed, %d failed\n' "${t%% *}" $passed $failed
  (( failed > 0 )) && { print -r -- "$out" | grep '^FAIL'; fail=1 }
done
# Safety: no test instance may outlive this script (audit C5); report if one had to be stopped.
sleep 1
if pgrep -f "MacOS/ReMeet --selftest" >/dev/null; then
  pkill -f "MacOS/ReMeet --selftest"; echo "stopped a leftover test instance"
fi
exit $fail
