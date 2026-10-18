#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_DIR="${PAPERDESK_BUILD_CACHE:-$PROJECT_DIR/work/module-cache}"
ICON_WORK="$(mktemp -d "${TMPDIR:-/tmp}/PaperDesk-icon.XXXXXX")"
trap 'rm -rf "$ICON_WORK"' EXIT
mkdir -p "$PROJECT_DIR/Resources" "$CACHE_DIR" "$ICON_WORK/AppIcon.iconset"
xcrun swift -module-cache-path "$CACHE_DIR" "$PROJECT_DIR/scripts/generate-icon.swift" "$ICON_WORK/AppIcon.iconset"
/usr/bin/iconutil -c icns "$ICON_WORK/AppIcon.iconset" -o "$PROJECT_DIR/Resources/AppIcon.icns"
cp "$ICON_WORK/AppIcon.iconset/icon_512x512@2x.png" "$PROJECT_DIR/Resources/AppIcon.png"
printf 'Generated Resources/AppIcon.icns and Resources/AppIcon.png\n'
