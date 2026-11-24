#!/bin/zsh
# Records the sponsor demo: a paced UI test walks photo -> sofa -> original -> relaunch -> original
# with the drawn synthetic photo, and the test plan keeps the screen recording.
# Usage: ./record-demo.sh <device-udid> <output.mp4>     (omit the udid argument value "sim" for the simulator)
cd "$(dirname "$0")"; out=${2:?output path}
dest="platform=iOS,id=$1"; [[ $1 == sim ]] && dest="platform=iOS Simulator,id=$(zsh ./simulator-id.sh)"
[[ -e build/demo.xcresult ]] && mv build/demo.xcresult "build/demo-old-$(date +%s).xcresult"
TEST_RUNNER_MEOWVERSE_DEMO=1 xcodebuild -project Meowverse.xcodeproj -scheme MeowverseDemo -destination "$dest" \
  -derivedDataPath build/DerivedData -resultBundlePath build/demo.xcresult -allowProvisioningUpdates \
  -only-testing:MeowverseUITests/PhotoToFurnitureUITests/testDemoWalkthrough test 2>&1 | rg "error:|Executed|\*\* TEST" | sort -u | cut -c1-600
tmp=$(mktemp -d)
xcrun xcresulttool export attachments --path build/demo.xcresult --output-path "$tmp" >/dev/null 2>&1
jq -r '.[].attachments[] | "\(.exportedFileName)\t\(.suggestedHumanReadableName)"' "$tmp/manifest.json"
video=$(jq -r '[.[].attachments[] | select(.exportedFileName|test("\\.(mp4|mov)$"))][0].exportedFileName // empty' "$tmp/manifest.json")
[[ -n $video ]] && cp "$tmp/$video" "$out" && ls -la "$out"
