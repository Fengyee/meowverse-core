# 源码与展示材料的许可范围

本发行包提供 **MeowverseCore 核心库的可见源码（source-available）**，采用 [PolyForm Noncommercial License 1.0.0](LICENSE)。许可含非商业用途限制，因此不把本发行称为标准开源发行。完整条款见 [LICENSE](LICENSE)，必要声明见 [NOTICE](NOTICE)。

可以在许可证定义的许可用途内使用、修改和再分发覆盖的软件；再分发时应按原文提供条款或其网址，并保留适用的 `Required Notice:` 声明。商业用途需要另行取得授权，请联系 [bella.meowverse@gmail.com](mailto:bella.meowverse@gmail.com)。打赏不授予商业使用许可。此处是范围说明，不修改 [官方许可正文](https://polyformproject.org/licenses/noncommercial/1.0.0)。

| 范围 | 适用说明 |
| --- | --- |
| `ios/MeowverseCore/Sources/` 中的 Swift 核心程序 | PolyForm Noncommercial License 1.0.0 |
| `ios/MeowverseCore/Tests/` 中的 Swift 测试程序与 `Package.swift` | PolyForm Noncommercial License 1.0.0 |
| 核心库及测试必需的目录 JSON、schema、稳定 ID、占地边界、互动坐标和校验清单 | 作为软件必需程序数据提供，适用同一 PolyForm Noncommercial 许可；目录中的第三方来源字段不改变对应第三方的原有权利 |
| 测试用 `web-v6-synthetic.zip` 及其中的程序绘制图片 | 作为软件测试数据提供，适用同一 PolyForm Noncommercial 许可；不包含私人照片 |
| `docs/media/` 中的成品截图 | 仅用于展示本项目，保留相应权利，不作为可复用美术素材提供；其中第三方元素仍依其原有权利与署名声明处理 |
| `support/` 中的收款图 | 仅用于本项目的自愿支持入口，保留相应权利，不适用源码许可 |
| `README.md`、`SUPPORT.md`、本文件及其他项目说明文稿 | 项目说明材料，保留相应权利，不随程序源码许可一并授权为可复用素材 |
| `LICENSE`、`NOTICE` 及适用的第三方许可、署名声明 | 可随对应作品复制，以履行许可条件；不因此改变许可条款 |

本包不提供完整 App 的 SwiftUI 界面、RealityKit 渲染器或锁屏／灵动岛扩展，也不提供正式猫咪与家具模型、贴图、图标、动画、设计源文件或私人原始照片。宣传截图只展示成品界面，不表示图中的源代码和美术资源随核心库发行。

源码中的目录条目可能引用正式资源的稳定 ID 或来源，这些标识属于程序与数据兼容接口；它们不是资源文件的副本，也不授予对应源模型、贴图或设计文件的使用许可。

项目名称只用于说明来源。源码许可不授予商标或品牌图形的独立使用权。收款图的姓名遮盖不改变收款对象，也不授予将其作为其他项目收款入口的许可。

第三方已有的许可与法律赋予的权利保持不变，本文件不把它们改成项目自有权利，也不撤回其他版本已经授出的权利。本次代码基线与提取范围见 [SOURCE-RELEASE.md](SOURCE-RELEASE.md)。
