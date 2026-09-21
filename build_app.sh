#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"

APP_NAME="Mac-dockbar clock.app"
STAGED_APP="$PWD/build/$APP_NAME"
mkdir -p "$STAGED_APP/Contents/MacOS"
cp "$APP_NAME/Contents/Info.plist" "$STAGED_APP/Contents/Info.plist"
xcrun swiftc -O -target arm64-apple-macosx13.0 -framework Cocoa -framework MapKit \
  DockClockSwift/*.swift -o "$STAGED_APP/Contents/MacOS/MacDockbarClock"
codesign --force --sign - "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
mkdir -p dist
ditto -c -k --sequesterRsrc --keepParent "$STAGED_APP" "dist/WeatherCalendar-macOS.zip"
print "Built: $STAGED_APP"
print "Archive: $PWD/dist/WeatherCalendar-macOS.zip"
