#!/bin/zsh
# Export named screenshots from the last UI test run into $1.
cd "$(dirname "$0")"; out=$1; tmp=$(mktemp -d)
xcrun xcresulttool export attachments --path build/ui.xcresult --output-path $tmp >/dev/null 2>&1
mkdir -p $out
jq -r '.[].attachments[] | select(.suggestedHumanReadableName|test("^[0-9]-")) | "\(.exportedFileName)\t\(.suggestedHumanReadableName)"' $tmp/manifest.json | while IFS=$'\t' read f n; do cp "$tmp/$f" "$out/${n%%_*}.png"; done
ls $out
