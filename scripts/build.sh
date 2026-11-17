#!/bin/zsh
# Developer build: Release into ./build.
# Signs with the self-signed "ReMeet Local Signing" certificate when it is in the login
# keychain. Its signature stays the same across builds, so privacy grants (mic, system audio)
# survive updates. An ad-hoc
# signature changes every build and loses them. Falls back to ad-hoc with a warning.
set -euo pipefail
cd "${0:A:h}/.."
IDENTITY="ReMeet Local Signing"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  SIGN=(CODE_SIGN_IDENTITY="$IDENTITY")
else
  print -u2 "warning: no \"$IDENTITY\" certificate; signing ad-hoc (Keychain items and permissions reset with this build)"
  SIGN=(CODE_SIGN_IDENTITY=-)
fi
xcodebuild -project ReMeet.xcodeproj -scheme ReMeet -configuration Release \
  -derivedDataPath build -destination 'platform=macOS,arch=arm64' \
  $SIGN CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  build "$@"
