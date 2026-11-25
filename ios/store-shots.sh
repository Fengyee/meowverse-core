#!/bin/zsh
# Draft App Store screenshots (6.9-inch, 1320x2868) in Chinese and English.
# Usage: ./store-shots.sh [simulator-udid]   (choose a 1320x2868 simulator)
# Writes ../docs/store-shots/{zh-Hans,en-US}/<n>-<name>.png; "alt-" files are alternates.
#
# All or nothing (audit 2026-11-24, E24-05): the shots are collected in a fresh folder, and only
# when the test run passed and every shot the test takes is there, in both languages, at
# 1320x2868, does that folder replace docs/store-shots (with RUN.txt saying which commit made
# it). On any failure docs/store-shots is left as the last complete run and the script exits 1.
setopt err_exit pipe_fail no_unset
cd "${0:A:h}"
sim=${1:-${MEOWVERSE_SHOTS_SIM:-$(zsh ./simulator-id.sh --store-shots)}}
[[ -z $sim ]] && { echo "no iPhone 18 Pro Max simulator; pass a udid"; exit 1; }
out=../docs/store-shots
fail() { print -r -- "FAIL store shots: $1"; [[ -f $out/RUN.txt ]] && print -r -- "$out still holds the earlier run: $(head -1 $out/RUN.txt)"; exit 1; }

# The shots the test takes, from its source; each language must have exactly these.
expected=(${(f)"$(rg -o --no-filename 'snap\(language, "([^"]+)"\)' -r '$1' MeowverseUITests/StoreScreenshotsUITests.swift | sort -u || true)"})
(( ${#expected} > 0 )) || fail "no snap(...) names found in StoreScreenshotsUITests.swift"

xcrun simctl boot "$sim" 2>/dev/null || true
xcrun simctl bootstatus "$sim" -b >/dev/null
tmp=$(mktemp -d)
xcrun simctl io "$sim" screenshot "$tmp/size.png" >/dev/null || fail "could not take a screenshot on $sim"
dimensions=$(sips -g pixelWidth -g pixelHeight "$tmp/size.png" | awk '/pixel/{print $2}' | paste -sd x -)
[[ $dimensions == 1320x2868 ]] || fail "selected simulator is ${dimensions}; pass the UDID of a 1320x2868 simulator."
xcrun simctl status_bar "$sim" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
rm -rf build/store-shots.xcresult
mkdir -p build
xc=0
TEST_RUNNER_MEOWVERSE_STORE_SHOTS=1 xcodebuild -project Meowverse.xcodeproj -scheme Meowverse \
  -destination "platform=iOS Simulator,id=$sim" -derivedDataPath build/DerivedData \
  -resultBundlePath build/store-shots.xcresult -only-testing:MeowverseUITests/StoreScreenshotsUITests test \
  > build/store-shots.log 2>&1 || xc=$?
{ rg "error:|Executed|\*\* TEST" build/store-shots.log || true; } | rg -v '^\s+\|' | cut -c1-600 | sort -u
(( xc == 0 )) || fail "xcodebuild exited $xc (log: ios/build/store-shots.log)"

xcrun xcresulttool export attachments --path build/store-shots.xcresult --output-path "$tmp/attachments" >/dev/null 2>&1 \
  || fail "could not export the attachments"
# Beside the destination's volume (ios/build is ignored), so promoting the set is a rename.
stage=build/store-shots-stage previous=build/store-shots-previous
rm -rf "$stage" "$previous"
mkdir -p "$stage/zh-Hans" "$stage/en-US"
jq -r '.[].attachments[] | select(.suggestedHumanReadableName|test("^(zh-Hans|en-US)-")) | "\(.exportedFileName)\t\(.suggestedHumanReadableName)"' "$tmp/attachments/manifest.json" \
  > "$tmp/list.tsv" || fail "the attachment manifest is unreadable"
while IFS=$'\t' read -r f n; do
  n=${n%%_*}; lang=${n%%-[0-9a]*}; name=${n#$lang-}
  cp "$tmp/attachments/$f" "$stage/$lang/$name.png"
done < "$tmp/list.tsv"

problems=()
for lang in zh-Hans en-US; do
  for name in $expected; do
    f="$stage/$lang/$name.png"
    if [[ ! -f $f ]]; then problems+=("$lang/$name.png missing"); continue; fi
    size=$(sips -g pixelWidth -g pixelHeight "$f" | awk '/pixel/{print $2}' | paste -sd x -)
    [[ $size == 1320x2868 ]] || problems+=("$lang/$name.png is $size")
  done
  for f in "$stage/$lang"/*.png(N); do
    (( ${expected[(Ie)${f:t:r}]} )) || problems+=("$lang/${f:t} is not a shot the test takes")
  done
done
if (( ${#problems} )); then print -rl -- $problems; fail "${#problems} problem(s) with the new shots"; fi

print -r -- "commit $(git rev-parse --short HEAD 2>/dev/null || echo unknown)$(git diff --quiet HEAD 2>/dev/null || echo ' (with uncommitted changes)'), $(date -u +%Y-%m-%dT%H:%MZ), ${#expected} shots per language" > "$stage/RUN.txt"
mkdir -p "${out:h}"
if [[ -e $out ]]; then mv "$out" "$previous"; fi
mv "$stage" "$out" || { [[ -e $previous ]] && mv "$previous" "$out"; fail "could not move the new shots into place"; }
rm -rf "$tmp" "$previous"
for f in $out/{zh-Hans,en-US}/*.png; do echo "$f $(sips -g pixelWidth -g pixelHeight $f | awk '/pixel/{printf "%s ", $2}')"; done
print -r -- "PASS store shots: $(head -1 $out/RUN.txt)"
