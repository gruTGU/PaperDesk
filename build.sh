#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
CACHE_DIR="${PAPERDESK_BUILD_CACHE:-$PROJECT_DIR/work/module-cache}"
APP_DIR="$BUILD_DIR/PaperDesk.app"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  arm64|x86_64) ;;
  *) echo "不支持的 Mac 架构：$HOST_ARCH" >&2; exit 1 ;;
esac

mkdir -p "$CACHE_DIR" "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
export CLANG_MODULE_CACHE_PATH="$CACHE_DIR"

echo "正在编译 PaperDesk（${HOST_ARCH}，macOS 13+）…"
xcrun swiftc -swift-version 5 -O \
  -target "$HOST_ARCH-apple-macosx13.0" -sdk "$SDK_PATH" \
  -module-cache-path "$CACHE_DIR" \
  -framework AppKit -framework PDFKit -framework ImageIO -framework UniformTypeIdentifiers \
  "$PROJECT_DIR"/Sources/*.swift \
  -o "$APP_DIR/Contents/MacOS/PaperDesk.new"
mv -f "$APP_DIR/Contents/MacOS/PaperDesk.new" "$APP_DIR/Contents/MacOS/PaperDesk"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleExecutable</key><string>PaperDesk</string>
  <key>CFBundleIdentifier</key><string>local.paperdesk</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>PaperDesk</string>
  <key>CFBundleDisplayName</key><string>PaperDesk 作业排版</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><false/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>PaperDesk 工程</string>
    <key>CFBundleTypeRole</key><string>Editor</string>
    <key>LSHandlerRank</key><string>Owner</string>
    <key>LSItemContentTypes</key><array><string>local.paperdesk.document</string></array>
  </dict></array>
  <key>UTExportedTypeDeclarations</key><array><dict>
    <key>UTTypeIdentifier</key><string>local.paperdesk.document</string>
    <key>UTTypeDescription</key><string>PaperDesk 工程</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string><string>public.content</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>paperdesk</string></array></dict>
  </dict></array>
</dict>
</plist>
PLIST

/usr/bin/codesign --force --deep --sign - "$APP_DIR"
echo "构建完成：$APP_DIR"
