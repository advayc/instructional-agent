#!/bin/zsh
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_LINK="$DIR/Jev.app"
INSTALL_APP="/Users/AdvayChandorkar/Applications/Jev.app"
SUPPORT_DIR="/Users/AdvayChandorkar/Library/Application Support/Jev"
STAGE_ROOT="$(/usr/bin/mktemp -d /private/tmp/jev-app-build.XXXXXX)"
STAGED_APP="$STAGE_ROOT/Jev.app"
trap '/bin/rm -rf "$STAGE_ROOT"' EXIT
set -a
source "$DIR/.env"
set +a
swiftc -O "$DIR/jev.swift" -o "$DIR/jev"
swiftc -O "$DIR/Guide.swift" "$DIR/DesktopSnapshot.swift" "$DIR/JevApp.swift" "$DIR/PopupPanel.swift" "$DIR/OverlayWindow.swift" "$DIR/main.swift" -o "$DIR/jev-ui"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$DIR/jev-ui" "$STAGED_APP/Contents/MacOS/jev-ui"
ICONSET="$STAGE_ROOT/Jev.iconset"
mkdir -p "$ICONSET"
/usr/bin/sips -z 16 16 "$DIR/Assets/JevIcon.png" --out "$ICONSET/icon_16x16.png" >/dev/null
/usr/bin/sips -z 32 32 "$DIR/Assets/JevIcon.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
/usr/bin/sips -z 32 32 "$DIR/Assets/JevIcon.png" --out "$ICONSET/icon_32x32.png" >/dev/null
/usr/bin/sips -z 64 64 "$DIR/Assets/JevIcon.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
/usr/bin/sips -z 128 128 "$DIR/Assets/JevIcon.png" --out "$ICONSET/icon_128x128.png" >/dev/null
/usr/bin/sips -z 256 256 "$DIR/Assets/JevIcon.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
/usr/bin/sips -z 256 256 "$DIR/Assets/JevIcon.png" --out "$ICONSET/icon_256x256.png" >/dev/null
/usr/bin/sips -z 512 512 "$DIR/Assets/JevIcon.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
/usr/bin/sips -z 512 512 "$DIR/Assets/JevIcon.png" --out "$ICONSET/icon_512x512.png" >/dev/null
/usr/bin/sips -z 1024 1024 "$DIR/Assets/JevIcon.png" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
/usr/bin/iconutil -c icns "$ICONSET" -o "$STAGED_APP/Contents/Resources/Jev.icns"
cat > "$STAGED_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>jev-ui</string>
	<key>CFBundleIdentifier</key>
	<string>dev.jev.app</string>
	<key>CFBundleIconFile</key>
	<string>Jev</string>
	<key>CFBundleDisplayName</key>
	<string>Jev</string>
	<key>CFBundleName</key>
	<string>Jev</string>
	<key>CFBundleShortVersionString</key>
	<string>0.2</string>
	<key>CFBundleVersion</key>
	<string>2</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSScreenCaptureUsageDescription</key>
	<string>Jev reads a screenshot only to identify visible controls for the on-screen tutorial. It sends a screenshot to the configured guide model only while you request a guide.</string>
</dict>
</plist>
PLIST
SIGNING_IDENTITY="$(/bin/zsh "$DIR/setup-signing.sh")"
/usr/bin/xattr -cr "$STAGED_APP"
# Sign the *bundle*, not only its executable. TCC evaluates the bundle's
# designated requirement when deciding whether this is the Jev the person
# approved for Screen Recording / Accessibility.
/usr/bin/codesign --force --deep --sign "$SIGNING_IDENTITY" --identifier "dev.jev.app" "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
/bin/mkdir -p "$SUPPORT_DIR"
/bin/cp "$DIR/.env" "$SUPPORT_DIR/.env"
/bin/chmod 600 "$SUPPORT_DIR/.env"
/bin/rm -rf "$INSTALL_APP"
/bin/mv "$STAGED_APP" "$INSTALL_APP"
/bin/rm -rf "$SOURCE_LINK"
/bin/ln -s "$INSTALL_APP" "$SOURCE_LINK"
# Desktop File Provider metadata can invalidate a code signature after the
# bundle is moved into this workspace. Run the signed app from Applications;
# the source-tree path above is only a convenience link for `open Jev.app`.
echo "built $INSTALL_APP"
pkill -x jev-ui 2>/dev/null || true
sleep 1
# Launch through LaunchServices so the privacy prompt is associated with Jev's
# app bundle rather than a terminal-launched bare executable.
open -n "$INSTALL_APP"
