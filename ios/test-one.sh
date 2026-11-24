#!/bin/zsh
# ./test-one.sh <testMethodName> [device-id]
cd "$(dirname "$0")"
dest="platform=iOS Simulator,id=$(zsh ./simulator-id.sh)"
[[ -n "${2:-}" ]] && dest="platform=iOS,id=$2"
rm -rf build/ui.xcresult
xcodebuild -project Meowverse.xcodeproj -scheme Meowverse -destination "$dest" -derivedDataPath build/DerivedData -resultBundlePath build/ui.xcresult -allowProvisioningUpdates "-only-testing:MeowverseUITests/PhotoToFurnitureUITests/$1" test 2>&1 | rg "error:|Executed|\*\* TEST" | rg -v '^\s+\|' | cut -c1-1800 | sort -u
