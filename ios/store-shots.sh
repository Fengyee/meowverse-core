#!/bin/zsh
# Draft App Store screenshots (6.9-inch, 1320x2868) in Chinese and English.
# Usage: ./store-shots.sh [simulator-udid]   (choose a 1320x2868 simulator)
# Writes ../docs/store-shots/{zh-Hans,en-US}/<n>-<name>.png; "alt-" files are alternates.
cd "$(dirname "$0")"
sim=${1:-${MEOWVERSE_SHOTS_SIM:-$(zsh ./simulator-id.sh --store-shots)}}
[[ -z $sim ]] && { echo "no iPhone 18 Pro Max simulator; pass a udid"; exit 1; }
xcrun simctl boot "$sim" 2>/dev/null; xcrun simctl bootstatus "$sim" -b >/dev/null
tmp=$(mktemp -d)
xcrun simctl io "$sim" screenshot "$tmp/size.png" >/dev/null || exit 1
dimensions=$(sips -g pixelWidth -g pixelHeight "$tmp/size.png" | awk '/pixel/{print $2}' | paste -sd x -)
[[ $dimensions == 1320x2868 ]] || { echo "Selected simulator is ${dimensions}; pass the UDID of a 1320x2868 simulator."; exit 1; }
xcrun simctl status_bar "$sim" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
rm -rf build/store-shots.xcresult
TEST_RUNNER_MEOWVERSE_STORE_SHOTS=1 xcodebuild -project Meowverse.xcodeproj -scheme Meowverse \
  -destination "platform=iOS Simulator,id=$sim" -derivedDataPath build/DerivedData \
  -resultBundlePath build/store-shots.xcresult -only-testing:MeowverseUITests/StoreScreenshotsUITests test 2>&1 \
  | rg "error:|Executed|\*\* TEST" | rg -v '^\s+\|' | cut -c1-600 | sort -u
xcrun xcresulttool export attachments --path build/store-shots.xcresult --output-path "$tmp" >/dev/null 2>&1
jq -r '.[].attachments[] | select(.suggestedHumanReadableName|test("^(zh-Hans|en-US)-")) | "\(.exportedFileName)\t\(.suggestedHumanReadableName)"' "$tmp/manifest.json" | while IFS=$'\t' read f n; do
  n=${n%%_*}; lang=${n%%-[0-9a]*}; name=${n#$lang-}
  mkdir -p ../docs/store-shots/$lang && cp "$tmp/$f" "../docs/store-shots/$lang/$name.png"
done
for f in ../docs/store-shots/{zh-Hans,en-US}/*.png; do echo "$f $(sips -g pixelWidth -g pixelHeight $f | awk '/pixel/{printf "%s ", $2}')"; done
