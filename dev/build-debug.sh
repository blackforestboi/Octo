#!/usr/bin/env bash

set -euo pipefail

readonly DERIVED_DATA_PATH="$HOME/Library/Developer/Xcode/DerivedData/OctoDebugShared"
readonly APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug/Octo Debug.app"
readonly LOCK_PATH="${TMPDIR:-/tmp}/io.github.blackforestboi.Octo.debug-build.lock"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

release_lock() {
  rm -f "$LOCK_PATH/pid"
  rmdir "$LOCK_PATH" 2>/dev/null || true
}

acquire_lock() {
  while ! mkdir "$LOCK_PATH" 2>/dev/null; do
    local owner_pid=""
    if [[ -f "$LOCK_PATH/pid" ]]; then
      owner_pid="$(<"$LOCK_PATH/pid")"
    fi

    if [[ -n "$owner_pid" ]] && kill -0 "$owner_pid" 2>/dev/null; then
      echo "Another Octo Debug build (PID $owner_pid) is using the canonical output. Waiting..."
      sleep 2
      continue
    fi

    rm -f "$LOCK_PATH/pid"
    rmdir "$LOCK_PATH" 2>/dev/null || true
  done

  printf '%s\n' "$$" > "$LOCK_PATH/pid"
  trap release_lock EXIT INT TERM
}

usage() {
  echo "Usage: $0 [--unsigned] [--launch] [--test]"
}

unsigned=false
launch=false
action=build

for argument in "$@"; do
  case "$argument" in
    --unsigned) unsigned=true ;;
    --launch) launch=true ;;
    --test) action=test ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

acquire_lock
cd "$PROJECT_ROOT"

build_arguments=(
  -project Hex.xcodeproj
  -scheme Octo
  -configuration Debug
  -derivedDataPath "$DERIVED_DATA_PATH"
  -skipMacroValidation
  -skipPackagePluginValidation
)

if [[ "$unsigned" == true ]]; then
  build_arguments+=(CODE_SIGNING_ALLOWED=NO)
fi

echo "Building the single canonical Debug app at: $APP_PATH"
xcodebuild "${build_arguments[@]}" "$action"

if [[ "$launch" == true ]]; then
  open "$APP_PATH"
fi
