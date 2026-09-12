#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${PAPERDESK_BUILD_CACHE:-$PROJECT_DIR/work/module-cache}"
mkdir -p "$PROJECT_DIR/build" "$CACHE_DIR"
xcrun swiftc -swift-version 5 -module-cache-path "$CACHE_DIR" \
  "$PROJECT_DIR/Sources/StorageManager.swift" "$PROJECT_DIR/Tests/StorageTests.swift" \
  -o "$PROJECT_DIR/build/storage-tests"
"$PROJECT_DIR/build/storage-tests"
