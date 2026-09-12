#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${PAPERDESK_BUILD_CACHE:-$PROJECT_DIR/work/module-cache}"
mkdir -p "$PROJECT_DIR/build" "$CACHE_DIR" "$PROJECT_DIR/work/ui-test"
xcrun swiftc -swift-version 5 -module-cache-path "$CACHE_DIR" \
  "$PROJECT_DIR/Sources/Models.swift" "$PROJECT_DIR/Sources/CanvasView.swift" \
  "$PROJECT_DIR/Sources/EditorController.swift" "$PROJECT_DIR/Sources/PDFExporter.swift" \
  "$PROJECT_DIR/Sources/ImageTools.swift" "$PROJECT_DIR/Sources/Conversion.swift" \
  "$PROJECT_DIR/Sources/ImageActions.swift" "$PROJECT_DIR/Sources/WorkspaceController.swift" \
  "$PROJECT_DIR/Sources/StorageManager.swift" "$PROJECT_DIR/Tests/EditorSmoke.swift" \
  "$PROJECT_DIR/Tests/CanvasNavigationTests.swift" "$PROJECT_DIR/Tests/WorkspaceTests.swift" \
  -o "$PROJECT_DIR/build/ui-tests"
"$PROJECT_DIR/build/ui-tests" "$PROJECT_DIR/work/ui-test"
