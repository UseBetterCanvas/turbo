#!/usr/bin/env bash
# Builds Turbo.app (menu bar only, ad-hoc signed) into ./build.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
# Universal binary (Apple Silicon + Intel). Set ARCHS="" to build for this Mac only.
ARCH_FLAGS=()
for arch in ${ARCHS-arm64 x86_64}; do ARCH_FLAGS+=(--arch "$arch"); done
swift build -c release --product Turbo "${ARCH_FLAGS[@]}"
BIN="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)/Turbo"

APP="build/Turbo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Turbo"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Resources/Fonts" && cp Resources/Fonts/*.ttf "$APP/Contents/Resources/Fonts/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Turbo</string>
    <key>CFBundleDisplayName</key><string>Turbo</string>
    <key>CFBundleIdentifier</key><string>com.bettercampus.turbo</string>
    <key>CFBundleExecutable</key><string>Turbo</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
(cd build && rm -f Turbo.zip && ditto -c -k --keepParent Turbo.app Turbo.zip)
echo "Built $APP"
