#!/bin/zsh
# Usage: ./build.sh sim|device [extra xcodebuild args]
set -euo pipefail
cd "$(dirname "$0")"
SIM_ID=$(zsh ./simulator-id.sh)
case "${1:-sim}" in
  sim) dest=(-destination "platform=iOS Simulator,id=$SIM_ID" -configuration Debug) ;;
  device) dest=(-destination "generic/platform=iOS" -configuration "${CONFIG:-Release}" -allowProvisioningUpdates) ;;
esac
shift || true
# The older way to build iCloud sync, the compilation condition alone, gets the build setting
# that also signs the app for push (Config.xcconfig): the same build either way.
for arg in "$@"; do
  [[ "$arg" == SWIFT_ACTIVE_COMPILATION_CONDITIONS=*MEOWVERSE_ICLOUD_SYNC* ]] && { set -- "$@" MEOWVERSE_ICLOUD_SYNC=YES; break; }
done
xcodebuild -project Meowverse.xcodeproj -scheme Meowverse "${dest[@]}" -derivedDataPath build/DerivedData "$@" build 2>&1 | rg "error:|warning: unre|BUILD|xcodebuild: error" | rg -v '^\s+\|' | sort -u | cut -c1-400

# SwiftPM resource bundles can go stale in incremental builds; a missing catalog stops the app at launch.
case "${dest[4]}" in Debug) sdk=iphonesimulator ;; *) sdk=iphoneos ;; esac
[[ "${dest[2]}" == generic/* ]] && sdk=iphoneos
bundle="build/DerivedData/Build/Products/${dest[4]}-$sdk/Meowverse.app/MeowverseCore_MeowverseCore.bundle"
for f in MeowverseCore/Sources/MeowverseCore/Resources/*; do
  cmp -s "$f" "$bundle/${f:t}" || { echo "error: stale resource in app bundle: ${f:t} (delete build/DerivedData and rebuild)"; exit 1; }
done
