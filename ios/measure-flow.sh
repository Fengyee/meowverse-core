#!/bin/zsh
# Records one Instruments trace of the whole photo -> sofa -> original flow on a device,
# using an optimized build with the drill switches (synthetic photo, separate test store).
# Instruments launches the app; a UI test attaches to it and drives the flow.
# Usage: ./measure-flow.sh <device-udid>
cd "$(dirname "$0")"; D=$1
X=(-project Meowverse.xcodeproj -scheme Meowverse -destination "platform=iOS,id=$D" -derivedDataPath build/DerivedData
   -allowProvisioningUpdates -configuration Release 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DRILLS' ENABLE_TESTABILITY=NO)
xcodebuild "${X[@]}" build-for-testing 2>&1 | rg "error:|\*\* TEST BUILD" | head -5
xcrun devicectl device install app --device $D build/DerivedData/Build/Products/Release-iphoneos/Meowverse.app 2>&1 | rg -i "error"
[[ -e build/flow.trace ]] && mv build/flow.trace "build/flow-old-$(date +%s).trace"
[[ -e build/ui.xcresult ]] && mv build/ui.xcresult "build/ui-old-$(date +%s).xcresult"
TEST_RUNNER_MEOWVERSE_ATTACH=1 xcodebuild "${X[@]}" -resultBundlePath build/ui.xcresult \
  -only-testing:MeowverseUITests/PhotoToFurnitureUITests/testProfilingWalkOnRunningApp test-without-building > build/flow-test.log 2>&1 &
# Wait until the test is running (the app is installed by then), then launch under Instruments.
for i in {1..90}; do rg -q "testProfilingWalkOnRunningApp\]' started" build/flow-test.log && break; sleep 1; done
xcrun xctrace record --instrument 'Points of Interest' --instrument 'Hangs' --device $D --time-limit 60s --output build/flow.trace \
  --launch -- io.github.fengyee.meowverse -MeowverseStore profile -MeowverseResetStore -MeowverseSyntheticPhoto > build/xctrace.log 2>&1
wait
rg "Executed|\*\* TEST" build/flow-test.log | head -2
echo "== intervals"; ./trace-dump.py build/flow.trace OSSignpostIntervals Meowverse | rg -v "com.apple" | cut -c1-60
echo "== footprint"; ./trace-dump.py build/flow.trace PointsOfInterestEvents footprint | cut -c1-14,95-190
echo "== hangs"; ./trace-dump.py build/flow.trace potential-hangs Meowverse | rg -v Runner | cut -c1-60
