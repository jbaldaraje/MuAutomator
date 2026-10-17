#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'This build requires macOS 14+ and Xcode 15+.' >&2
  exit 1
fi
swift test -j 2
xcodebuild -project MUAutomator.xcodeproj -scheme MUAutomator -configuration Release \
  -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
swift macOS/GenerateIcon.swift .build/AppIcon.iconset
mkdir -p .build/xcode/Build/Products/Release/MUAutomator.app/Contents/Resources
iconutil -c icns .build/AppIcon.iconset \
  -o .build/xcode/Build/Products/Release/MUAutomator.app/Contents/Resources/AppIcon.icns
codesign --force --sign - .build/xcode/Build/Products/Release/MUAutomator.app
codesign --verify --deep --strict .build/xcode/Build/Products/Release/MUAutomator.app
echo 'Built .build/xcode/Build/Products/Release/MUAutomator.app'
echo 'Ad-hoc signed for local testing. Use your Apple distribution identity and notarize before distribution.'
