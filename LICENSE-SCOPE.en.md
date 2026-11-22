# License scope for the source and presentation materials

[简体中文](LICENSE-SCOPE.md) | English

This is an English translation of [LICENSE-SCOPE.md](LICENSE-SCOPE.md).

This release provides the **source-available code of the MeowverseCore core library** under the [PolyForm Noncommercial License 1.0.0](LICENSE). The license limits use to noncommercial purposes, so this release is not called a standard open-source release. The full terms are in [LICENSE](LICENSE), and the required notice is in [NOTICE](NOTICE).

You may use, modify and redistribute the covered software for the permitted purposes defined in the license. When redistributing, provide the terms or their web address as the license requires, and keep any applicable `Required Notice:` statement. Commercial use requires a separate license; contact [bella.meowverse@gmail.com](mailto:bella.meowverse@gmail.com). This page describes scope; it does not modify the [official license text](https://polyformproject.org/licenses/noncommercial/1.0.0).

| Scope | What applies |
| --- | --- |
| Swift core program in `ios/MeowverseCore/Sources/` | PolyForm Noncommercial License 1.0.0 |
| Swift test program and `Package.swift` in `ios/MeowverseCore/Tests/` | PolyForm Noncommercial License 1.0.0 |
| Catalog JSON, schemas, stable IDs, footprints, interaction coordinates and verification manifests required by the core library and its tests | Provided as program data required by the software, under the same PolyForm Noncommercial License; third-party source fields in the catalogs do not change the original rights of those third parties |
| The test file `web-v6-synthetic.zip` and the programmatically drawn images inside it | Provided as software test data, under the same PolyForm Noncommercial License; contains no private photos |
| Finished screenshots in `docs/media/` | For presenting this project only; the corresponding rights are reserved and they are not provided as reusable art assets. Third-party elements in them remain subject to their original rights and attribution notices |
| User instructions, prompts and download packages in `docs/cat-creation/` | For users to download, copy and use as described in the cat reference guide. They are not a release of the app's production art or production project files and are not automatically covered by the code license. The source, permitted uses and third-party rights of each item are in that directory's [ATTRIBUTION.md](docs/cat-creation/ATTRIBUTION.md) |
| The Fripouille-derived templates in `docs/cat-creation/POSE_GUIDE.png` and `docs/cat-creation/guides/` | guillaume bolis keeps the attribution for the original work and the applicable CC BY 4.0 rights; the repository's noncommercial code license does not replace or restrict the third-party license; no source model files are included |
| `docs/cat-creation/cat-creation-flow-bella.png`, `cat-creation-flow-bella-en.png` | The Chinese and English AI-generated finished posters for this workflow, only for presenting and sharing the workflow within this project; they are not app screenshots, and Bella's production art source assets are not released as reusable |
| Generated reference images that users upload in Issues | Not automatically included in the code or template license, and not automatically licensed for the built-in cat library, training or asset releases; the scope of a submission and any later use are confirmed separately |
| The QQ group QR code image in `support/` | Only for this project's free community entry; the corresponding rights are reserved and the source license does not apply. Third-party marks in them remain subject to their original rights |
| `README.md`, `README.en.md`, `SUPPORT.md`, this file, `.github/ISSUE_TEMPLATE/` and other project documentation | Project documentation; the corresponding rights are reserved and it is not licensed as reusable material together with the program source |
| `LICENSE`, `NOTICE` and applicable third-party licenses and attribution notices | May be copied with the corresponding work to meet license conditions; this does not change the license terms |

This package does not provide the full app's SwiftUI interface, RealityKit renderer or Lock Screen / Dynamic Island extensions, nor the production cat and furniture models, textures, icons, animations, design source files or private original photos. The promotional screenshots show only the finished interface; they do not mean that the source code or art resources shown are released with the core library.

Catalog entries in the source may reference the stable IDs or sources of production resources. These identifiers are part of the program and data compatibility interface; they are not copies of the resource files and grant no license to the corresponding source models, textures or design files.

The project name is used only to indicate the source. The source license grants no separate right to use the trademark or brand graphics.

Existing third-party licenses and rights granted by law remain unchanged. This file does not turn them into rights owned by the project, and does not withdraw rights already granted by other versions. The code baseline and extraction scope for this release are in [SOURCE-RELEASE.en.md](SOURCE-RELEASE.en.md).
