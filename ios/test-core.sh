#!/bin/zsh
# Runs the MeowverseCore tests of this public source release.
#
#   ios/test-core.sh                 # every test that can run without the art
#   ios/test-core.sh --no-parallel   # extra arguments go to `swift test`
#
# The release has no art, and the published repository has no web pages, so the tests below read
# files that are not here. They are skipped by name rather than left to fail, or to pass without
# checking anything (the three Bella tests return early when her files are missing):
#   bundledBella, bundledBellaManifest   the built-in Bella pack under ios/Meowverse/Resources/Art
#   bundledCats                          every built-in cat's low tier, same folder
#   everySoundHasItsRuntimeFile          the room sounds under ios/Meowverse/Resources/Sounds
#   theBundledFontsCoverage              the title font under ios/Meowverse/Resources/Fonts
#   theTitleFaceDrawsTheChineseName      the same font, for the postcard letterhead
#   iconNamesMatchTheAssetCatalog        the app icon images in Assets.xcassets
#   everyNoticeIsBackedByAShippedFile    the third-party notices next to the art
#   everySourceSiteInTheAttributionHasARow  the art's ATTRIBUTION.txt
#   thePrivacyPolicyHasBothSections      the web privacy page (public/privacy.html)
# Four timing tests (BatchSuggestionTests, PhotoRequestTests, LoadWatchdogTests) can fail on a
# busy machine in a parallel run; they pass alone or with --no-parallel.
set -eu
cd "${0:A:h}/MeowverseCore"
skip='bundledBella|bundledCats|everySoundHasItsRuntimeFile|theBundledFontsCoverage|theTitleFaceDrawsTheChineseName|iconNamesMatchTheAssetCatalog|everyNoticeIsBackedByAShippedFile|everySourceSiteInTheAttributionHasARow|thePrivacyPolicyHasBothSections'
exec swift test --skip "$skip" "$@"
