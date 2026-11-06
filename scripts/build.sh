#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="$(xcrun --show-sdk-path)"
APP="dist/TokenEater.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library -target arm64-apple-macosx14.0 \
  -Xcc -I"$SDK/usr/include" \
  -o "$APP/Contents/MacOS/TokenEater" \
  Sources/TokenEater/Logic.swift \
  Sources/TokenEater/Fetch.swift \
  Sources/TokenEater/LaunchAtLogin.swift \
  Sources/TokenEater/AppMain.swift \
  -framework AppKit -framework SwiftUI -framework Security

ICONSET="$(swift scripts/make-icon.swift "$APP/Contents/Resources")"
for png in "$ICONSET"/*.png; do
  sips -s format png "$png" --out "${png%.png}.tmp.png" >/dev/null
  mv "${png%.png}.tmp.png" "$png"
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cp Support/Info.plist "$APP/Contents/Info.plist"
xattr -cr "$APP"
codesign --force --sign - "$APP"

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/TokenEater.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "TokenEater" -srcfolder "$STAGE" -ov -format UDZO "dist/TokenEater.dmg" >/dev/null
rm -rf "$STAGE"
echo "built dist/TokenEater.dmg"
