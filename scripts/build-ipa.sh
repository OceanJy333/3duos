#!/bin/bash
# Input: version, build number and the Xcode project generated from project.yml.
# Output: unsigned IPA and SHA-256 checksum, ready for personal signing.
# Pos: shared local/GitHub Actions release packaging entry.
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:-0.1.1}"
build_number="${2:-1}"
output="build/release"

xcodegen generate
mkdir -p "$output"
xcrun swiftc UI/ConsoleSkinProfile.swift UI/ConsoleShellGeometry.swift Tests/Layout/main.swift -o "$output/layout-check"
"$output/layout-check"
xcrun swiftc Core/CPU/*.swift Tests/CPU/main.swift -o "$output/cpu-check"
"$output/cpu-check"

xcodebuild -project 3duos.xcodeproj -scheme 3duos -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/ReleaseDerivedData \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

package="$(mktemp -d)"
trap 'rm -rf "$package"' EXIT
mkdir -p "$package/Payload"
ditto 'build/ReleaseDerivedData/Build/Products/Release-iphoneos/3duos Lab.app' "$package/Payload/3duos.app"
ipa="3duos-${version}-unsigned.ipa"
ditto -c -k --sequesterRsrc --keepParent "$package/Payload" "$output/$ipa"
(cd "$output" && shasum -a 256 "$ipa" > "$ipa.sha256")
echo "Created $output/$ipa (unsigned; personal signing required)"
