#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$PROJECT_DIR/build/PaperDesk.app"
EXECUTABLE="$APP_DIR/Contents/MacOS/PaperDesk"
NEEDS_BUILD=false
if [[ ! -x "$EXECUTABLE" || ! -f "$APP_DIR/Contents/Info.plist" || "$PROJECT_DIR/build.sh" -nt "$EXECUTABLE" ]]; then
  NEEDS_BUILD=true
else
  for source_file in "$PROJECT_DIR"/Sources/*.swift; do
    if [[ "$source_file" -nt "$EXECUTABLE" ]]; then NEEDS_BUILD=true; break; fi
  done
fi
if [[ "$NEEDS_BUILD" == true ]]; then "$PROJECT_DIR/build.sh"; fi
open "$APP_DIR" --args "$@"
