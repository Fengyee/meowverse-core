#!/bin/zsh
# Runs the UI tests on the simulator (default) or a device id passed as $1.
cd "$(dirname "$0")"
dest="platform=iOS Simulator,id=$(zsh ./simulator-id.sh)"
[[ -n "${1:-}" ]] && dest="platform=iOS,id=$1"
rm -rf build/ui.xcresult
xcodebuild -project Meowverse.xcodeproj -scheme Meowverse -destination "$dest" -derivedDataPath build/DerivedData -resultBundlePath build/ui.xcresult -allowProvisioningUpdates test 2>&1 | rg "error:|Test Case|Executed|\*\* TEST" | rg -v '^\s+\|' | cut -c1-500
