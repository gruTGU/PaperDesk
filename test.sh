#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
CACHE_DIR="${PAPERDESK_BUILD_CACHE:-$PROJECT_DIR/work/module-cache}"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
HOST_ARCH="$(uname -m)"
mkdir -p "$BUILD_DIR" "$CACHE_DIR"
export CLANG_MODULE_CACHE_PATH="$CACHE_DIR"

xcrun swiftc -swift-version 5 \
  -target "$HOST_ARCH-apple-macosx13.0" -sdk "$SDK_PATH" \
  -module-cache-path "$CACHE_DIR" \
  -framework AppKit -framework PDFKit -framework ImageIO -framework UniformTypeIdentifiers \
  "$PROJECT_DIR/Sources/Models.swift" \
  "$PROJECT_DIR/Sources/ImageTools.swift" \
  "$PROJECT_DIR/Sources/Conversion.swift" \
  "$PROJECT_DIR/Sources/PDFExporter.swift" \
  "$PROJECT_DIR/Tests/TestMain.swift" \
  -o "$BUILD_DIR/tests"
"$BUILD_DIR/tests"
