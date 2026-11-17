#!/bin/zsh
# Developer: build Release, quit the running ReMeet (it finalizes any recording first),
# copy to /Applications and relaunch. The build/ copy stays for Xcode.
set -euo pipefail
cd "${0:A:h}/.."
./scripts/build.sh | grep -E "error:|BUILD" | sort -u
osascript -e 'with timeout of 30 seconds' -e 'tell application id "com.moizfakhri.ReMeet" to quit' -e 'end timeout' 2>/dev/null || true
for i in {1..20}; do pgrep -f "/Applications/ReMeet.app/Contents/MacOS/ReMeet" >/dev/null || break; sleep 0.5; done
ditto build/Build/Products/Release/ReMeet.app /Applications/ReMeet.app
# Refresh Launch Services so Dock / Notification Center pick up the new AppIcon
# (stale blank Dock "recent apps" tiles may still need Remove from Dock once).
 /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/ReMeet.app >/dev/null 2>&1 || true
open /Applications/ReMeet.app
echo "Installed /Applications/ReMeet.app"
