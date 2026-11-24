#!/bin/zsh
# Cold-launches an optimized build on the device under Instruments and prints signposts and hangs.
# Usage: ./measure-launch.sh <device-udid>
cd "$(dirname "$0")"; D=$1
xcodebuild -project Meowverse.xcodeproj -scheme Meowverse -destination "platform=iOS,id=$D" -derivedDataPath build/DerivedData -allowProvisioningUpdates -configuration Release build 2>&1 | rg "error:|\*\* BUILD" | head -5
xcrun devicectl device install app --device $D build/DerivedData/Build/Products/Release-iphoneos/Meowverse.app 2>&1 | rg -i "error" 
rm -rf build/launch-poi.trace
xcrun xctrace record --instrument 'Points of Interest' --instrument 'Hangs' --device $D --time-limit 10s --output build/launch-poi.trace --launch -- io.github.fengyee.meowverse ${=EXTRA:-} > build/xctrace.log 2>&1
./trace-dump.py build/launch-poi.trace OSSignpostIntervals Meowverse | rg -v "com.apple" | cut -c1-60
./trace-dump.py build/launch-poi.trace PointsOfInterestEvents footprint | cut -c1-14,95-190
./trace-dump.py build/launch-poi.trace potential-hangs Meowverse | cut -c1-60
