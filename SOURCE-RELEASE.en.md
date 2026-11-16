# Core source release notes

[简体中文](SOURCE-RELEASE.md) | English

This package follows the plan confirmed on 2026-11-14: the latest MeowverseCore core source is public under PolyForm Noncommercial 1.0.0, while the production app interface, rendering, art and design source files stay private.

## Version and scope

- Source main: `0084971a5fa8a834738920aa320c7f8d4081bb12`, matching the current 0.1.0 (3) development line, library schema 11.
- Swift package: 28 library Swift files, 31 test Swift files and Package.swift, with the required catalog JSON, a synthetic backup ZIP and verification manifests.
- The included JSON contains program data such as stable IDs, furniture categories, footprints and interaction coordinates; it contains no production meshes, textures or animation resources.
- It does not include the SwiftUI app target, the Live Activity extension, the production renderer or the full app build project. Running the core tests does not launch an app with the room view; use TestFlight for the full experience.

## Differences from the original development directory

Only the `bundledBella` integration test, which depends on production Bella assets outside the package, was removed from the exported copy of `CatPackTests.swift`. That test returns early when the assets are missing; keeping it would count an asset check that never ran as a pass. All other core source and tests keep the bytes of the source version.

The original development line declares 345 core tests; this package declares and actually runs **344 tests in 44 suites, all passing**. This does not stand for the production app's interface tests or on-device performance acceptance.

## Images and license

The Chinese and English screenshots in the README (three each) are real development-build screens kept separately to present the project. They were captured on 2026-11-15, after build 3, and the photos in them are synthetic samples. Sources, timing and third-party attribution are in the [image notes](docs/media/ATTRIBUTION.md). They are not screens produced by running this Swift library, and no production art source assets are provided.

The code, build manifests, required program data and synthetic test material are under the [LICENSE](LICENSE). The finished promotional screenshots, documentation such as the README, the group QR code and the payment codes are not licensed as reusable material with the code; see [LICENSE-SCOPE.en.md](LICENSE-SCOPE.en.md). The license uses the unmodified official English text, and no interpretation may widen or narrow the rights in that text.

This release uses the core library scope listed in this file and the PolyForm Noncommercial license. It does not include the interface or replacement art from the earlier community-edition draft, and it does not revoke any rights already validly granted for an earlier version.

The official source repository is [Fengyee/meowverse-core](https://github.com/Fengyee/meowverse-core). The full product is available through [TestFlight](https://testflight.apple.com/join/WCuPQFsm). The QQ group is **<span lang="zh-Hans">Meowverse/猫宇宙</span>**, group number **1132819295**; the group QR code is shown [lower in the README](README.en.md#community), and the ways to tip are in [SUPPORT.en.md](SUPPORT.en.md). Testing, feedback and joining the group do not require a tip.
