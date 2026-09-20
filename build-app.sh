#!/bin/zsh
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/Jev.app"
set -a
source "$DIR/.env"
set +a
swiftc -O "$DIR/jev.swift" -o "$DIR/jev"
swiftc -O "$DIR/Guide.swift" "$DIR/JevApp.swift" "$DIR/PopupPanel.swift" "$DIR/OverlayWindow.swift" "$DIR/main.swift" -o "$DIR/jev-ui"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$DIR/jev-ui" "$APP/Contents/MacOS/jev-ui"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>jev-ui</string>
	<key>CFBundleIdentifier</key>
	<string>dev.jev.app</string>
	<key>CFBundleName</key>
	<string>Jev</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
PLIST
echo "built $APP"
pkill -x jev-ui 2>/dev/null || true
sleep 1
open "$APP"
