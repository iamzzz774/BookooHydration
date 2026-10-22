#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_DIR="$BUILD_DIR/BookooHydrationStandalone.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
LAUNCH_AGENTS_DIR="$CONTENTS_DIR/Library/LaunchAgents"
ICONSET_DIR="$BUILD_DIR/BookooHydration.iconset"
MODULE_CACHE_DIR="$PROJECT_DIR/.build/module-cache"

cd "$PROJECT_DIR"
UNIVERSAL=false
if [[ "${1:-}" == "--universal" && $# -eq 1 ]]; then
    UNIVERSAL=true
elif [[ $# -gt 0 ]]; then
    echo "Usage: scripts/build_app.sh [--universal]" >&2
    exit 2
fi
mkdir -p "$MODULE_CACHE_DIR"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIR"
if [[ -z "${SDKROOT:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk ]]; then
    export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk
fi
echo "Building BookooHydration (release)..."
if $UNIVERSAL; then
    for ARCH in x86_64 arm64; do
        swift build --disable-sandbox -c release --arch "$ARCH" --product BookooHydration
    done
else
    swift build --disable-sandbox -c release --product BookooHydration
fi
BIN_DIR="$(swift build --disable-sandbox -c release --show-bin-path)"

rm -rf "$APP_DIR" "$ICONSET_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$LAUNCH_AGENTS_DIR"
if $UNIVERSAL; then
    X86_DIR="$(swift build --disable-sandbox -c release --arch x86_64 --show-bin-path)"
    ARM_DIR="$(swift build --disable-sandbox -c release --arch arm64 --show-bin-path)"
    lipo -create "$X86_DIR/BookooHydration" "$ARM_DIR/BookooHydration" -output "$MACOS_DIR/BookooHydration"
    for ARCH in x86_64 arm64; do
        swiftc -target "$ARCH-apple-macosx13.0" "$PROJECT_DIR/scripts/login_helper.swift" -o "$BUILD_DIR/login-helper-$ARCH"
    done
    lipo -create "$BUILD_DIR/login-helper-x86_64" "$BUILD_DIR/login-helper-arm64" -output "$MACOS_DIR/BookooHydrationLoginHelper"
else
    cp "$BIN_DIR/BookooHydration" "$MACOS_DIR/BookooHydration"
    swiftc "$PROJECT_DIR/scripts/login_helper.swift" -o "$MACOS_DIR/BookooHydrationLoginHelper"
fi
cat > "$LAUNCH_AGENTS_DIR/io.github.iamzzz774.BookooHydration.Standalone.login.plist" <<'AGENT_PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.github.iamzzz774.BookooHydration.Standalone.login</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/BookooHydrationLoginHelper</string>
    <key>RunAtLoad</key>
    <true/>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>io.github.iamzzz774.BookooHydration.Standalone</string>
    </array>
</dict>
</plist>
AGENT_PLIST
plutil -lint "$LAUNCH_AGENTS_DIR/io.github.iamzzz774.BookooHydration.Standalone.login.plist"

echo "Generating application icon..."
swiftc "$PROJECT_DIR/scripts/generate_icon.swift" -o "$BUILD_DIR/generate_icon" -framework AppKit
"$BUILD_DIR/generate_icon" "$ICONSET_DIR" "$RESOURCES_DIR/AppIcon.icns"
rm -rf "$ICONSET_DIR"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>BookooHydration 普通版</string>
    <key>CFBundleExecutable</key>
    <string>BookooHydration</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.iamzzz774.BookooHydration.Standalone</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>BookooHydration</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>连接 BOOKOO 咖啡秤以读取杯子重量并记录喝水量。</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

plutil -lint "$CONTENTS_DIR/Info.plist"
echo "Removing build-machine debug paths..."
strip -S "$MACOS_DIR/BookooHydration" "$MACOS_DIR/BookooHydrationLoginHelper"
echo "Ad-hoc signing application..."
codesign --force --sign - "$MACOS_DIR/BookooHydrationLoginHelper"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "Built and verified: $APP_DIR"
