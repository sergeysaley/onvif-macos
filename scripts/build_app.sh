#!/bin/bash
# Builds "ONVIF Browser.app" with an ad-hoc signature.
#
#   ./scripts/build_app.sh                 # x86_64 (default)
#   ARCHS="x86_64 arm64" ./scripts/build_app.sh   # universal binary
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_NAME="ONVIF Browser"
PRODUCT="ONVIFBrowser"
ARCHS="${ARCHS:-x86_64}"
BUILD_DIR="$ROOT/build"
BUNDLE="$BUILD_DIR/$APP_NAME.app"

ARCH_FLAGS=()
for arch in $ARCHS; do ARCH_FLAGS+=(--arch "$arch"); done

echo "==> swift build (release, $ARCHS)"
swift build -c release "${ARCH_FLAGS[@]}" --product "$PRODUCT"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

echo "==> Assembling $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources" "$BUNDLE/Contents/Frameworks"
cp "$BIN_DIR/$PRODUCT" "$BUNDLE/Contents/MacOS/$PRODUCT"
cp "$ROOT/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# Icon: Resources/AppIcon.icns, or generated from Resources/AppIcon.png (1024x1024) if that is newer.
ICON_PNG="$ROOT/Resources/AppIcon.png"
ICON_ICNS="$ROOT/Resources/AppIcon.icns"
if [ -f "$ICON_PNG" ] && { [ ! -f "$ICON_ICNS" ] || [ "$ICON_PNG" -nt "$ICON_ICNS" ]; }; then
    echo "==> Generating AppIcon.icns from AppIcon.png"
    ICONSET="$BUILD_DIR/AppIcon.iconset"
    rm -rf "$ICONSET" && mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z $size $size "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z $double $double "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$ICON_ICNS"
fi
if [ -f "$ICON_ICNS" ]; then
    cp "$ICON_ICNS" "$BUNDLE/Contents/Resources/AppIcon.icns"
fi

# macOS 10.15 and 11 do not ship the Swift concurrency runtime: bundle the back-deployed copy.
if otool -L "$BUNDLE/Contents/MacOS/$PRODUCT" | grep -q "libswift_Concurrency"; then
    TOOLCHAIN_USR="$(dirname "$(dirname "$(xcrun --find swift)")")"
    CONCURRENCY_LIB="$TOOLCHAIN_USR/lib/swift-5.5/macosx/libswift_Concurrency.dylib"
    if [ ! -f "$CONCURRENCY_LIB" ]; then
        CONCURRENCY_LIB="$(find "$(xcode-select -p)" -path '*swift-5.5/macosx/libswift_Concurrency.dylib' 2>/dev/null | head -n 1)"
    fi
    if [ -n "$CONCURRENCY_LIB" ] && [ -f "$CONCURRENCY_LIB" ]; then
        echo "==> Bundling $CONCURRENCY_LIB"
        cp "$CONCURRENCY_LIB" "$BUNDLE/Contents/Frameworks/"
    else
        echo "WARNING: libswift_Concurrency.dylib (back-deploy) not found; the app will not start on macOS 10.15/11." >&2
    fi
fi

echo "==> Ad-hoc signing"
if ls "$BUNDLE/Contents/Frameworks/"*.dylib >/dev/null 2>&1; then
    codesign --force --sign - --timestamp=none "$BUNDLE/Contents/Frameworks/"*.dylib
fi
codesign --force --sign - --timestamp=none "$BUNDLE"
codesign --verify --verbose=2 "$BUNDLE"

echo "==> Done: $BUNDLE"
lipo -info "$BUNDLE/Contents/MacOS/$PRODUCT" || true
