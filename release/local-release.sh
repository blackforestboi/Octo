#!/usr/bin/env bash

# Builds and notarizes Octo locally, then publishes only the completed assets
# and signed Sparkle feed. Nothing runs on GitHub except the Pages deployment
# triggered by the committed appcast update.

set -euo pipefail

readonly TEAM_ID="5YUPQC9D96"
readonly NOTARY_PROFILE_DEFAULT="AC_PASSWORD"
readonly SPARKLE_KEYCHAIN_SERVICE_DEFAULT="Octo Sparkle Private Key"

usage() {
  cat <<'USAGE'
Usage:
  bun run release -- --local-build --tag v<version> --publish
  bun run release:local -- --tag v<version> --publish

Build, notarize, staple, and publish an Octo release from this Mac.

Required:
  --local-build    Perform the archive, Developer ID signing, notarization,
                   stapling, and packaging on this Mac.
  --tag v<version>  Version tag, matching CFBundleShortVersionString.
  --publish         Required acknowledgement that this command will create/push
                    the tag, create or update a GitHub Release, and push the
                    signed Sparkle appcast commit to the default branch.

Optional environment:
  DEVELOPER_ID_IDENTITY       Codesigning identity SHA-1 hash. If omitted, the
                              first Developer ID Application identity for team
                              5YUPQC9D96 is used.
  NOTARY_PROFILE              notarytool Keychain profile (default: AC_PASSWORD)
  SPARKLE_PRIVATE_KEY_FILE    Path to the Sparkle private Ed25519 key. If unset,
                              it is read from the Keychain service below.
  SPARKLE_KEYCHAIN_SERVICE    Keychain service holding the Sparkle private key
                              (default: Octo Sparkle Private Key)

Prerequisites:
  - A clean checkout of the default branch with the release version committed.
  - A valid Developer ID Application identity for team 5YUPQC9D96.
  - A validated notarytool Keychain profile.
  - GitHub CLI authentication with repository write access.
  - The Sparkle private key available through SPARKLE_PRIVATE_KEY_FILE or the
    configured Keychain service.
USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command is unavailable: $1"
}

read_latest_appcast_build() {
  python3 - "$1" <<'PYTHON'
import sys
import xml.etree.ElementTree as ET

sparkle_namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
root = ET.parse(sys.argv[1]).getroot()
builds = []
for element in root.iter():
    if element.tag == f"{sparkle_namespace}version" and element.text:
        value = element.text.strip()
        if value.isdigit():
            builds.append(int(value))
print(max(builds) if builds else "")
PYTHON
}

tag=""
publish=false
local_build=false

while (($#)); do
  case "$1" in
    --local-build|--local)
      local_build=true
      shift
      ;;
    --tag)
      (($# >= 2)) || die "--tag requires a value"
      tag="$2"
      shift 2
      ;;
    --publish)
      publish=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ "$local_build" == true ]] || die "This release entrypoint requires --local-build so packaging and notarization happen locally"
[[ "$tag" =~ ^v[0-9]+(\.[0-9]+)+$ ]] || die "--tag must look like v2026.7.311"
[[ "$publish" == true ]] || die "Refusing to publish without --publish"

for command in xcodebuild xcrun codesign ditto hdiutil gh git curl python3 security lipo plutil shasum; do
  require_command "$command"
done

working_tree_status="$(git status --porcelain --untracked-files=all)"
[[ -z "$working_tree_status" ]] || die "Working tree is not clean; commit or remove all changes before releasing"

default_branch="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
[[ -n "$default_branch" ]] || default_branch="main"
current_branch="$(git branch --show-current)"
[[ "$current_branch" == "$default_branch" ]] || die "Run from the default branch ($default_branch), not $current_branch"

version="${tag#v}"
source_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Hex/Info.plist)"
[[ "$source_version" == "$version" ]] || die "Tag $tag does not match Hex/Info.plist version $source_version"

source_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Hex/Info.plist)"
[[ "$source_build" =~ ^[1-9][0-9]*$ ]] || die "Hex/Info.plist CFBundleVersion must be a positive integer: $source_build"
project_builds="$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION = ([0-9]+);/\1/p' Hex.xcodeproj/project.pbxproj | sort -u)"
[[ "$project_builds" == "$source_build" ]] || die "Build metadata disagrees: Info.plist=$source_build, project settings=$project_builds"

tag_exists=false
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  git merge-base --is-ancestor "$(git rev-list -n 1 "$tag")" HEAD || die "Existing tag $tag is not part of the current branch"
  tag_exists=true
elif git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
  die "Remote tag $tag exists but is not available locally for verification"
fi

