# Source release notes

[简体中文](SOURCE-RELEASE.md) | English

From November 24, 2026, this repository publishes **all the code** of Meowverse 1.0, submitted for App Store review on November 24, 2026: the app itself, the widgets and Live Activity, the Control Center controls, the cat download extension, the MeowverseCore library, the unit and interface tests, the Xcode project and the build scripts. The license is unchanged: PolyForm Noncommercial 1.0.0. **The art is not published.** This release replaces the plan of November 14, 2026, which published the core library only.

## Version and scope

<!-- export-facts:begin -->
| Item | Value |
| --- | --- |
| Source commit | `2f9d0415a2a0244ee689cac77a7e8bc8e8f5706e` (2026-11-24) |
| App version | 1.0 (14), iOS 26.0 or later |
| Library schema | 12 |
| App target | 244 files |
| Widgets, Live Activity, Control Center and the cat download extension | 53 |
| MeowverseCore and its tests | 246 |
| UI tests | 80 |
| Xcode project and build settings | 13 |
| Build and test scripts | 14 |
| Tools (recognition evaluation, DINOv2 conversion) | 22 |
| Technical documents | 10 |
| Added for the release (placeholder art script, core test script) | 2 |
| Art and resource files not published | 650 |
<!-- export-facts:end -->

The export script generates the numbers in this table from the source commit; the SHA-256 of every file is in [SOURCE-MANIFEST.json](SOURCE-MANIFEST.json) for checking one by one.

| Folder | Contents |
| --- | --- |
| `ios/Meowverse/` | Swift sources of the app target, interface text (`.xcstrings`) and privacy manifest; the asset catalogs keep only `Contents.json` and colors |
| `ios/PocketCatShared/`, `ios/PocketCatWidget/` | The pixel cat widgets, Live Activity, Control Center controls and the code they share with the app |
| `ios/MeowverseAssets/` | The download extension for the cats' low and high tier models (Background Assets) |
| `ios/MeowverseCore/` | The core library, its tests, the program data they need and a synthetic backup |
| `ios/MeowverseUITests/` | Interface tests |
| `ios/Meowverse.xcodeproj/`, `ios/*.xcconfig`, `ios/*.entitlements`, `ios/*-Info.plist` | Project, schemes, test plan, build settings, entitlements and Info.plists |
| `ios/*.sh`, `ios/*.py` | Build, test, recording and localization check scripts |
| `ios/Tools/` | The furniture recognition evaluation tool, the DINOv2 to Core ML conversion and the placeholder art script |
| Technical documents in `docs/` | iCloud sync, the cat pack format, the photo library model, the onboarding tour, rendering and quality tiers, voice control, sources of the cat facts |

Voice control (Talk to Bella) is hidden in 1.0 and left out at compile time; its source is published with this release, and `ios/Config.xcconfig` describes how to turn it on.

The sponsors on the About page, in News and on the cat cards appear under the nicknames they gave (Omucat, Yoko, Chuibao, Xin, Cornelius); a cat without one reads “<cat’s name>’s human”.

## What is not included

- **Art**: cat and furniture models and meshes, textures, room themes, illustrations, app icons, pixel cat images, Control Center symbols, sounds, fonts, Blender sources and the art pipeline. They are the work of the project and its collaborators, and some of them are used under third-party licenses; the art is not licensed with the code and is not suited to redistribution under the code license. See Meowverse on the App Store for the finished look.
- **DINOv2 model weights** (a Core ML file of about 86 MB): convert them from the upstream model with `ios/Tools/EmbeddingLab`. Without them the app makes furniture suggestions with the system's Vision framework.
- The frozen web demo, private material, internal documents (status, plans, review records, marketing, team setup) and the recognition evaluation records made on the maintainer's own photos.
- In-app purchase code. Meowverse 1.0 is entirely free; purchases never entered the 1.0 code.

Some documents named in code comments (such as the release process, the tour script and the art pipeline notes) are internal and are not part of this release.

## Differences from the development repository

- `ios/simulator-id.sh`: in the development repository its default is one simulator on the maintainer's Mac; the public copy takes the first available iPhone simulator instead. Every other file has the same bytes as in the source commit.
- Added: `ios/Tools/make-placeholder-art.py` (placeholder images), `ios/test-core.sh` (runs the core tests), `SOURCE-MANIFEST.json`, and a block in `.gitignore` that ignores the placeholder images.

## How to build

You need macOS, Xcode 27 and the iOS 26 SDK. There are no external Swift Package dependencies and no model keys to configure.

```sh
python3 ios/Tools/make-placeholder-art.py   # optional: grey placeholders for the asset catalogs
xcodebuild -project ios/Meowverse.xcodeproj -scheme Meowverse \
  -destination 'generic/platform=iOS Simulator' build
ios/test-core.sh                            # core library tests
```

The project builds without the placeholders too; Xcode then warns once for every missing image. With them, the app icon and illustrations are grey squares and the Control Center symbols are grey dots. Furniture, cats, room themes, sounds and fonts are read at run time; without the art those places stay empty, and the room does not look like the released app.

To install on a device you need your own developer team: put `DEVELOPMENT_TEAM = <your Team ID>` in `ios/Local.xcconfig` (not tracked by git) and change `MEOWVERSE_BUNDLE_ID` to your own identifier. The entitlements files name this project's App Group and iCloud container; change them to ones you registered.

`ios/test-core.sh` skips 10 tests that read art files or the web pages (each is listed in the script), rather than letting them fail or pass without checking anything when the files are missing.

## Test results

<!-- updated by the lead after rerunning on the final commit -->
On the export of the source commit (Xcode 27.2, macOS 26.7.2):

- Simulator build (`generic/platform=iOS Simulator`, Debug): passes, with and without the placeholders.
- `ios/test-core.sh`: of 1,262 tests, 4 timing tests fail in a parallel run on a busy machine and pass when rerun alone; with `--no-parallel` all pass.

These results only show that the published code builds and that the core tests pass. They do not stand for the released app's look, on-device performance or system permission acceptance.

## Images and license

The Chinese and English screenshots in the README are finished screens kept separately to present the project; the photos in them are synthetic samples. Sources, timing and third-party attribution are in the [image notes](docs/media/ATTRIBUTION.md). They are not screens produced by running the code in this repository, and no production art source assets are provided.

The code, build manifests, required program data and synthetic test material are under the [LICENSE](LICENSE). The finished promotional screenshots, documentation such as the README and the group QR code are not licensed as reusable material with the code; see [LICENSE-SCOPE.en.md](LICENSE-SCOPE.en.md). The license uses the unmodified official English text, and no interpretation may widen or narrow the rights in that text.

This release does not revoke any rights already validly granted for an earlier version.

The official source repository is [Fengyee/meowverse-core](https://github.com/Fengyee/meowverse-core). The QQ group is **<span lang="zh-Hans">Meowverse/喵空间</span>**, group number **1132819295**; the group QR code is shown [lower in the README](README.en.md#community). Testing, feedback and joining the group are free.
