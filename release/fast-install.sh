#!/usr/bin/env bash

# Build the signed Release app for local use and replace /Applications/Octo.app.
# This deliberately skips packaging, notarization, stapling, and publishing.

set -euo pipefail

readonly APP_NAME="Octo.app"
readonly APP_BUNDLE_ID="io.github.blackforestboi.Octo"
readonly TEAM_ID="5YUPQC9D96"
readonly INSTALL_PATH="/Applications/${APP_NAME}"
readonly DERIVED_DATA_PATH="$(pwd)/build/DerivedData-Release"
readonly BUILT_APP_PATH="${DERIVED_DATA_PATH}/Build/Products/Release/${APP_NAME}"
readonly BUILD_LOG_PATH="${DERIVED_DATA_PATH}/Logs/fast-install.log"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

for command in xcodebuild ditto osascript; do
  command -v "$command" >/dev/null 2>&1 || die "Required command is unavailable: $command"
done

developer_id_identity="${DEVELOPER_ID_IDENTITY:-}"
if [[ -z "$developer_id_identity" ]]; then
	developer_id_identity="$(security find-identity -v -p codesigning 2>/dev/null | awk -v team="$TEAM_ID" '/Developer ID Application:/ && index($0, team) { print $2; exit }')"
fi
[[ -n "$developer_id_identity" ]] || die "No Developer ID Application identity found for team $TEAM_ID"

[[ -d /Applications ]] || die "/Applications is unavailable"
if [[ -e "$INSTALL_PATH" && ! -O "$INSTALL_PATH" ]]; then
  die "$INSTALL_PATH is not owned by $USER; replace it once with administrator privileges, then rerun this command"
fi

# Stop the installed menu-bar app before its bundle is replaced. It may not be
# running, so an AppleScript failure here is intentionally non-fatal.
osascript -e "tell application id \"${APP_BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true

if ! xcodebuild \
  -scheme Octo \
  -configuration Release \
	-derivedDataPath "$DERIVED_DATA_PATH" \
	-skipMacroValidation \
	-skipPackagePluginValidation \
	CODE_SIGN_STYLE=Manual \
	CODE_SIGN_IDENTITY="$developer_id_identity" \
	DEVELOPMENT_TEAM="$TEAM_ID" \
	build >"$BUILD_LOG_PATH" 2>&1; then
  tail -n 100 "$BUILD_LOG_PATH" >&2
  die "Release build failed; full log: $BUILD_LOG_PATH"
fi

[[ -d "$BUILT_APP_PATH" ]] || die "Release build did not produce $BUILT_APP_PATH"

backup_path=""
if [[ -e "$INSTALL_PATH" ]]; then
  backup_path="$(mktemp -d "${TMPDIR:-/tmp}/octo-install.XXXXXX")/${APP_NAME}"
  mv "$INSTALL_PATH" "$backup_path"
fi

if ! ditto "$BUILT_APP_PATH" "$INSTALL_PATH"; then
  [[ -n "$backup_path" && -e "$backup_path" ]] && mv "$backup_path" "$INSTALL_PATH"
  die "Could not install the new app; the previous app was restored"
fi

[[ -n "$backup_path" ]] && rm -rf "${backup_path%/${APP_NAME}}"

printf 'Installed %s\n' "$INSTALL_PATH"
open -a "$INSTALL_PATH"
