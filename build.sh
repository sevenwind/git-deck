#!/bin/bash
# Собирает GitDeck.app рядом со скриптом
set -e
cd "$(dirname "$0")"
VERSION=$(tr -d '[:space:]' < VERSION)   # тег релиза на GitHub = v$VERSION
swift build -c release --arch arm64 --arch x86_64
APP="GitDeck.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path 2>/dev/null)/GitDeck" "$APP/Contents/MacOS/GitDeck"

ICONS=$(mktemp -d)/AppIcon.iconset
swift tools/make_icon.swift "$ICONS"
iconutil -c icns "$ICONS" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>GitDeck</string>
<key>CFBundleDisplayName</key><string>GitDeck</string>
<key>CFBundleIdentifier</key><string>local.gitdeck.app</string>
<key>CFBundleExecutable</key><string>GitDeck</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Готово: $PWD/$APP"
