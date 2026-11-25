# 源码发行说明

简体中文 | [English](SOURCE-RELEASE.en.md)

2026-11-24 起，本仓库公开喵空间 1.0（2026-11-24 已提交 App Store 审核）的**全部代码**：App 本体、小组件与实时活动、控制中心、猫咪分档下载扩展、MeowverseCore 核心库、单元测试与界面测试、Xcode 工程和构建脚本。许可不变，仍是 PolyForm Noncommercial 1.0.0。**美术资源不公开。** 这一版取代 2026-11-14 只公开核心库的方案。

## 版本与范围

<!-- export-facts:begin -->
| 项目 | 值 |
| --- | --- |
| 来源提交 | `2f9d0415a2a0244ee689cac77a7e8bc8e8f5706e`（2026-11-24） |
| App 版本 | 1.0（14），最低 iOS 26.0 |
| 资料库 schema | 12 |
| App target | 244 个文件 |
| 小组件、实时活动、控制中心与猫的下载扩展 | 53 |
| MeowverseCore 与测试 | 246 |
| UI 测试 | 80 |
| Xcode 工程与构建设置 | 13 |
| 构建与测试脚本 | 14 |
| 工具（识别评测、DINOv2 转换） | 22 |
| 技术文档 | 10 |
| 发行时新增（占位图脚本、核心测试脚本） | 2 |
| 未公开的美术与资源文件 | 650 |
<!-- export-facts:end -->

表中数字由导出脚本按来源提交生成；每个文件的 SHA-256 记在 [SOURCE-MANIFEST.json](SOURCE-MANIFEST.json)，可以逐个对照。

| 目录 | 内容 |
| --- | --- |
| `ios/Meowverse/` | App target 的 Swift 源码、界面文字（`.xcstrings`）、隐私清单；资产目录只留 `Contents.json` 和颜色 |
| `ios/PocketCatShared/`、`ios/PocketCatWidget/` | 像素猫小组件、实时活动、控制中心控件和它们与 App 共用的代码 |
| `ios/MeowverseAssets/` | 猫咪低档、高档模型的下载扩展（Background Assets） |
| `ios/MeowverseCore/` | 核心库、测试和测试用的程序数据、合成备份 |
| `ios/MeowverseUITests/` | 界面测试 |
| `ios/Meowverse.xcodeproj/`、`ios/*.xcconfig`、`ios/*.entitlements`、`ios/*-Info.plist` | 工程、scheme、测试计划、构建设置、权益和 Info.plist |
| `ios/*.sh`、`ios/*.py` | 构建、测试、录屏和本地化检查脚本 |
| `ios/Tools/` | 家具识别评测工具、DINOv2 转 Core ML 的脚本、占位图脚本 |
| `docs/` 中的技术文档 | iCloud 同步、猫咪包格式、照片库模型、新手导览、渲染与画质分档、语音控制、猫咪小知识来源 |

语音控制（Talk to Bella）在 1.0 中隐藏，编译时就不包含；它的源码随本次发行公开，打开方法见 `ios/Config.xcconfig`。

关于页、公告和猫咪卡片里的赞助人用的是他们自己给的昵称（Omucat、阳子、锤宝、Xin、科内利乌斯）；没有昵称的猫写作「〈猫名〉的铲屎官」。

## 不包含什么

- **美术资源**：猫咪与家具的模型和网格、贴图、房间主题、插画、App 图标、像素猫图片、控制中心符号、音效、字体，以及 Blender 源文件和美术管线。它们是项目与合作者的作品，其中一部分按第三方许可使用；美术不随代码授权，也不适合按代码许可再分发。完整画面请看 App Store 上的喵空间。
- **DINOv2 模型权重**（约 86 MB 的 Core ML 文件）：可以用 `ios/Tools/EmbeddingLab` 从上游模型自己转换。缺少时 App 改用系统 Vision 给家具建议。
- 冻结的网页版 demo、私人素材、内部文档（进度、计划、审核记录、营销材料、团队配置），以及在维护者自己照片上做的识别评测记录。
- 内购代码。1.0 全部免费，内购从未进入 1.0 的代码。

代码注释里提到的一部分文档（如发版流程、导览台词稿、美术管线说明）属于内部文档，没有随本次发行公开。

## 与开发仓库的差异

- `ios/simulator-id.sh`：开发仓库里默认指向维护者 Mac 上的一台模拟器；公开版改成取第一台可用的 iPhone 模拟器。其余文件与来源提交逐字节相同。
- 新增 `ios/Tools/make-placeholder-art.py`（生成占位图）、`ios/test-core.sh`（跑核心测试）、`SOURCE-MANIFEST.json`，`.gitignore` 加了一段占位图的忽略规则。

## 怎么编译

需要 macOS、Xcode 27 和 iOS 26 SDK。没有外部 Swift Package 依赖，不需要模型密钥。

```sh
python3 ios/Tools/make-placeholder-art.py   # 可选：给资产目录补上灰色占位图
xcodebuild -project ios/Meowverse.xcodeproj -scheme Meowverse \
  -destination 'generic/platform=iOS Simulator' build
ios/test-core.sh                            # 核心库测试
```

不补占位图也能编过，只是 Xcode 会为每张缺失的图片报一条警告。补了以后 App 图标、插画处是灰色方块，控制中心符号是灰色圆点。家具、猫咪、房间主题、音效和字体在运行时读取，没有美术时这些位置是空的，App 里的房间不会是正式版的样子。

装到真机需要自己的开发者团队：在 `ios/Local.xcconfig`（不进 git）里写 `DEVELOPMENT_TEAM = <你的 Team ID>`，并把 `MEOWVERSE_BUNDLE_ID` 换成自己的标识。权益文件里的 App Group 与 iCloud 容器写的是本项目的标识，要一起改成你自己注册的。

`ios/test-core.sh` 跳过 10 条读取美术文件或网页的测试（脚本里逐条写明），而不是让它们失败或在文件缺失时不检查就算通过。

## 测试结果

<!-- 由 lead 在最终提交上重跑后更新 -->
在来源提交的导出副本上（Xcode 27.2，macOS 26.7.2）：

- 模拟器构建（`generic/platform=iOS Simulator`，Debug）：通过，补占位图前后都通过。
- `ios/test-core.sh`：1262 条测试中，并行跑时 4 条计时测试在机器繁忙时失败，单独重跑通过；`--no-parallel` 全部通过。

这些结果只说明公开的代码能编译、核心库测试能通过，不代表正式 App 的画面、真机性能或系统权限验收。

## 图片与许可

README 的中英文截图是单独供项目展示的成品界面，照片内容为合成示意。来源、时间和第三方署名见 [图片说明](docs/media/ATTRIBUTION.md)。它们不是运行本仓库代码得到的画面，也不提供正式美术源资产。

代码、构建清单、必要程序数据和合成测试素材适用 [LICENSE](LICENSE)。成品宣传截图、README 等说明材料、群二维码不随代码授权为可复用素材，详见 [LICENSE-SCOPE.md](LICENSE-SCOPE.md)。正式许可使用未经修改的官方英文正文，解释不能扩大或缩小该正文的权利范围。

本次发行不撤销任何既有版本已有效授出的权利。

官方源码仓库为 [Fengyee/meowverse-core](https://github.com/Fengyee/meowverse-core)。QQ 群为 **Meowverse/喵空间**，群号 **1132819295**，群二维码直接展示在 [README 下方](README.md#community)。测试、反馈和入群都免费。
