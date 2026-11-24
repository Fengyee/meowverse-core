# License scope for the source and presentation materials

[简体中文](LICENSE-SCOPE.md) | English

This is an English translation of [LICENSE-SCOPE.md](LICENSE-SCOPE.md).

This repository provides the **source-available code of all of Meowverse 1.0**: the app, its extensions, the MeowverseCore core library, the tests, the Xcode project and the build scripts, under the [PolyForm Noncommercial License 1.0.0](LICENSE). The license limits use to noncommercial purposes, so this release is not called a standard open-source release. The full terms are in [LICENSE](LICENSE), and the required notice is in [NOTICE](NOTICE).

You may use, modify and redistribute the covered software for the permitted purposes defined in the license. When redistributing, provide the terms or their web address as the license requires, and keep any applicable `Required Notice:` statement. Commercial use requires a separate license; contact [bella.meowverse@gmail.com](mailto:bella.meowverse@gmail.com). This page describes scope; it does not modify the [official license text](https://polyformproject.org/licenses/noncommercial/1.0.0).

| Scope | What applies |
| --- | --- |
| Swift sources and tests under `ios/`: `Meowverse/` (app), `PocketCatShared/`, `PocketCatWidget/`, `MeowverseAssets/` (extensions), `MeowverseCore/` (core library and tests), `MeowverseUITests/` (interface tests), `Tools/` | PolyForm Noncommercial License 1.0.0 |
| Interface text catalogs (`.xcstrings`), privacy manifests, Info.plists, entitlements, and the `Contents.json` files and colors in the asset catalogs | PolyForm Noncommercial License 1.0.0 |
| The Xcode project, schemes, test plan, `.xcconfig` files, `Package.swift`, and the build and test scripts under `ios/` | PolyForm Noncommercial License 1.0.0 |
| `ios/README.md` and the technical documents in `docs/` released with the code (listed in [SOURCE-RELEASE.en.md](SOURCE-RELEASE.en.md)) | Provided as software documentation, under the same PolyForm Noncommercial License |
| Catalog JSON, schemas, stable IDs, footprints, interaction coordinates and verification manifests required by the program | Provided as program data required by the software, under the same PolyForm Noncommercial License; third-party source fields in the catalogs do not change the original rights of those third parties |
| The test files `web-v6-synthetic.zip` and `inspect-fixture.usdz` and the programmatically drawn content inside them | Provided as software test data, under the same PolyForm Noncommercial License; contains no private photos |
| Third-party attribution and license notes in the code (the About page's credits data) | Record the sources and licenses of third-party works; they do not change those third parties' rights and do not mean that those works are provided in this repository |
| Finished screenshots in `docs/media/` | For presenting this project only; the corresponding rights are reserved and they are not provided as reusable art assets. Third-party elements in them remain subject to their original rights and attribution notices |
| User instructions, prompts and download packages in `docs/cat-creation/` | For users to download, copy and use as described in the cat reference guide. They are not a release of the app's production art or production project files and are not automatically covered by the code license. The source, permitted uses and third-party rights of each item are in that directory's [ATTRIBUTION.md](docs/cat-creation/ATTRIBUTION.md) |
| The Fripouille-derived templates in `docs/cat-creation/POSE_GUIDE.png` and `docs/cat-creation/guides/` | guillaume bolis keeps the attribution for the original work and the applicable CC BY 4.0 rights; the repository's noncommercial code license does not replace or restrict the third-party license; no source model files are included |
| `docs/cat-creation/cat-creation-flow-bella.png`, `cat-creation-flow-bella-en.png` | The Chinese and English AI-generated finished posters for this workflow, only for presenting and sharing the workflow within this project; they are not app screenshots, and Bella's production art source assets are not released as reusable |
| Generated reference images that users upload in Issues | Not automatically included in the code or template license, and not automatically licensed for the built-in cat library, training or asset releases; the scope of a submission and any later use are confirmed separately |
| The QQ group QR code image in `support/` | Only for this project's free community entry; the corresponding rights are reserved and the source license does not apply. Third-party marks in them remain subject to their original rights |
| `README.md`, `README.en.md`, `SUPPORT.md`, this file, `.github/ISSUE_TEMPLATE/` and other project documentation | Project documentation; the corresponding rights are reserved and it is not licensed as reusable material together with the program source |
| `LICENSE`, `NOTICE` and applicable third-party licenses and attribution notices | May be copied with the corresponding work to meet license conditions; this does not change the license terms |

This repository provides no art: no cat or furniture models, meshes, textures, room themes, illustrations, app icons, pixel cat images, Control Center symbols, sounds, fonts, animations or design source files such as Blender files, and no DINOv2 model weights or private original photos. The grey placeholders written by `ios/Tools/make-placeholder-art.py` only let the project build quietly; they are not project art. The promotional screenshots show only the finished interface; they do not mean that the art shown is released with the code.

Catalog entries and resource-loading code in the source may reference the stable IDs, file names or sources of production resources. These identifiers are part of the program and data compatibility interface; they are not copies of the resource files and grant no license to the corresponding source models, textures or design files.

The project name is used only to indicate the source. The source license grants no separate right to use the trademark or brand graphics.

Existing third-party licenses and rights granted by law remain unchanged. This file does not turn them into rights owned by the project, and does not withdraw rights already granted by other versions. The code baseline and extraction scope for this release are in [SOURCE-RELEASE.en.md](SOURCE-RELEASE.en.md).
