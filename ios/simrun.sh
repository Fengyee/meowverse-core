#!/bin/zsh
# Reinstall the built app on the selected simulator and capture a screenshot.
set -eu
simulator=$(zsh "${0:A:h}/simulator-id.sh")
out=${1:?usage: simrun.sh screenshot-path [app arguments]}
shift
app="${0:A:h}"/build/DerivedData/Build/Products/Debug-iphonesimulator/Meowverse.app
zsh "${0:A:h}/build.sh" sim
bundle_id=$(plutil -extract CFBundleIdentifier raw -- "$app/Info.plist")
xcrun simctl terminate "$simulator" "$bundle_id" >/dev/null 2>&1 || true
xcrun simctl install "$simulator" "$app"
xcrun simctl launch "$simulator" "$bundle_id" "$@" >/dev/null
sleep "${WAIT:-5}"
xcrun simctl io "$simulator" screenshot "$out" >/dev/null
sips -Z 1100 "$out" >/dev/null
