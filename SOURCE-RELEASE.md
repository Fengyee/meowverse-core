# 核心源码发行说明

简体中文 | [English](SOURCE-RELEASE.en.md)

本包按 2026-11-14 确认的方案整理：最新 MeowverseCore 核心源码公开，使用 PolyForm Noncommercial 1.0.0；正式 App 界面、渲染、美术与设计源文件继续私有。

## 版本与范围

- 来源 main：`0084971a5fa8a834738920aa320c7f8d4081bb12`，对应当前 0.1.0 (3) 开发线，资料库 schema 11。
- Swift 包：28 个库 Swift 文件、31 个测试 Swift 文件、Package.swift；附带必要的目录 JSON、合成备份 ZIP 与校验清单。
- 附带的 JSON 包含稳定 ID、家具类别、占地和互动坐标等程序数据；不包含正式网格、贴图或动作资源。
- 不包含 SwiftUI App target、Live Activity 扩展、正式渲染器或完整 App 构建工程。运行核心测试不会启动带房间画面的 App；完整体验请使用 TestFlight。

## 与原开发目录的差异

仅从导出副本的 `CatPackTests.swift` 中移除了依赖包外正式 Bella 素材的 `bundledBella` 集成测试。该测试在素材缺失时会直接返回；保留它会把未执行的素材验证误算为通过。其余核心源码和测试保持来源版本的字节内容。

原开发线声明 345 项核心测试，本包声明并实际运行 **344 项，44 个 suite，全部通过**。这不代表正式 App 的界面测试或真机性能验收。

## 图片与许可

README 的中英文截图（各三张）是单独供项目展示的开发版真实界面，采自 2026-11-15，晚于构建 3；照片内容为合成示意。来源、时间和第三方署名见 [图片说明](docs/media/ATTRIBUTION.md)。它们不作为本 Swift 库的运行画面，也不提供正式美术源资产。

代码、构建清单、必要程序数据和合成测试素材适用 [LICENSE](LICENSE)。成品宣传截图、README 等说明材料、群二维码和收款图不随代码授权为可复用素材，详见 [LICENSE-SCOPE.md](LICENSE-SCOPE.md)。正式许可使用未经修改的官方英文正文，解释不能扩大或缩小该正文的权利范围。

本次发行使用本文件列明的核心库范围及 PolyForm Noncommercial 许可，不包含此前社区版草案的界面或替换美术，也不撤销任何既有版本已有效授出的权利。

官方源码仓库为 [Fengyee/meowverse-core](https://github.com/Fengyee/meowverse-core)。完整产品可从 [TestFlight](https://testflight.apple.com/join/WCuPQFsm) 体验；QQ 群为 **Meowverse/猫宇宙**，群号 **1132819295**，群二维码及打赏方式直接展示在 [README 下方](README.md#community)。测试、反馈和入群不要求打赏。
