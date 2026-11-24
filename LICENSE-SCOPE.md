# 源码与展示材料的许可范围

简体中文 | [English](LICENSE-SCOPE.en.md)

本仓库提供 **喵空间 1.0 全部代码的可见源码（source-available）**：App、扩展、MeowverseCore 核心库、测试、Xcode 工程与构建脚本，采用 [PolyForm Noncommercial License 1.0.0](LICENSE)。许可含非商业用途限制，因此不把本发行称为标准开源发行。完整条款见 [LICENSE](LICENSE)，必要声明见 [NOTICE](NOTICE)。

可以在许可证定义的许可用途内使用、修改和再分发覆盖的软件；再分发时应按原文提供条款或其网址，并保留适用的 `Required Notice:` 声明。商业用途需要另行取得授权，请联系 [bella.meowverse@gmail.com](mailto:bella.meowverse@gmail.com)。此处是范围说明，不修改 [官方许可正文](https://polyformproject.org/licenses/noncommercial/1.0.0)。

| 范围 | 适用说明 |
| --- | --- |
| `ios/` 下的 Swift 源码与测试：`Meowverse/`（App）、`PocketCatShared/`、`PocketCatWidget/`、`MeowverseAssets/`（扩展）、`MeowverseCore/`（核心库与测试）、`MeowverseUITests/`（界面测试）、`Tools/` | PolyForm Noncommercial License 1.0.0 |
| 界面文字目录（`.xcstrings`）、隐私清单、Info.plist、权益文件、资产目录里的 `Contents.json` 与颜色 | PolyForm Noncommercial License 1.0.0 |
| Xcode 工程、scheme、测试计划、`.xcconfig`、`Package.swift`，以及 `ios/` 下的构建与测试脚本 | PolyForm Noncommercial License 1.0.0 |
| `ios/README.md` 和 `docs/` 中随代码发行的技术文档（[SOURCE-RELEASE.md](SOURCE-RELEASE.md) 列出） | 作为软件文档提供，适用同一 PolyForm Noncommercial 许可 |
| 程序必需的目录 JSON、schema、稳定 ID、占地边界、互动坐标和校验清单 | 作为软件必需程序数据提供，适用同一 PolyForm Noncommercial 许可；目录中的第三方来源字段不改变对应第三方的原有权利 |
| 测试用 `web-v6-synthetic.zip`、`inspect-fixture.usdz` 及其中的程序绘制内容 | 作为软件测试数据提供，适用同一 PolyForm Noncommercial 许可；不包含私人照片 |
| 代码中的第三方署名与许可说明（关于页的鸣谢数据） | 记录第三方作品的来源与许可，不改变对应第三方的原有权利，也不表示这些作品随本仓库提供 |
| `docs/media/` 中的成品截图 | 仅用于展示本项目，保留相应权利，不作为可复用美术素材提供；其中第三方元素仍依其原有权利与署名声明处理 |
| `docs/cat-creation/` 中的用户操作说明、提示词与下载包 | 供用户按猫咪参考图征集指南下载、复制和使用；不是正式 App 美术或制作工程的发行，不自动适用代码许可。各项来源、允许用途和第三方权利见该目录的 [ATTRIBUTION.md](docs/cat-creation/ATTRIBUTION.md) |
| `docs/cat-creation/POSE_GUIDE.png` 和 `docs/cat-creation/guides/` 里的 Fripouille 衍生模板 | 保留 guillaume bolis 的原作署名与适用的 CC BY 4.0 权利，仓库非商业代码许可不替代或限制第三方许可；不包含源模型文件 |
| `docs/cat-creation/cat-creation-flow-bella.png`、`cat-creation-flow-bella-en.png` | 本流程的中英文 AI 生成成品操作海报，仅供本项目展示与分享该流程；不是 App 截图，不发行可复用的 Bella 正式美术源资产 |
| 用户在 Issue 上传的生成参考图 | 不自动纳入代码或模板许可，不自动授权用于内置猫库、训练或素材发行；提交范围与后续采用分别确认 |
| `support/` 中的 QQ 群二维码图片 | 仅用于本项目的免费交流入口，保留相应权利，不适用源码许可；其中第三方标识仍依其原有权利处理 |
| `README.md`、`README.en.md`、`SUPPORT.md`、本文件、`.github/ISSUE_TEMPLATE/` 及其他项目说明文稿 | 项目说明材料，保留相应权利，不随程序源码许可一并授权为可复用素材 |
| `LICENSE`、`NOTICE` 及适用的第三方许可、署名声明 | 可随对应作品复制，以履行许可条件；不因此改变许可条款 |

本仓库不提供美术资源：猫咪与家具的模型、网格、贴图、房间主题、插画、App 图标、像素猫图片、控制中心符号、音效、字体、动画、Blender 等设计源文件，也不提供 DINOv2 模型权重和私人原始照片。`ios/Tools/make-placeholder-art.py` 生成的灰色占位图只用于让工程安静地编译，不是项目美术。宣传截图只展示成品界面，不表示图中的美术资源随代码发行。

源码中的目录条目和资源加载代码可能引用正式资源的稳定 ID、文件名或来源，这些标识属于程序与数据兼容接口；它们不是资源文件的副本，也不授予对应源模型、贴图或设计文件的使用许可。

项目名称只用于说明来源。源码许可不授予商标或品牌图形的独立使用权。

第三方已有的许可与法律赋予的权利保持不变，本文件不把它们改成项目自有权利，也不撤回其他版本已经授出的权利。本次代码基线与提取范围见 [SOURCE-RELEASE.md](SOURCE-RELEASE.md)。