identity="${DEVELOPER_ID_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity="$(security find-identity -v -p codesigning 2>/dev/null | awk -v team="$TEAM_ID" '/Developer ID Application:/ && index($0, team) {print $2; exit}')"
fi
[[ -n "$identity" ]] || die "No Developer ID Application identity found for team $TEAM_ID"

notary_profile="${NOTARY_PROFILE:-$NOTARY_PROFILE_DEFAULT}"
notary_args=(--keychain-profile "$notary_profile")
if [[ -n "${NOTARY_KEY_FILE:-}" ]]; then
  [[ -r "$NOTARY_KEY_FILE" ]] || die "Notary API key is unreadable: $NOTARY_KEY_FILE"
  : "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required with NOTARY_KEY_FILE}"
  : "${NOTARY_ISSUER:?NOTARY_ISSUER is required with NOTARY_KEY_FILE}"
  notary_args=(--key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
else
  xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1 || die "Notarytool Keychain profile '$notary_profile' is unavailable"
fi

generate_appcast="$(pwd)/bin/generate_appcast"
[[ -x "$generate_appcast" ]] || die "Sparkle generate_appcast is unavailable at $generate_appcast"

repository="$(git remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')"
[[ -n "$repository" ]] || die "Unable to identify the GitHub repository"

work_directory="$(mktemp -d "${TMPDIR:-/tmp}/octo-release.XXXXXX")"
cleanup() {
  rm -rf "$work_directory"
}
trap cleanup EXIT

published_appcast="$work_directory/published-appcast.xml"
if ! curl --fail --location --silent --show-error --output "$published_appcast" "https://blackforestboi.github.io/Octo/appcast.xml"; then
  cp docs/updates/appcast.xml "$published_appcast"
fi

repository_appcast="$work_directory/repository-appcast.xml"
cp docs/updates/appcast.xml "$repository_appcast"
live_published_build="$(read_latest_appcast_build "$published_appcast")"
repository_published_build="$(read_latest_appcast_build "$repository_appcast")"
latest_published_build="$live_published_build"
if [[ -z "$latest_published_build" || ( -n "$repository_published_build" && "$repository_published_build" -gt "$latest_published_build" ) ]]; then
  latest_published_build="$repository_published_build"
fi

if [[ -n "$latest_published_build" ]]; then
  if [[ "$tag_exists" == false && "$source_build" -le "$latest_published_build" ]]; then
    next_build=$((latest_published_build + 1))
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $next_build" Hex/Info.plist
    sed -E -i '' "s/^([[:space:]]*)CURRENT_PROJECT_VERSION = [0-9]+;/\1CURRENT_PROJECT_VERSION = $next_build;/" Hex.xcodeproj/project.pbxproj
    source_build="$next_build"
    project_builds="$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION = ([0-9]+);/\1/p' Hex.xcodeproj/project.pbxproj | sort -u)"
    [[ "$project_builds" == "$source_build" ]] || die "Failed to update all project build settings to $source_build"
    git add Hex/Info.plist Hex.xcodeproj/project.pbxproj
    git commit -m "chore(release): increment build number to $source_build"
    git push origin "HEAD:$default_branch"
    printf 'Incremented release build number to %s\n' "$source_build"
  fi

  if [[ "$tag_exists" == true ]]; then
    [[ "$source_build" -ge "$latest_published_build" ]] || die "Build $source_build is older than the published Sparkle build $latest_published_build"
  else
    [[ "$source_build" -gt "$latest_published_build" ]] || die "Build $source_build is not newer than the published Sparkle build $latest_published_build"
  fi
fi

release_derived_data="$(pwd)/build/DerivedData-Release"
dependency_fingerprint_file="$release_derived_data/.dependency-fingerprint"
dependency_inputs=(
  "HexCore/Package.swift"
  "HexCore/Package.resolved"
  "Hex.xcodeproj/project.pbxproj"
  "Hex.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
)
for dependency_input in "${dependency_inputs[@]}"; do
  [[ -f "$dependency_input" ]] || die "Dependency input is missing: $dependency_input"
done

dependency_fingerprint="$({
  printf '%s\n' 'Xcode toolchain:'
  xcodebuild -version
  for dependency_input in "${dependency_inputs[@]}"; do
    printf '%s\n' "$dependency_input"
    if [[ "$dependency_input" == "Hex.xcodeproj/project.pbxproj" ]]; then
      sed -E '/^[[:space:]]*(CURRENT_PROJECT_VERSION|MARKETING_VERSION) = /d' "$dependency_input" | shasum -a 256
    else
      shasum -a 256 "$dependency_input"
    fi
  done
} | shasum -a 256 | awk '{print $1}')"

