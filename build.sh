#!/bin/sh
# build.sh: Session Hub (Mantra).app. Run only by GitHub Actions (.github/workflows/build.yml), never on the Mac.
# VERSION is `let VERSION = n` in app/App.swift. SIGN=- is ad hoc (the runner); the Mac re-signs "Mantra Apps" after install.
set -e
cd "$(dirname "$0")"
mkdir -p build
V=$(sed -n 's/^let VERSION = \([0-9]*\)/\1/p' app/App.swift)
APP="build/Session Hub (Mantra).app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library -o "$APP/Contents/MacOS/SessionHub" app/*.swift
[ -x "$APP/Contents/MacOS/SessionHub" ] || { echo "the app did not build"; exit 1; }
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Session Hub (Mantra)</string>
<key>CFBundleDisplayName</key><string>Session Hub (Mantra)</string>
<key>CFBundleIdentifier</key><string>community.auroville.sessionhub</string>
<key>CFBundleExecutable</key><string>SessionHub</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$V</string>
<key>CFBundleVersion</key><string>$V</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
codesign --force -s "${SIGN:-Mantra Apps}" "$APP"
echo "built $APP (v$V)"
