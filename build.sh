#!/bin/zsh
set -e
cd "$(dirname "$0")"
ARCH=$(uname -m)
APP=build/NotchDial.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target "$ARCH-apple-macos13.0" Sources/*.swift -o "$APP/Contents/MacOS/NotchDial"
cp Info.plist "$APP/Contents/Info.plist"

# macOS ties the Accessibility grant to the code signature. An ad-hoc signature is a
# new identity on every build, so every rebuild silently drops the permission that
# makes the status signal exact — and a stale TCC row shows the toggle ON while the
# app is denied, which is a genuinely nasty afternoon.
#
# So: sign with a stable identity when one exists. Any self-signed code-signing
# certificate works and costs nothing (Keychain Access > Certificate Assistant >
# Create a Certificate, type "Code Signing"); name it NotchDial Local Signing, or
# set NOTCHDIAL_SIGN_ID to whatever you called yours. Fall back to ad-hoc so a
# fresh clone still builds with no setup at all.
ID="${NOTCHDIAL_SIGN_ID:-NotchDial Local Signing}"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$ID"; then
    codesign --force -s "$ID" --options runtime "$APP" 2>/dev/null \
        || codesign --force -s "$ID" "$APP"
    echo "BUILD OK: $APP  (signed: $ID — the Accessibility grant survives rebuilds)"
else
    codesign --force -s - "$APP" 2>/dev/null
    echo "BUILD OK: $APP  (ad-hoc — macOS will ask for Accessibility again after each rebuild;"
    echo "                 see 'Keeping the permission' in the README to stop that)"
fi