build_mode="incremental"
cached_dependency_fingerprint=""
if [[ -f "$dependency_fingerprint_file" ]]; then
  cached_dependency_fingerprint="$(<"$dependency_fingerprint_file")"
fi
if [[ "$cached_dependency_fingerprint" != "$dependency_fingerprint" ]]; then
  build_mode="full (dependency fingerprint changed)"
  rm -rf "$release_derived_data"
fi
mkdir -p "$release_derived_data"
printf 'Release build mode: %s\n' "$build_mode"

archive_path="$work_directory/Octo.xcarchive"
app_path="$archive_path/Products/Applications/Octo.app"
notarization_zip="$work_directory/Octo-notarization.zip"
release_directory="$(pwd)/build/releases/$version"
zip_path="$release_directory/Octo-$version.zip"
dmg_path="$release_directory/Octo-$version.dmg"

mkdir -p "$release_directory"

xcodebuild archive \
  -scheme Octo \
  -configuration Release \
  -archivePath "$archive_path" \
  -derivedDataPath "$release_derived_data" \
  -skipMacroValidation \
  -skipPackagePluginValidation \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$identity" \
  DEVELOPMENT_TEAM="$TEAM_ID"

printf '%s\n' "$dependency_fingerprint" > "$dependency_fingerprint_file"

[[ -d "$app_path" ]] || die "Archive did not contain Octo.app"

# Preserve the app's Xcode-generated entitlements before re-signing the bundle.
# Re-signing without --entitlements strips microphone access from hardened-runtime
# releases, causing TCC to reject the request without displaying a prompt.
app_entitlements="$work_directory/Octo.entitlements"
codesign -d --entitlements :- "$app_path" > "$app_entitlements"
plutil -lint "$app_entitlements" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$app_entitlements")" == "true" ]] \
  || die "Archived app is missing the microphone audio-input entitlement"

# Sparkle's macOS XCFramework slice is universal. Thin every executable in it
# before signing so the entire release, not only Octo's main executable, is
# Apple Silicon-only.
sparkle_path="$app_path/Contents/Frameworks/Sparkle.framework"
sparkle_binaries=(
  "$sparkle_path/Versions/B/Autoupdate"
  "$sparkle_path/Versions/B/Updater.app/Contents/MacOS/Updater"
  "$sparkle_path/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
  "$sparkle_path/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
  "$sparkle_path/Versions/B/Sparkle"
)
for binary in "${sparkle_binaries[@]}"; do
  [[ -f "$binary" ]] || die "Expected Sparkle binary is missing: $binary"
  architectures="$(lipo -archs "$binary")"
  if [[ "$architectures" != "arm64" ]]; then
    [[ " $architectures " == *" arm64 "* ]] || die "Sparkle binary has no arm64 slice: $binary ($architectures)"
    lipo "$binary" -thin arm64 -output "$binary.arm64"
    mv "$binary.arm64" "$binary"
  fi
done

# Xcode signs the app bundle, but Sparkle contains nested executable code that
# must receive its own Developer ID signature and secure timestamp after thinning.
for component in \
  "$sparkle_path/Versions/B/Autoupdate" \
  "$sparkle_path/Versions/B/Updater.app" \
  "$sparkle_path/Versions/B/XPCServices/Downloader.xpc" \
  "$sparkle_path/Versions/B/XPCServices/Installer.xpc" \
  "$sparkle_path"; do
  [[ -e "$component" ]] || die "Expected Sparkle component is missing: $component"
  codesign --force --options runtime --timestamp --sign "$identity" "$component"
done

codesign \
  --force \
  --options runtime \
  --timestamp \
  --entitlements "$app_entitlements" \
  --sign "$identity" \
  "$app_path"

signed_app_entitlements="$work_directory/Octo-signed.entitlements"
codesign -d --entitlements :- "$app_path" > "$signed_app_entitlements"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$signed_app_entitlements")" == "true" ]] \
  || die "Signed app lost the microphone audio-input entitlement"

codesign --verify --deep --strict --verbose=2 "$app_path"

executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_path/Contents/Info.plist")"
executable_path="$app_path/Contents/MacOS/$executable_name"
archive_architectures="$(lipo -archs "$executable_path")"
[[ "$archive_architectures" == "arm64" ]] || die "Built app must be Apple Silicon-only; found architectures: $archive_architectures"

while IFS= read -r -d '' candidate; do
  candidate_architectures="$(lipo -archs "$candidate" 2>/dev/null || true)"
  [[ -z "$candidate_architectures" || "$candidate_architectures" == "arm64" ]] || die "Release contains a non-arm64 Mach-O binary: $candidate ($candidate_architectures)"
