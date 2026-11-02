#!/bin/bash
# Input: an IPA exported and signed by Xcode, and an output IPA path.
# Output: full-signature, uncompressed IPA plus SHA-256 for re-signing tools.
# Pos: package an existing distribution build for import compatibility testing.
set -euo pipefail
cd "$(dirname "$0")/.."
source_ipa="$1"
target_ipa="$2"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
ditto --norsrc --noextattr -x -k "$source_ipa" "$stage"
shopt -s nullglob
apps=("$stage"/Payload/*.app)
[[ "${#apps[@]}" == 1 ]]
codesign --verify --deep --strict "${apps[0]}"
(cd "$stage" && zip -0qry -X packaged.ipa Payload)
mkdir -p "$(dirname "$target_ipa")"
mv "$stage/packaged.ipa" "$target_ipa"
python3 scripts/check-ipa.py "$target_ipa"
(cd "$(dirname "$target_ipa")" && shasum -a 256 "$(basename "$target_ipa")" > "$(basename "$target_ipa").sha256")
echo "Created $target_ipa; re-sign before installing on another device."
