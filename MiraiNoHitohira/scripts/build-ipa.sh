#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
project_root="$PWD"
build_folder="$(mktemp -d)"
trap 'rm -rf "$build_folder"' EXIT

cat "$project_root/App/Scene.swift" "$project_root/scripts/check-typing.swift" \
  | xcrun swift - "$project_root/App/Resources/scenes.json"

xcodebuild \
  -project MiraiNoHitohira.xcodeproj \
  -scheme MiraiNoHitohira \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$build_folder/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

app="$build_folder/DerivedData/Build/Products/Release-iphoneos/MiraiNoHitohira.app"
test -x "$app/MiraiNoHitohira"
for file in Info.plist scenes.json scene0.jpg scene7.jpg Key.wav Saved.wav Flight.wav Dawn.wav KleeOne-Regular.ttf KleeOne-SemiBold.ttf KleeOne-OFL.txt ja.lproj/InfoPlist.strings \
    Ambience/Leaves.m4a Ambience/Sparrow.m4a Ambience/Warbler.m4a Ambience/Tit.m4a Ambience/Dove.m4a Ambience/Credits.txt Motion/scene25.mp4 Motion/scene26.mp4; do
  test -s "$app/$file"
done

test "$(plutil -extract CFBundleDisplayName raw "$app/Info.plist")" = "MiraiNoHitohira"
test "$(plutil -extract CFBundleDisplayName raw "$app/ja.lproj/InfoPlist.strings")" = "未来の一片"

python3 - "$app" <<'PYTHON'
import json
import pathlib
import sys

app = pathlib.Path(sys.argv[1])
entries = json.loads((app / "scenes.json").read_text())["entries"]
images = {entry["image"] for entry in entries}
if len(entries) != 29 or images != set(range(8, 37)):
    raise SystemExit("Expected 29 distinct daily illustrations")
for index in images:
    image = app / "Memories" / f"scene{index}.jpg"
    if not image.is_file() or not image.stat().st_size:
        raise SystemExit(f"Missing bundled illustration: {image.name}")
PYTHON

mkdir -p "$build_folder/Payload" "$project_root/dist"
ditto "$app" "$build_folder/Payload/MiraiNoHitohira.app"
output="$project_root/dist/MiraiNoHitohira.ipa"
rm -f "$output"
(cd "$build_folder" && /usr/bin/zip -qry "$output" Payload)
unzip -tq "$output"
ls -lh "$output"
