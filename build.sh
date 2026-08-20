#!/bin/zsh
set -e
cd "$(dirname "$0")"
ARCH=$(uname -m)
APP=build/NotchDial.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target "$ARCH-apple-macos13.0" Sources/*.swift -o "$APP/Contents/MacOS/NotchDial"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force -s - "$APP" 2>/dev/null
echo "BUILD OK: $APP"
