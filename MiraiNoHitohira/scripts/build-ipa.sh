#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
project_root="$PWD"
build_folder="$(mktemp -d)"
trap 'rm -rf "$build_folder"' EXIT

xcodebuild   -project MiraiNoHitohira.xcodeproj   -scheme MiraiNoHitohira   -configuration Release   -destination 'generic/platform=iOS'   -derivedDataPath "$build_folder/DerivedData"   CODE_SIGNING_ALLOWED=NO   CODE_SIGNING_REQUIRED=NO   build

app="$build_folder/DerivedData/Build/Products/Release-iphoneos/MiraiNoHitohira.app"
test -x "$app/MiraiNoHitohira"
for file in Info.plist scenes.json scene0.jpg scene7.jpg Key.wav Saved.wav Dawn.wav; do
  test -s "$app/$file"
done

mkdir -p "$build_folder/Payload" "$project_root/dist"
ditto "$app" "$build_folder/Payload/MiraiNoHitohira.app"
output="$project_root/dist/MiraiNoHitohira.ipa"
rm -f "$output"
(cd "$build_folder" && /usr/bin/zip -qry "$output" Payload)
unzip -tq "$output"
ls -lh "$output"