done < <(find "$app_path" -type f -print0)

archive_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
[[ "$archive_version" == "$version" ]] || die "Built app version $archive_version does not match tag $tag"
archive_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist")"
[[ "$archive_build" == "$source_build" ]] || die "Built app build $archive_build does not match source build $source_build"

ditto -c -k --sequesterRsrc --keepParent "$app_path" "$notarization_zip"
xcrun notarytool submit "$notarization_zip" "${notary_args[@]}" --wait
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"

ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"
hdiutil create -volname "Octo $version" -srcfolder "$app_path" -ov -format UDZO "$dmg_path"
xcrun notarytool submit "$dmg_path" "${notary_args[@]}" --wait
xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"

unzip -tqq "$zip_path" >/dev/null
spctl --assess --type execute --verbose=4 "$app_path"
# DMGs are notarized containers, not executable code. `spctl --type open` reports
# "no usable signature" for a valid stapled DMG; stapler validation above is the
# authoritative validation for the disk image, while Gatekeeper assesses the app.

if [[ "$tag_exists" == false ]]; then
  git tag -a "$tag" -m "Release $tag"
fi
if [[ "$tag_exists" == false ]]; then
  git push origin "$tag"
fi

if gh release view "$tag" --repo "$repository" >/dev/null 2>&1; then
  gh release upload "$tag" --repo "$repository" --clobber "$zip_path" "$dmg_path"
else
  gh release create "$tag" --repo "$repository" --verify-tag --title "Octo $version" --generate-notes "$zip_path" "$dmg_path"
fi

raw_sparkle_key="$work_directory/sparkle-private-key.raw"
sparkle_key="$work_directory/sparkle-private-key"
if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
  [[ -r "$SPARKLE_PRIVATE_KEY_FILE" ]] || die "Sparkle key file is unreadable: $SPARKLE_PRIVATE_KEY_FILE"
  cp "$SPARKLE_PRIVATE_KEY_FILE" "$raw_sparkle_key"
else
  security find-generic-password \
    -a "${USER}" \
    -s "${SPARKLE_KEYCHAIN_SERVICE:-$SPARKLE_KEYCHAIN_SERVICE_DEFAULT}" \
    -w > "$raw_sparkle_key" || die "Sparkle private key is unavailable from the Keychain"
fi

python3 - "$raw_sparkle_key" "$sparkle_key" <<'PYTHON'
import re
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text().strip()
pem = re.search(r"-----BEGIN [^-]+-----(.*?)-----END [^-]+-----", source, re.DOTALL)
normalized = "".join((pem.group(1) if pem else source).split())
if not normalized:
    raise SystemExit("Sparkle private key is empty")
Path(sys.argv[2]).write_text(normalized)
PYTHON
chmod 600 "$sparkle_key"

update_site="$work_directory/update-site"
mkdir -p "$update_site"
if ! curl --fail --location --silent --show-error --output "$update_site/appcast.xml" "https://blackforestboi.github.io/Octo/appcast.xml"; then
  cp docs/updates/appcast.xml "$update_site/appcast.xml"
fi
cp "$dmg_path" "$update_site/"
"$generate_appcast" \
  --ed-key-file "$sparkle_key" \
  --download-url-prefix "https://github.com/$repository/releases/download/$tag/" \
  --maximum-versions 0 \
  --maximum-deltas 0 \
  -o "$update_site/appcast.xml" \
  "$update_site"

python3 - "$update_site/appcast.xml" "$version" "$source_build" <<'PYTHON'
import sys
import xml.etree.ElementTree as ET

sparkle_namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
expected_version = sys.argv[2]
expected_build = sys.argv[3]
root = ET.parse(sys.argv[1]).getroot()
for item in root.findall(".//item"):
    short_version = item.findtext(f"{sparkle_namespace}shortVersionString")
    build = item.findtext(f"{sparkle_namespace}version")
    if short_version == expected_version and build == expected_build:
        raise SystemExit(0)
raise SystemExit(
    f"Generated appcast has no item for version {expected_version} and build {expected_build}"
)
PYTHON

cp "$update_site/appcast.xml" docs/updates/appcast.xml
git add docs/updates/appcast.xml
git commit -m "chore(release): publish $tag update feed"
git push origin "HEAD:$default_branch"

printf '\nRelease complete:\n  ZIP: %s\n  DMG: %s\n  GitHub: https://github.com/%s/releases/tag/%s\n  Appcast: https://blackforestboi.github.io/Octo/appcast.xml\n' \
  "$zip_path" "$dmg_path" "$repository" "$tag"
