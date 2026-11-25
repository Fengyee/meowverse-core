# Meowverse for iOS

原生 SwiftUI App。核心只有一件事：**点房间里的沙发，看到让它出现的那张猫咪原图。**

空房间 → 系统照片选择器选一张照片 → 本机识别给出候选 → 确认款式和摆放 → 重开后点家具找回同一张照片。设备保存的副本可离线查看。用户授权读取相册后，系统也可以从 iCloud 照片取回大图。

第二轮（2026-11-09）从网页版补齐了：猫咪在房间里自己走动、上家具休息；照片库与照片详情（收藏、便签、拍摄日期、删除）；给已有家具再添照片、只存照片不添家具、之后再把照片变成家具；设置（猫咪名字（第十轮移到“猫咪管理”）、占用空间、核对照片）、导出备份、从备份恢复、导入网页版备份、清除全部数据；三步新手引导。

截图：[docs/ios-shots/](../docs/ios-shots/)。

## 家具与猫咪互动

新资料库从 Kitty 和一间空房开始。导入照片后手动选择「猫爬架」，确认款式与摆放，猫会自动走过来。也可以点房间底部的「互动」，请她在拍球台拨球、在底层猫洞藏身、坐上中层跳台，或到顶层软垫坐、趴、打盹。点家具可打开它的来源照片。

### 房间、装扮与陪伴

- 15×15 房间支持从全景捏合到近看，放大后可以平移。手指可以从家具上开始操作。点到多件家具重叠的位置时会列出候选。房间外的 3D 宝箱打开收纳箱。摆放和移动时，同色底的虚线格标出门口和猫上下家具的位置。
- 「房间菜单 → 房间装扮」提供经典奶油、春·花芽、夏·海风、秋·枫糖和冬·初雪。选季节可预览墙纸和背景，也可选择素色墙面。「完成」保存到本机，「取消」恢复原样。分享明信片会沿用当前装扮和光线。
- 默认使用恒定柔光。选择「跟随当地时间」后按设备时区切换晨光（06:00）、日光（09:00）、黄昏（17:00）和夜景（21:00）。调节的是场景灯色、强度和背景，不需要定位权限。
- iPad 按窗口实际宽度布局。达到 880 pt 时房间与家具详情并排，摆放控件位于预览右侧。窄窗口使用单栏，旋转时保留已选照片和摆放草稿。切到另一个房间时关闭旧详情、回到全景，从家具库定位会跳到家具所在的房间。
- 「互动 → 陪我一会儿」启动像素猫实时活动。当前房间没有猫时，可从房间的「更多」菜单打开。支持灵动岛的 iPhone 在紧凑区域显示一个 20 pt 猫头像，展开或在锁屏可见状态和操作。用户选起始表情，其余五种随机排好，与起始表情组成一轮，每 5 分钟走一步，六步后循环。「换个表情」立即切换并重新计时，「结束陪伴」关闭活动。陪伴和 3D 房间各自运行。
- 手表与控制中心（第 11 轮，owner 2026-11-19 决定，方案见 [docs/WIDGETS_WATCH_AR.md](../docs/WIDGETS_WATCH_AR.md)）：实时活动声明了 `.supplementalActivityFamilies([.small])`，手表的智能叠放（以及 CarPlay）用单独的布局 `PocketCatWatchStatus`：48 pt 整只像素猫、猫名、表情，不放按钮。锁屏把原来的「陪我一会儿」换成猫名；灵动岛的紧凑态、最小态和展开态不变。猫名是 `PocketCatAttributes.catName`（可选，开始陪伴时定下，改名从下一次陪伴起生效；更新前已在跑的陪伴解码为没有名字，显示「陪我一会儿」），取房间里领头的猫，房间里没有猫时取第一只。名字只占一行，过长以「…」截断，空白和看不见的字符算没有名字。控制中心有三个控件（扩展改成了 `WidgetBundle`）。「陪我一会儿」是开关（owner 用 7.24 试过后要求，像手电筒）：开着表示正在陪伴，值从 App Group 读（`PocketCatCompanyToggle`，和小组件同一份记录、同样防迟到写入和 8 小时上限），大尺寸时显示「陪伴中」/「未陪伴」；点开用 `SetPocketCatCompany`（`SetValueIntent` 加 `LiveActivityIntent`）在后台开始陪伴，不打开 App，名字读 App 留在自己 UserDefaults 里的那份，已有陪伴在跑就沿用它、不换表情；点关结束所有在跑的陪伴并清掉 App Group 里的记录，实时活动、小组件和开关一起回到没在陪伴。开始、换表情、结束时都 `reloadControls`。种类沿用原来按钮的 `app.meowverse.control.companion`，已加进控制中心的直接变成开关。实时活动被关掉时由系统显示一句说明。「拍照添加」「从相册添加」打开 App，走主屏快捷项的同一条路。手表上的样子没在真机上看过；`-MeowverseOverlayGallery watch`（DEBUG）把手表布局按 40 mm 和 49 mm 的尺寸画出来供评审。模拟器上新装的扩展，控件要重启一次模拟器才出现在控制中心的添加列表里（`PocketCatWatchControlsUITests`）。
- 小组件第一步（第 11 轮，样张 `art/ui/source/widget-mockups.py`，评审 `art/ui/reviews/r11-widgets.md`）：同一个扩展里加了「像素猫」主屏小组件（小、中）和锁屏小组件（圆形、矩形），代码在 `PocketCatWidget/PocketCatScreenWidgets.swift`。没在陪伴时，猫按整点轮换表情，按钮是「陪我一会儿」（`StartPocketCatCompany`，不打开 App）；陪伴中按钮换成「换个表情」（`ChangePocketCatMood`），表情跟灵动岛一致，时间线按陪伴的轮换排好（`PocketCatWidgetPlan`）。中号多一个「添加照片」，打开 App。点按钮以外的地方打开陪伴页。着色主屏和锁屏用单色整只猫（`mono-figure-*`）当模板图，绿窗不画。小号的按钮字号最大到「大」，再按 0.8 缩，不出省略号。扩展读不到 App 的实时活动，所以 App 在开始、换表情、结束陪伴时把陪伴状态写进 App Group `group.io.github.fengyee.meowverse`（`PocketCatCompanyShelf`：会话 id、开始时间、表情轮换，不放照片、猫名和统计），并刷新小组件；App 回到前台时再对一次账。结束过的陪伴记下会话 id（最多 8 个），之后迟到的写入不会把它带回小组件；系统 8 小时的上限落在时间线中间时，到点就换回没在陪伴的样子。猫名、统计、房间缩略图是第二步，没做。

新款还有剑麻抓柱、瓦楞斜面抓板、窗边双层小台、弹簧布隧道、薄荷毡窝、甜甜圈软垫和弹簧逗猫鼠。Vision 继续提供已有标签的本机建议，宠物专用类别可手动选择。房间里的动作只在当前会话播放。

图片附加清单补入开放猫砂盆、三级踏板软垫飘窗、羽毛棒托盘、木托双碗餐台和花瓣饮水机。手动选择「猫砂盆」「窗台」「逗猫玩具」「水碗和饮水机」后选款确认。猫可扒砂、登窗坐看或趴睡、拍羽毛、低头吃粮和舔水。[逐项实现与独立审核](../docs/ADDITIONAL_FEATURES.md)

### 玩具与零食

空房间也能点「互动 → 选玩具」或「互动 → 喂小零食」。可选毛毡小鼠、拼色小球、羽毛逗猫棒，以及三文鱼小片、鸡肉小块、小鱼饼干。在空地点按放下，拖动玩具可带猫跟随。「放到空地／换位置」提供等价的按钮操作，玩耍时用双指平移镜头。更换和结束按钮带有 VoiceOver 标签。

玩具会持续陪玩，零食到达后约 4.8 秒活跃时间吃完。打开其他界面或切到后台会暂停。选项通过 `bella.playItem` 保存在设备设置中，道具与消费进度属于本次互动。家具记录继续通过照片确认流程创建。

### 地面步态

在房间左上角的「房间菜单」里选择普通行走、优雅慢步、奔跑或连续跳跃。默认为普通行走，选择自动保存在本机。猫咪行进中会从当前位置按新步态和速度继续前往原目的地，普通休息时会起身出发。上下家具的踏板路线与系统「减弱动态效果」分别由房间处理。原生播放取自同一份 Bella 骨骼素材。[步态素材和速度](../assets/models/README.md#地面步态)

### 房间明信片

打开左上角的「房间菜单 → 分享房间」，可以看到当前虚拟房间与 Bella 的全景明信片。修改标题或「附上喵空间二维码」后，预览会更新。二维码默认关着、每次打开都从关开始（owner，2026-11-20：它指向冻结的网页 demo）。点「分享明信片」由 iOS 系统面板选择接收应用或保存位置。输出是本机合成的 2400 × 2400 PNG，含 2160 × 1460 的房间渲染和 App 图标。二维码指向[网页版原型](https://fengyee.github.io/meowverse/)，每张卡使用同一个地址。卡面仅使用虚拟场景、可见标题和启用的体验码。

### 放到桌上看看（AR，第 11 轮试验版）

「互动 → 放到桌上看看」（在「陪我一会儿」那一组的下面，单独一组）全屏打开相机，系统引导找到水平面后，点一下桌面（或点「放在这里」，放在屏幕中间）把当前房间放上去，默认约 36 cm 宽，开放的一角朝向手机。双指缩放（15 cm 到 1.2 m）、双指旋转、单指拖动；「重新放置」拿起来重放；点家具或从「家具」菜单打开和房间里一样的家具详情；左上角「回到房间」（`ar-exit`）退出，房间状态不变。AR 里用透视镜头，这是 owner 定的例外（[docs/WIDGETS_WATCH_AR.md](../docs/WIDGETS_WATCH_AR.md)），房间页仍是固定正交。

- 实现：`Room/RoomARScreen.swift` 是页面和 ARKit 会话；房间本身用房间页的同一个 `RoomSceneController`，以桌面模式挂在 `ARView(cameraMode: .ar)` 上：不建正交相机，房间整组放在一个 `room` 实体下按 `ARTabletopPose` 缩放、转向、平移，灯另挂一个只转不缩的实体，阴影距离按米算。放置、缩放、拖动的数学和入口规则在 Core 的 `ARTabletop.swift`（`ARTabletopTests`）。
- 设备不能追踪世界（模拟器、Mac 上的 iPad 版）时没有这一行；相机权限关着时这一行还在，下面写明，打开后的页面给「打开系统设置」。相机画面只在本机显示，不录制、不保存；场景里没有用户照片，照片板仍是色块。
- 进后台时暂停相机会话；家具详情打开、手机过热（`thermalState` serious 以上）或会话中断时猫停下。详情里选「编辑家具」「在房间里定位」会先关掉 AR，等它完全退下后在房间里接着做。
- 文字在单独的 `RoomAR.xcstrings`，不进 `Localizable.xcstrings`。
- 只在模拟器上验过入口和「不能用 AR」页（`RoomARUITests`）。放置、手势、猫在桌上走、帧率、发热、内存全部没在真机上看过。

### 画质（2026-11-22）

「设置 › 画面 › 画质」有四项：自动（默认）、高、中、低。选择存在本机 UserDefaults（`room.renderQuality`，测试库按库名分开、随 `-MeowverseResetStore` 清掉），不进存档、备份和同步。切换后房间立即按新档画，不重开 App、不重建场景（猫不回门口）。规则和数值都在 Core 的 `RenderQuality.swift`（`RenderQualityTests`），App 侧是 `App/RenderQualitySetting.swift` 和 `RoomSceneController.applyQuality`。

画质表由 `RenderQuality.swift` 定义。iPhone 15 Pro 的 20 件家具短测中三档场景更新均约 60 Hz，GPU 命令缓冲中位数约 0.43／0.56／1.33 ms。长期功耗待测。

| 档 | 每点最多像素 | 家具自遮挡 | 太阳投影 | 接地软影／HDR | 家具材质 |
| --- | ---: | --- | --- | --- | --- |
| 高 | 3 | 开 | 开 | 开 | 全家具粗糙度与法线贴图，样板使用原稿底色 |
| 中 | 1.75 | 开 | 开 | 关 | 最长边 128 px 底色 |
| 低 | 1.5 | 开 | 关 | 关 | 调色板底色 |

- 房间页和摆放预览跟随档位。桌面 AR 使用自己的渲染设置。款式图和明信片使用完整材质与 HDR。家具参数、
  资源更新命令和场景适用范围见 [iOS 房间画质与家具资产](../docs/ROOM_RENDERING.md)。
- 自动按 `ProcessInfo.physicalMemory`：不到 5 GiB → 低（4 GB 及以下的机型，报告值约 3.7 GiB），5–7 GiB → 中（6 GB 机型约 5.6 GiB），7 GiB 及以上 → 高（8 GB 机型约 7.5 GiB）。阈值放在两档中间，留出设备少报的余量。
- 发热：选「自动」时，`thermalState` 到 serious 或 critical，降一档（高 → 中、中 → 低，低不再降），只降不升，到下次启动为止；降的那一下用一条 4 秒自己消失、不拦点按的提示说明（`TransientNotice`），设置里的说明也改成“这次先用「中」”。手动选了高、中、低时不自动改。在发热时改回「自动」，立即按降过的一档。
- 测试开关（DEBUG 和演练构建）：`-MeowverseQuality <auto|high|medium|low>` 启动时把选择写成这一档（会存下来）；`-MeowverseQualityMemory <GiB>` 假装设备有这么多内存；`-MeowverseQualityThermal <nominal|fair|serious|critical>` 假装发热状态，加 `-MeowverseQualityThermalAfter <秒>` 则在资料库就绪这么多秒后才到，相当于系统发来的变化；`-MeowverseQualityProbe` 在窗口上放一个 `room-quality-probe` 元素，值是房间视图实际的 `scale <倍率> shadows <on|off>`，同时传 `-MeowverseFurnitureTextureProbe` 可读家具已绑定的底色与材质图、自遮挡材质数、HDR 环境和地板遮挡图。`-MeowverseFurnitureOcclusion <on|off|legacy>` 单独切换材质的自遮挡，或用 `legacy` 走旧网格路径。用 `-MeowverseCapRoomScaleAt2x` 单独对照 2× 与 3× 的代价。UI 测试 `RenderQualityUITests`。
- 120 件 v2 家具共用预烘焙的几何自遮挡，照相板由代码生成。三档的分辨率、动态阴影和样板底色仍各按表生效。
- 猫也按档换网格（2026-11-20）：App 包里只有中档，低档按需下载（Background Assets），没下载、下载中或失败时用中档；「高」在还没有高档时也是中档。房间和 AR 用同一档，「查看 3D 模型」只读 `inspect.usdz`，明信片用现有最好的一档。切换时猫原地换网格，不回门口。格式、选择规则和下载的调研结论在 [猫咪包格式](../docs/CAT_PACK.md)「画质档」「按需下载」；Core 是 `CatPackTiers.swift`（`CatPackTierTests`），App 是 `App/CatTierSupport.swift`，UI 测试 `CatTierUITests`。下载扩展 `MeowverseAssets/`（Background Assets，Apple 托管）和 Info.plist 键 2026-11-20 接好了。九只内置猫的 App 清单（`Resources/Art/<id>-cat.json`）都带 `tiers.low`，低档文件不在 App 包里，是九个资源包 `cat-<id>-low`（招财的 2026-11-24 上传）；资源包上传到 App Store Connect 之前，选「低」时猫下载不到，留在中档并显示失败的说明（模拟器上不设 URL Override 时就是这样；TestFlight 构建上没看过）。换了网格的档必须带齐自己的贴图，否则这一档不可用（`CatPackManifest.textureGap`，见猫咪包格式的字段表）。
- 低档没就绪时（未下载、下载中、失败、iOS 26 以前），设置里「画面」和画质页的页脚各多一句说明，房间里不提示（`AppModel.catTierNote`，UI 测试 `testQualityNoteSaysTheCatIsOnTheStandardModelUntilLowIsReady`）。

#### 低档资源包：整理、本机服务、端到端

```sh
./ba-local.sh stage                        # 九只猫的真低档 → build/asset-packs/cat-<id>-low.aar（从 assets/cats/<id>/ 的 low-rigged.glb 和贴图现做）
./ba-local.sh stage --tier-source <目录>   # 或者读现成的文件：<目录>/<id>/low/<文件>
./ba-local.sh certs                        # 一次性的根证书和 localhost 证书，放进 build/ba-local 的单独钥匙串
./ba-local.sh sim <模拟器 UDID>            # 只在这台模拟器里信任根证书，并把 BA 的 URL Override 指向本机
./ba-local.sh serve                        # 前台跑 ba-serve，Ctrl-C 停
TEST_RUNNER_MV_BA_SERVE=serving xcodebuild … -only-testing:MeowverseUITests/CatTierUITests/testLiveAssetPackDownloadFromALocalServer test
# 停掉 serve 再跑一次，TEST_RUNNER_MV_BA_SERVE=stopped：中档加失败的说明
./ba-local.sh clean <模拟器 UDID>          # 钥匙串从搜索列表拿掉并删除，清掉 URL Override
```

- `testLiveAssetPackDownloadFromALocalServer`（serving）：Bella 下载 → 低档；低画质下做的明信片上是中档（`-MeowverseCatProbe` 时窗口上的 `postcard-cat-probe` 记着上一张明信片上的猫）；在逗猫棒旁边先拍低档、再原地换中档拍一张（附件名带猫的地面坐标，方便裁出猫来对比）；重开仍是低档。别的猫只在需要时手动看（下一条）。
- 手动看：`-MeowverseCatTiers live -MeowverseQuality low` 启动，猫先是中档，下载完原地换成低档；`-MeowverseCatProbe` 时 `bella-probe` 的值以 `#low` 结尾。别的内置猫加 `-cat.activePack.Test-<名字> <id>`（`-MeowverseStore <名字>` 的测试库放在 `Test-<名字>`，选的猫也按它记；默认库是 `cat.activePack`）。
- `ba-serve` 只从用户钥匙串搜索列表里找证书，`certs` 把单独的钥匙串文件加进列表、`clean` 拿掉，登录钥匙串和 Mac 的信任设置都不动。根证书留在模拟器里，要清掉用 `xcrun simctl keychain <UDID> reset`。`ba-package` 的 `-o` 要绝对路径。
- 真机（没试过）：证书的名字和 SAN 要换成 Mac 的局域网地址或 `.local` 主机名（`ba-serve --host` 用同一个），根证书做成描述文件装到手机上并在「设置 › 通用 › 关于本机 › 证书信任设置」里打开；手机开开发者模式，在「设置 › 开发者 › Background Assets Testing › Development Overrides › URL Override」填 `https://<地址>:54753`；用 Xcode 或 `./build.sh device` 装开发签名的构建。依据：Apple 文档「Testing asset packs locally」。
- TestFlight 和商店：资源包单独上传、外部测试前单独过审，见 [TestFlight](../docs/TESTFLIGHT.md)「猫的低档资源包与下载扩展」。

### 和猫咪说话（Talk to Bella，第 12 轮）

房间右下角、底部控件上方的像素猫头像（`talk-to-bella`）。点一下说一句话，猫用已有的动作回应，不说话。设计和规则见 [docs/TALK_TO_BELLA.md](../docs/TALK_TO_BELLA.md)，开关是 `FeatureFlags.talkToBella`（免费）。

1.0 里没有这个功能（上线设计 §2）：默认构建不编译 `TalkToBella/`，产物不链接 Speech 和 Foundation Models，Info.plist 里没有麦克风、语音识别的用途说明（两句的翻译仍在各语言的 `InfoPlist.strings` 里：一个 target 只有一份 `InfoPlist.xcstrings`，iOS 只在 Info.plist 有这个键时才读翻译），房间里没有头像，公告里没有这一条，右下角饰照常显示。要它就用构建设置打开，测试也要告诉 Runner：

```sh
./build.sh sim MEOWVERSE_TALK_TO_BELLA=YES
python3 check-voice-build.py build/DerivedData/Build/Products/Debug-iphonesimulator/Meowverse.app present   # 默认构建用 absent
TEST_RUNNER_MV_TALK_TO_BELLA=1 xcodebuild … -only-testing:MeowverseUITests/TalkToBellaUITests test-without-building
```

默认构建上 `TalkToBellaUITests` 全部跳过，跑的是 `VoiceOffUITests`。

- 管线：`TalkToBella/SpeechListener`（只用设备上的识别）→ Core 的 `BellaCommandRules`（固定说法）→ 没匹配上且有 Apple 智能时 `TalkToBella/BellaIntentModel`（Foundation Models，iOS 26+）→ Core 的 `BellaCommandResolver`（按房间判断能不能做）→ 和「互动」菜单相同的调用；「过来」走 `BellaActor.come(to:)`。头像外观在 `DesignSystem/BellaVoiceButton.swift`，评审页 `-MeowverseOverlayGallery bella`。
- 声音和文字只在内存里，日志不记识别文字；设备不支持本机识别或权限关着时，头像是「语音不可用」，点按直接打开「互动」。
- 文字在单独的 `TalkToBella.xcstrings`（放在 `Meowverse/` 顶层，`check-localization.py` 只扫顶层）。
- 模拟器上没有本机语音识别，也没有 Foundation Models：只能用下面的测试开关走规则这条路（`TalkToBellaUITests`）。麦克风、权限弹窗、模型、音频会话全部没在真机上看过。

### 猫咪模型

内置 Bella 是按她本人重建的模型。「猫咪管理 → 猫咪模型」（房间顶部的「猫咪」）可以切换猫咪、导入 `.meowcat` 客制化猫咪，并在「查看 3D 模型」里查看高精度版本。房间只加载约一万面的低精度网格。坐、趴、睡、走和全部家具互动都在同一副骨架上播放。[猫咪包格式](../docs/CAT_PACK.md) · [从重建模型到猫咪包：骨架、权重与动作](../docs/CAT_RIG.md)

照片库、家具库、两者的多对多关联，以及多房间、多猫咪的扩展方向见[照片库与家具库：对象、关系和界面](../docs/IOS_LIBRARY_MODEL.md)。已实现的部分：照片库里多选后一起放进家具、收藏或删除，按家具筛选；家具相册里多选后移出、移到另一件或也放进另一件；给家具添照片时可以直接从照片库选；家具列表每行显示分类、照片张数和上次添照片的时间。家具库是全屏页面：可搜索、筛选、排序，列表和封面两种视图，多选后一起锁定、收纳或删除；家具可以锁定（不能移动、换款式、收纳、删除）、在房间里定位、选封面、调整照片顺序。

### 扩充家具

1. 在 `scripts/ios/pet-furniture.mjs` 的 `recipes` 中声明款式、占地和互动点。每个点有稳定的 `id`、中文名称、猫脚底中心位置、朝向、可用动作和从正面入口开始的中间落脚点 `via`。相同踏板请复用同一个坐标。配方中的长度单位是房间的一格，朝向为绕 +Y 轴的弧度，零表示面向 +Z。
2. 复用外部模型时，把核过许可的 GLB 放在 `assets/sources/pet-furniture/`，记录原作页面、下载版本和 SHA-256，并登记到 `scripts/check-privacy.mjs`。该目录只供烘焙。也可以用配方中的几何部件制作模型。十款外部模型的发布方标注了 AI 辅助制作及 CC0 许可，另有三款原生家具和六款随身道具由本项目制作。详见 App 内署名和来源清单。[宠物素材包](https://3dassets.dev/packs/companion-animals-and-pet-home) · [剑麻抓柱](https://3dassets.dev/assets/boarding-kennels-and-cattery-boarding-kennels-and-catt-f731695e)
3. 在仓库根目录执行下列命令。烘焙会生成原生目录、绘制用网格、姿势、署名和来源记录。随后用合成照片在模拟器检查洞口遮挡、爪尖接触、进出路线与各个朝向。

```sh
npm ci
node scripts/ios/bake-ios-assets.mjs
node scripts/ios/bake-ios-assets.mjs --check
node --test scripts/ios/bella-interaction-poses.test.mjs
npx vitest run --config scripts/ios/web-backup-fixture.config.ts
swift test --package-path ios/MeowverseCore
```

其中 Vitest 命令生成 Web v6 合成备份，仅供测试 target 使用。新检出首次运行 Swift 测试前需要生成一次。

## 环境

| 项 | 值 |
| --- | --- |
| Xcode / SDK | Xcode 27.2，iOS SDK 27.2 |
| 最低系统 | iOS 和 iPadOS 26.0（App、两个扩展和 `MeowverseCore`）；只上 iPhone 和 iPad，不上 Mac（Catalyst、“为 iPad 设计”）和 Vision Pro |
| 名字 | 中文系统上叫「喵空间」，其他语言叫 Meowverse：中文名在 App 和两个扩展各自的 `InfoPlist.xcstrings`（`CFBundleDisplayName`，只有 zh-Hans），英文名是 `MEOWVERSE_DISPLAY_NAME`。界面里的中文说「喵空间」；文件名、`.meowcat`、网址、标识符、iCloud 云盘里的文件夹名和「Meowverse」相簿不改 |
| 版本 | 1.0；构建号 `CURRENT_PROJECT_VERSION` 在 App 和两个扩展的 Debug、Release 里共六处，要一起改，比手机上和 App Store Connect 上已有的都大 |
| 语言 | Swift 6（App 默认 MainActor 隔离）；UI 测试 target 用 Swift 5 模式 |
| Scheme | `Meowverse`（日常与测试），`MeowverseDemo`（录演示，带屏幕录制的 test plan） |
| Bundle id | `io.github.fengyee.meowverse`（`Config.xcconfig`） |
| 签名 | 在 `ios/Local.xcconfig` 写一行 `DEVELOPMENT_TEAM = <你的 Team ID>`；这个文件不进 git |
| 第三方依赖 | 无。只有本地包 `MeowverseCore` |

并行开发时，可以为每个 worktree 选一台专用模拟器，把它的 UDID 单独写一行到 `ios/Simulator.local`。构建、UI 测试、启动和录制脚本都会读取它，临时切换可设置 `MEOWVERSE_SIM`。在 Xcode 界面运行时选择同一台设备。要让模拟器上的安装和数据也能与主版本共存，可在该 worktree 的 `ios/Local.xcconfig` 中设置以下两行，把 `demo` 换成自己的标识。两个本地配置文件均已排除出 Git。

```xcconfig
MEOWVERSE_BUNDLE_ID[sdk=iphonesimulator*] = io.github.fengyee.meowverse.worktree.demo
MEOWVERSE_DISPLAY_NAME[sdk=iphonesimulator*] = Meowverse demo
```

这个名字只在英文系统上看得到；中文系统上两份都叫「喵空间」（中文名来自 `InfoPlist.xcstrings`，不读构建设置）。

## 命令

都在 `ios/` 下执行。`<udid>` 用 `xcrun devicectl list devices` 查。

```bash
swift test --package-path MeowverseCore        # 核心逻辑、互动路径与备份
./build.sh sim                                 # 模拟器 Debug 构建
./build.sh device                              # 真机 Release 构建
xcrun devicectl device install app --device <udid> build/DerivedData/Build/Products/Release-iphoneos/Meowverse.app
xcrun devicectl device process launch --device <udid> io.github.fengyee.meowverse
./test-ui.sh                                   # 模拟器跑全部 UI 测试
./test-ui.sh <udid>                            # 真机跑全部 UI 测试
./test-one.sh <测试方法名> [udid]               # 单条
./export-shots.sh <目录>                        # 导出上一次 UI 测试里的命名截图
./measure-launch.sh <udid>                     # 真机冷启动：Instruments 标记、内存、卡顿
./measure-flow.sh <udid>                       # 真机全流程：同上，覆盖导入 → 保存 → 打开原图
./record-demo.sh <udid> <输出.mp4>              # 真机录演示（合成照片）
node ../scripts/ios/bake-ios-assets.mjs --check # 校验 App 内美术资源与 Web 来源一致
```

真机无线安装需要手机已配对、已解锁、和 Mac 在同一网络。免费开发者账号同一台手机最多装 3 个自签 App，UI 测试会额外占一个（测试 Runner）。

### 测试用开关

只在 Debug 或带 `DRILLS` 编译条件的构建里存在，正式 Release 构建里没有：

- `-MeowverseStore <名字>`：用独立的测试库 `Test-<名字>`，不碰用户数据
- `-MeowverseResetStore`：启动时清空该测试库（对用户库无效）
- `-MeowverseFailNextSave`：让下一次保存失败一次
- `-MeowverseSyntheticPhoto`：显示"合成照片"按钮，导入一张程序画的照片（带 EXIF 日期 2026-03-14）
- `-MeowverseColorGridSimilarity -MeowverseFailPrints`：每张照片的特征都算不出（之前缓存的还读得到），看「这次没能完成比对」。算不出的每张只试一次，到下次打开、照片文件变了、导入新照片或再按一次「按建议放进家具」时再试；试了几次记在 `Caches/Meowverse/print-attempts-Test-<库>`（每次打开从 0 数）
- `-MeowverseColorGridSimilarity -MeowverseUnlikePrints`：任何两张不同的照片都不相像，看「房间里没有和它相像的家具」
- `-MeowverseBackupDrill`：设置页在导出之后多一个“演练：恢复刚导出的备份”按钮，不经过系统文件选择器走完导出 → 预览 → 恢复
- `-MeowverseSeveralHomes`：打开 1.0 里隐藏的多个房间、多只猫咪（见下面“多个房间和多只猫咪”）
- `-MeowverseAddHomesDrill`：打开资料库后像快捷项那样直接调用一次 `addRoom` 和 `addCat`，把结果显示在提示里（测动作处的拒绝）
- `-MeowverseLinkDrill`：外链不打开浏览器，把要打开的地址写进这一行的辅助功能值（只在 Debug；测隐私政策这类链接时不联网）
- `-MeowverseSampleSponsors none|one|several`：用编的赞助人代替正式名单，看关于、公告、功能页和猫卡片上的致谢（只在 Debug）
- `-MeowverseReleaseEntries`：像正式构建一样藏起「导入猫咪模型…」
- `-MeowverseCloudFolder <名字>`：备份到 iCloud 云盘改用 App 容器里的普通文件夹，见下面“备份到 iCloud 云盘”
- `-MeowverseRealICloud`：测试库（`-MeowverseStore`）里也走真正的 iCloud 云盘。不加时测试库不碰 iCloud
- `-MeowverseSyncFolder <名字>`：iCloud 同步改用 App 容器里的普通文件夹代替 CloudKit，两个测试库用同一个名字就互相同步；`-MeowverseSyncAccount <名字>`、`-MeowverseSyncFault <offline|signedOut|quota|deleted>` 模拟换账户和出错，见下面“iCloud 同步”
- `-MeowverseRealICloudSync`：测试库里也走真正的 CloudKit 同步（只在打开了 `FeatureFlags.iCloudSync` 的构建里有效）。不加时测试库不碰 CloudKit
- `-MeowverseBackupFile <路径>`：设置页多一个“演练：打开指定的备份文件”按钮，把这个文件当作用户选中的备份（模拟器上可以直接给 Mac 上的路径）
- `-MeowverseFastPocketCat`：把陪伴的单步时长调为 5 秒，供前后台轮换测试。
- `-MeowverseQuality`、`-MeowverseQualityMemory`、`-MeowverseQualityThermal`、`-MeowverseQualityThermalAfter`、`-MeowverseQualityProbe`：画质的选择、内存、发热和读回，见上面「画质」
- `-MeowverseCatTiers <ready|hang|fail|after:<秒>|live|live-kept>`：内置猫低档的下载怎么走。`live` 真的经 Background Assets 下载（先删掉上次下好的，`live-kept` 保留），要配本机的 `ba-serve`（上面「画质」）；其余几种不下载，用猫自己的中档文件按低档的文件名顶替，分别是已在设备上、永远下不完、半秒后失败、若干秒后完成。配 `-MeowverseCatProbe` 读出房间里的档（值的第一段以 `#low`、`#medium` 结尾）
- `-MeowverseShowAREntry`：模拟器上也显示「互动 → 放到桌上看看」；点开后的页面照实说这台设备不能用 AR
- `-MeowverseShowAREntry -MeowverseARDrill <camera-off|controls>`：模拟器到不了的两个 AR 画面，只用来看颜色：相机权限关着的说明页，或者黑底上「找到桌面以后」的底栏
- `-MeowverseFakeCamera`：模拟器没有相机。打开后「添加照片」出现「拍照」，点开是一个演练相机，“Use Photo”会像系统相机一样交出一张程序画的照片：转过 90° 的像素，加上带 EXIF 拍摄时间（2026-05-20）和 GPS 的元数据，走和真相机相同的编码与导入。
- `-MeowverseFakeCameraDenied`：同上，但当作相机权限已关闭，点「拍照」出现无法打开相机的提示。
- `-MeowversePhotosSave refused|failed`：拍照后存进“照片”时按没有权限或存不下失败，看查看页的提示（`CaptureSaveWordsUITests`）。
- `-MeowverseFailImportRead`：每次导入都在读到照片之后失败，看各种来源的失败提示（`CaptureFailureWordsUITests`）。
- `-MeowverseDiskFullAfter <n>`：存进 n 张照片以后按储存空间已满失败（`DiskFullUITests`）。
- `-MeowverseDeliveredDrill`：「清除全部数据」之前先送达一条临时授权的通知，清完把剩几条写进 `Caches/Meowverse/delivered-after-Test-<库>`（`ClearAllCompanyUITests`）。
- `-MeowverseBackupExpiryDrill`：备份一开始就当作后台时间到期，把后台任务是否已结束写进 `Caches/Meowverse/backup-expiry-Test-<库>`（`BackupExpiryUITests`）。
- `-MeowverseSyncOlderCatalog`（只在 Debug）：同步时当作不认识沙发的旧版本，和 `-MeowverseSyncFolder` 一起用（`SyncNewerPieceUITests`）。
- `-MeowverseQuickAction <类型>`：启动时收到一个主屏幕快捷项，相当于从长按菜单冷启动。类型是 `app.meowverse.camera`、`app.meowverse.library`、`app.meowverse.companion`、`app.meowverse.memory` 之一。
- `-MeowverseQuickActionDelay <秒>`：配合上一条，启动后过这么多秒才收到快捷项，相当于 App 在前台或后台时被点了长按菜单。
- `-TalkToBellaTranscript "<一句话>"`：点房间角落的猫咪头像时不开麦克风，直接把这句话当作听到的内容走完整条管线。
- `-TalkToBellaRulesOnly`：和上一条一起用，只用固定说法、不调 Foundation Models，结果可重复（有 Apple 智能的模拟器否则会走模型）。

`-MeowverseFailNextSave` 现在也会让下一次“替换资料库”（恢复、导入、清除全部）失败一次。

## 结构

```
Meowverse/            App：SwiftUI 界面
  App/                入口、AppModel、文案、设置与备份、新手引导、关于与隐私
  Room/               房间（RealityKit 正交相机）、美术加载、家具列表、猫咪的走动与状态文字
  Import/             导入：候选确认 → 款式 → 摆放；或加到已有家具；或只存照片
  Memories/           家具详情：原图、日期、来源
  Photos/             照片库、照片详情（收藏、便签、拍摄日期、删除）
  Resources/Art/      Bella、14 款 Kenney 家具和 13 款宠物家具（见 ATTRIBUTION.txt）
MeowverseCore/        本地 Swift 包：数据模型、网格规则、照片读取、文件存储、候选状态机、Vision 识别
PocketCatShared/      App 与扩展共用的表情、轮换顺序、系统操作、图集与文案
PocketCatWidget/      灵动岛与锁屏实时活动。系统计时文本与相位字体决定当前可见的一层
MeowverseUITests/     真机/模拟器端到端测试
```

数据在 App 的 Application Support 下：`state.json`、`state.backup.json`、`originals/<sha256>.<ext>`、`thumbnails/<photoId>.jpg`。每次修改要么全部写入要么回滚；`state.json` 损坏时从备份恢复并提示用户。存下来的文件用 SHA-256 去重和校验。

**照片只存一份缩小的副本（版本 8，2026-11-13）。** 完整的原图留在用户的相册里，App 不再存第二份。导入时长边超过 2048 px 的照片存成缩小的副本（HEIC，写不了 HEIC 时用 JPEG；方向已摆正，不带 EXIF 和位置），长边不超过 2048 px 的照片原样保存。缩小保存的记录带 `reducedFrom`（原图的 SHA-256、字节数和像素尺寸），这时 `sha256` / `byteSize` / `width` / `height` 描述的是存下来的副本；拍摄日期在缩小前从原图读出，记在记录里。同一张原图再选一次按原图的 SHA-256 认出来，不会存第二份；旧版本整张存下的照片不改动，再选同一张也认得出。关闭「从相册读取大图」时只用系统选图器，选取云端照片仍需等待 iCloud 下载。目录名仍叫 `originals/`。

**相册里的照片标识。** 选图器用 `photoLibrary: .shared()` 打开（不需要权限，也不弹授权框），每张照片记录里多一个可选的 `assetIdentifier`，即相册给这张照片的本机标识。它只是线索：只在选图的那台设备上有意义，相册里的照片可能已被删除，「从相册读取大图」取得授权后可以用它定位原图。判断“是不是同一张照片”仍然只看字节的 SHA-256，从不看这个标识。旧照片没有标识时，再选同一张并保存即可补记。迁移或删除相册原图后，完整授权下重新选择相同字节的照片，若旧绑定已明确失效，可在审阅页点「重新关联相册原图」，批量保存也会更新该绑定。仍有效的关联会保留，临时无法查询时可稍后重试。备份保留原记录的标识。它在版本 8 发布前加入，所以存档版本没有再升。

**从相册读取大图（不打开则退回存较大的副本）。** 第一次添加照片前（房间里的“添加照片”、引导最后一步、家具详情里的添加照片），先出现一页说明 `PhotoLibraryIntro`：打开有什么好处、需要访问所有照片、App 只读用户选进来的照片、照片去了哪里（按 iCloud 备份与同步的状态说，`PhotoReachWording.libraryIntroWords`）、不允许也能用。按 HIG 的预授权页规则（第十二轮审核 PRIVACY-2）只有一个「继续」按钮，直接进系统弹窗：不写“允许”，没有跳过的出口，不写“推荐”或“请选完整访问”，由用户在系统弹窗里决定。只在相册权限还没回答过时出现：在设置的开关或系统设置里答过（允许或拒绝），系统不会再弹窗，这页也就不出现。答过一次就不再出现；拒绝或只给部分访问时如实说明，再点「继续」去选图，之后靠设置里的开关和系统设置改。UI 测试 `PhotoLibraryIntroUITests`。界面测试的资料库默认跳过这页，要测它传 `-MeowverseLibraryIntro`；点了“继续”的测试要答系统弹窗，结束时 `resetAuthorizationStatus(for: .photos)`，否则后面的测试见不到这页。之后也可以在设置 › 存储里用开关更改，代码在 `Meowverse/App/PhotoLibraryLink.swift`。打开时申请相册的“完整访问”（`NSPhotoLibraryUsageDescription`）；只给“仅选中的照片”不算数，因为系统选图器选中的照片并不会因此对 App 可读。打开后：

- 新导入的照片只存一张长边 1024 px 的小预览（`PhotoIngest.linkedMaxPixel`），并多记一个跨设备的 `cloudIdentifier`。只有当相册此刻确实能看到这张照片时才这样存，否则照旧存 2048 px。
- 打开照片时先显示存下来的副本，再从相册按标识读取大图替换上去（允许从 iCloud 下载）。所有“缩小保存”的照片都受益，包括以前按 2048 px 存的。
- 相册里找不到（已删除、换了相册）或暂时取不到（在 iCloud 而没有网络）时，继续显示存下来的副本，并用一行小字说明。
- 关掉开关或在系统设置里收回权限后，一切退回到只看存下来的副本，什么都不会丢。

小预览和 2048 px 的副本用的是同一套 `reducedFrom` 记录，共用核对、备份、恢复和去重流程。App 只向相册要自己导入时记过标识的照片。模拟器实测（系统自带的两张示例照片）：小预览 158 KB 和 372 KB，同两张按 2048 px 存是 569 KB 和 1.17 MB。

`state.json` 当前写 v11，可读取 v1–v11。两种 v8（单房间和多房间）、15×15 的 v9、单房间集成版 v10 均可恢复。v11 保存房间、猫咪、家具归属、照片与家具的关联及相册标识。没有房间信息的旧家具归入第一个房间。旧资料库在下次保存时写 v11，从备份恢复则在替换时写 v11。旧版读到 v11 会提示更新。版本 7 增加调色预设。版本 6：增加收纳箱 `storage`、可以没有照片的家具、墙面摆放（`wall`）和照片板类别。版本 1 至 5 均可读取，下次保存时升级；旧版 App 会拒绝版本 6 的存档和备份。版本 5 增加猫砂盆、窗台和饮水家具类别。版本 3 增加了 `catName`（1–20 个字，新资料库默认 Kitty，已有名字照旧），并允许识别记录的 `mode` 取网页版的 `fixture` / `remote`（只出现在从网页备份带过来的记录上）。版本 2 的内容包含 `favorite`、`note`（最多 2000 个 UTF-16 单位）和 `exifCaptureDate`（导入时从文件读到的日期，之后不再改动），照片可以独立于家具保存。`captureDate` / `captureDateSource` 是界面显示的日期，手动填写后来源是 `user`，清除后回到 `exifCaptureDate`，没有则保持未知。

照片规则：移除或收起家具不删照片；只有“删除这张照片”会删除副本，删除前列出受影响的家具。从版本 6 起删除照片不再带走家具：家具只是少一张，最后一张也删掉后显示「还没有照片」（这一点与 Web 版 `deletePhoto` 不同）。照片也可以只从某件家具移出而留在照片库。

## 猫咪的日常

规则从网页版移植（`src/domain/catRoutine.ts` → `MeowverseCore/CatRoutine.swift`，界面在 `Room/BellaActor.swift`）：猫从门口格 (7,14) 进来，约 2 秒后第一次出发；在家具上休息约 10 秒，在地板上约 4.5 秒；地面速度取决于所选步态。床上睡觉，沙发和长凳上趴着，其他家具旁坐着；刚搬进来的家具是下一个目的地。房间下方有一行状态文字（VoiceOver 读作房间的值）。开了“减弱动态效果”时不走路，改为淡出淡入换位置；房间被导入界面盖住或 App 不在前台时暂停。

摆放规则随之多了两条：家具不能挡住门口格，也不能放在猫走不到的地方。

## 导入界面的呈现方式

导入界面是房间上方的一层原地覆盖，不是系统的全屏弹出。iOS 27 上，照片选择器还在收起时再弹出全屏界面，会得到一个没有背景、和房间叠在一起的界面（第一轮真机反馈的问题）。同理，引导页里点“去添加照片”是等引导页完全收起后才打开选择器。新增界面时不要让两个弹出层重叠。

## 设置、备份、恢复与网页版导入

房间左上角的“设置”里有：占用空间、核对照片、导出备份、从备份恢复、导入网页版备份、清除全部数据、关于与隐私。猫咪的名字和模型在房间顶部的“猫咪管理”里；设置最上面一行“猫咪的名字和模型”会关掉设置、打开猫咪管理。代码在 `Meowverse/App/SettingsView.swift`、`AppModel+Backup.swift`，核心逻辑在 `MeowverseCore` 的 `ZipArchive.swift`、`BackupArchive.swift`、`WebBackupImport.swift` 和 `LibraryStore` 的“Settings, backup, restore”一节。

**App 备份**是一个普通 ZIP（只用“存储”方式，不压缩；没有 ZIP64，所以整个文件要小于 4 GB），“文件”App 可以直接打开：

```
manifest.json               format = "meowverse-ios-backup"，formatVersion = 1，createdAt，appVersion，
                            schemaVersion，photoCount，furnitureCount，state 和每个文件的 path / byteSize / sha256
state.json                  资料库状态，和 App 里保存的完全一样
originals/<sha256>.<ext>    App 里存的每张照片，逐字节原样（版本 8 起可能是缩小的副本）
thumbnails/<名字>.jpg        缩略图（缺了的在恢复时用原图重新生成）
```

导出前会把每张原图重新算一遍 SHA-256，有缺失或不一致就不生成备份。导出的文件先放在 App 的临时目录，由系统分享面板（“存储到文件”等）保存；App 自己不上传。离开设置页或下次启动时，没存走的临时文件会被删掉。

**恢复 / 导入。** App 检查 ZIP 的路径、条目数、长度与偏移，核对清单、`state.json` 和每份照片的 SHA-256，然后在资料库旁的 `<名字>.incoming-<UUID>` 目录暂存完整数据。用户可以查看预览、取消或确认替换。新目录就位后才切换内存状态。文件系统支持原子交换时使用 `RENAME_SWAP`，其他情况在启动时可从暂存的上一份资料库恢复。较新版本的存档须先更新 App 才能打开。

如果本机的状态文件和回退文件都已损坏，启动页也能选择并预览外部备份。确认恢复后，旧目录会保留在本机隔离区，存储用量包含这些文件。之后明确选择「清除全部数据」才会一起删除。

**网页版备份（ZIP 第 6 版）**的对应关系：

| 网页版 | iPhone 版 |
| --- | --- |
| `photos[]` 的原图 | 逐字节原样，SHA-256 同时和清单、照片记录核对；`photoId`、文件名、`importedAt`、`favorite`、`revision` 照搬 |
| `captureDate` / `captureDateSource` | `user` 照搬；`exif` 以这台设备从文件里读到的为准（读不到就是未知，并在预览里说明）；`unknown` 保持未知 |
| `photoDetails[id].note` | 照片的 `note` |
| `cat.displayName` | `catName`（超过 20 个字会截短并说明） |
| `gridRoom.items[]` | 家具：`instanceId`、`modelId`、位置、大小、朝向、配色、名字、标签、`revision` 照搬；不重新套用 iOS 的摆放规则 |
| 家具的 `sources[]` | `photoId`、`origin`、`relationToCat` 照搬；指向的识别记录一起带过来（`mode` 为 `fixture` / `remote` / `manual`，只保留家具类别的物体并重排序号）。对不上的改为手动关联并在预览里说明 |
| 缩略图、预览图 | 不使用，用原图重新生成缩略图 |

不会带过来、并在预览里逐项列出的：经典模式的家具 / 证据 / 提案，自己导入的 GLB 家具和猫咪模型，云端分析的运行、同意记录和没有被家具引用的识别结果，照片的类别修正、自定义标签和“已校对”标记，房间配色主题，以及这个版本没有的家具款式（它们的照片仍然导入）。只要有一张照片在这台设备上解码不了，整次导入就不进行，不会悄悄少一张。早于第 6 版的网页存档需要先在网页版里打开并重新导出。

测试用的网页备份 `MeowverseCore/Tests/MeowverseCoreTests/Resources/web-v6-synthetic.zip`（UI 测试目录里有一份相同的拷贝）是用网页版真正的写入代码生成的，图片全部由脚本画出：

```bash
npx vitest run --config scripts/ios/web-backup-fixture.config.ts   # 在仓库根目录执行
```

## 多个房间和多只猫咪（1.0 隐藏）

**全部免费。** 1.0 没有付费锁、购买入口和完整版（owner，2026-11-22）：家具（含三套主题家具）、主题、照片全流程、备份和同步都直接能用。

**多房间、多猫先隐藏。** 这两项还没做完。`FeatureFlags.severalRoomsAndCats` 是 false：没有「新建房间」「添加猫咪」和相关的话，`model.addRoom`、`model.addCat`（App 里仅有的两个入口）也拒绝所有调用方。`model.offersSeveralHomes` 是唯一的判断，Debug 和演练构建可以用 `-MeowverseSeveralHomes` 打开。已经在存档里的第二个房间、第二只猫（例如从备份恢复来的）照常显示、切换、改名和删除。存档和存储层不知道这个开关。

**多个房间。**

- 存档：家具多了可选的 `roomId`（不写 = 第一个房间），状态多了可选的 `rooms` / `cats`（不写 = 一个没起名的房间、一只叫 `catName` 的猫）。v11 继续省略默认房间和默认猫咪列表。
- 存储层命令：`addRoom` `renameRoom` `removeRoom`，`commitNewFurniture` / `addFurniture` / `restoreFurniture` 多了 `roomId:`，`updatePlacement(roomId:)` 把家具搬到另一个房间。摆放规则按房间各算各的（每个房间 20 件）。测试在 `RoomsAndCatsTests.swift`。
- 规则：最多 8 个房间；第一个房间不能删；删除房间时家具连同照片进收纳箱，房间里有锁定的家具就拒绝；收纳箱全局一个。
- 界面：房间标题变成菜单 `room-switcher`（切换、`new-room`、`open-home`）；“房间”页 `HomeManagerView`（`room-row`、`room-row-menu` › `rename-room` / `remove-room`、`manager-new-room`）；家具详情“更多”里“搬到另一个房间”（优先保留原位，需另找空位时保留家具尺寸和配色；目标房间放不下则留在原房间）；有多个房间时家具库每行写明在哪个房间，筛选里可以只看一个房间，分组标题改成“各个房间里共 n 件”。
- 多房间整理照片时，「未识别」优先放进当前房间的照片板。本房还没有合适的板时，可以新挂一块；手动选择其他房间或收纳箱的目标时，选项会标明位置。
- 当前看哪个房间记在 UserDefaults（按存档目录分开），不进存档和备份；切换房间时场景整个重建（`.id(currentRoomId)`），猫从门口开始。
- UI 测试：`RoomsUITests`（隐藏时没有新建入口、动作处也拒绝；加 `-MeowverseSeveralHomes` 后新建、切换、搬家具、重启后记得房间、删除房间后家具进收纳箱；第二只猫的添加、住在哪里、没有猫的房间、移除）。

**多只猫咪。**

- 存储层命令：`addCat` `renameCat` `setCatRoom` `removeCat`；第一只猫不能移除，它的名字就是 `catName`（原来设置里的改名第十轮并到了这里）。最多 6 只。猫的 `roomId` 为空 = “跟着你”，你看哪个房间它就在哪个房间。
- 界面：“猫咪管理”页（`cat-row`、`cat-row-menu` › `rename-cat` / 住在哪里 / `remove-cat`、`manager-new-cat`，下面是猫咪模型卡）。玩耍时这一页也能打开，改名、换模型照常；添加、移除和住在哪里等玩完（`cats-wait-for-play`）。
- 场景：`RoomSceneView(cats:)` 传入这个房间的猫，第一只是领头的（`RoomSceneController.bella`：状态文字、邀请、玩耍、明信片等待都跟它），其余每只是一个独立的 `BellaActor`（`Companion`），从门口旁边的格子出发、依次晚 1.7 秒动身，自己出发时避开别的猫占着的家具。房间里没有猫时领头的那只隐藏并停住，“互动”不可用。
- 没做：每只猫自己的外观（都用猫咪管理里选的猫咪包，两只猫长得一样）；照片上标是哪只猫、按猫筛选；每只猫的提醒；地板上两只猫的路线互不避让。

## 备份到 iCloud 云盘（2026-11-18 起打开；2026-11-20 由「iCloud 备份」改名）

自动把上面那种 App 备份 ZIP 存进用户自己的 iCloud 云盘（“文件”App › iCloud 云盘 › Meowverse），换手机时一键恢复。不是同步：不合并，恢复走上面同一套预览和整体交换。`App/FeatureFlags.swift` 的 `FeatureFlags.iCloudBackup = true`，正式构建里设置有这一行，空房间有备份时提示恢复，启动和进入后台时按规则备份。把开关改回 false 就整个关掉：没有这一行，不提示恢复，没有前后台钩子，`UbiquityBackupDestination` 也不碰 ubiquity 容器（它自己再检查一次开关）。

测试库（`-MeowverseStore`）不加测试开关时不碰 iCloud，这样手机上跑 UI 测试不会读到、也不会提示恢复真正的 iCloud 备份；要在测试库里走真正的 iCloud 云盘，加 `-MeowverseRealICloud`（`testShippedICloudPathIsHonestWhenSignedOut`：模拟器没有登录 iCloud，状态如实写“没有登录”）。

- 代码：规则（何时备份、命名、清理、推荐哪份）和写入流程在 `MeowverseCore/CloudBackup.swift`，测试在 `CloudBackupTests.swift`；App 侧是 `App/AppModel+ICloudBackup.swift`、`UbiquityBackupDestination.swift`、`ICloudBackupView.swift`（设置页）、`ICloudBackupLifecycle.swift`（启动 / 进入后台、空房间的恢复提示）。
- 文件：`Meowverse-backup-<设备 id>-<UTC 时间>-r<revision>.zip`，旁边一个同名 `.json` 说明文件（数量、大小、SHA-256）。设备 id 是每次安装随机生成的 12 位十六进制，文件名里没有猫的名字或设备名。说明文件最后写，有了它这份备份才算“已核对”。
- 时机：用户同意后才开；房间内容（state 的 SHA-256）和上次成功备份不同才写；自动备份在启动和进入后台时，最多每天一次，失败后一小时内不重试；“立即备份”不受每天一次的限制。空房间从不备份。
- 写入：在 App 临时目录生成 ZIP → 用恢复时的同一套 `BackupArchive.prepare` 完整核对 → 移入目的地（iCloud 用 `setUbiquitous`，不覆盖同名文件）→ 在目的地再算一遍 SHA-256 → 写说明文件 → 只清理这台设备的旧备份，只保留最新 1 份已核对的（2026-11-13 起，原来是 3 份：每份都含全部照片，三份占的 iCloud 空间是三倍）。失败或中断时，已有备份一个字节都不动；说明文件还没下载到本机的备份、最新一份确认已上传的备份，永远不会被清理。开始前先检查：原图总量超过单个 ZIP 上限（约 4 GB）直接报“太大”，本机空余空间不到原图的 2 倍加 200 MB 直接报“空间不够”，都不写任何东西。
- 关闭：以后不再备份，并问要不要删除这台设备存的备份；删除要再确认一次，确认框写明份数、大小和最新日期，只删列出来的那些。
- 测试开关（Debug 和演练构建）：`-MeowverseCloudFolder <名字>` 用 App 容器里的普通文件夹 `Application Support/Meowverse/TestCloud-<名字>` 代替 iCloud 云盘（`FeatureFlags.iCloudBackup` 为 false 时也能用）。UI 测试是 `ICloudBackupUITests`，不需要别的功能开关。

**打开的步骤**（1–4 已在 2026-11-18 做完，5 还没做）：

1. 已完成：开发者账号里注册了 iCloud Container `iCloud.io.github.fengyee.meowverse`，App ID `io.github.fengyee.meowverse` 打开了 iCloud 能力（“Include CloudKit support”，同时覆盖 iCloud 云盘和 CloudKit）并分配了这个容器。实时活动扩展的 App ID（`.pocketcat`）没有 iCloud；第 11 轮起扩展只有 App Group 一项权益（`PocketCatWidget.entitlements`），和 App 的两份权益文件用同一个组，组由 `-allowProvisioningUpdates` 自动登记。
2. 已完成：Meowverse App target 的 Debug 与 Release 配置都有 `CODE_SIGN_ENTITLEMENTS = Meowverse.entitlements;`。`ios/Meowverse.entitlements`：`com.apple.developer.icloud-container-identifiers`、`com.apple.developer.ubiquity-container-identifiers` 都是这个容器，`icloud-services` = `CloudDocuments` 和 `CloudKit`（CloudKit 给以后的同步用，同一个容器）。第一次带权益的构建要增加 App 和扩展的构建号，让系统重新读取 iCloud 文件夹设置。
3. 已完成：`ios/Meowverse-Info.plist` 的根字典里有 `NSUbiquitousContainers`（容器名 Meowverse、文件夹公开给“文件”App、不建子文件夹），`CFBundleURLTypes`、`BGTaskSchedulerPermittedIdentifiers` 保留。
4. 已完成：`FeatureFlags.iCloudBackup = true`；“关于与隐私”和 `public/privacy.html` 写明备份到 iCloud 云盘由系统上传，App 自己仍然不发网络请求。用户打开 iCloud 同步后这句不再属实：关于页、iCloud 备份页和同意页、相册说明页、新手引导改为如实说明（经 Apple 的 iCloud 和自己的设备同步，开发者拿不到数据），按 `model.cloudSyncOn` 切换；没有同步的构建里文案不变。`public/privacy.html` 等同步上架时再改（docs/ICLOUD_SYNC.md §10）。
5. 真机上验证（模拟器不能测真正的 iCloud）：登录 iCloud、打开 iCloud 云盘的手机上打开开关 → “立即备份” → 状态从“正在等系统上传”变成“已上传到 iCloud”，“文件”App 里能看到 Meowverse 文件夹和 ZIP；“文件”App 里把备份“移除下载”后，恢复列表显示“恢复前要先下载”，选它能看到下载进度；下载中关掉网络，看到“没有网络”的提示且房间不变；退出 iCloud 或在设置里关掉 Meowverse 的 iCloud 云盘，状态如实显示；iCloud 存储已满时状态显示“储存空间已满”，旧的已上传备份不被清理；第二台手机（或删掉 App 重装）首次打开空房间时出现“从 iCloud 恢复”，预览 → 确认后家具和原图都在；关闭开关并选择删除，“文件”App 里这台设备的备份消失、其他设备的还在。

## iCloud 同步（2026-11-18，开关关着）

几台登录同一个 Apple 账户的 iPhone、iPad 看同一个家：逐条记录合并，不整包覆盖。和上面的备份到 iCloud 云盘是两件事。规则、记录格式和合并在 [docs/ICLOUD_SYNC.md](../docs/ICLOUD_SYNC.md)，代码在 `MeowverseCore/Sync*.swift`；App 侧在 `Meowverse/Sync/`。

- **开关**：`App/FeatureFlags.swift` 的 `FeatureFlags.iCloudSync`，仓库里是 false：没有设置行，没有生命周期钩子，不建 `CKContainer`，不碰 CloudKit。只有构建设置 `MEOWVERSE_ICLOUD_SYNC=YES`（它打开同名的编译条件）能把它变成 true，见下面的构建命令。同步免费。打开后还要用户在设置 › iCloud 同步里看过同意页、点“打开 iCloud 同步”。
- **传输层**：`Sync/CloudKitSyncTransport.swift`。私有数据库，自定义 zone `Meowverse` 放记录，由 CKSyncEngine 收发；照片文件是 zone `MeowverseFiles` 里不可变的 `MVFile` 记录（`file.<sha256>`，CKAsset），直接读写，下载后核对 SHA-256。CKSyncEngine 自己拉到的记录先写进 `CloudSyncMirror`（磁盘），再写引擎状态，同步周期从那里取，所以 App 中途被杀也不丢。发送只在一轮同步里做，带着上一版的系统字段，别处改过就回来一个冲突去合并，从不覆盖。记录和文件的格式、错误码的含义在 `MeowverseCore/CloudKitSyncCoding.swift`、`CloudSyncMirror.swift`，测试 `CloudSyncTransportCodingTests`。状态文件在 `Application Support/Meowverse/Sync/<库>/`（引擎状态、mirror），同步自己的 `sync-state.json` 仍在库目录里。
- **时机**（`Sync/AppModel+ICloudSync.swift`、`ICloudSyncLifecycle.swift`）：启动、回到前台（距上次不到 20 秒不再来）、改动后 4 秒（改动当时就记下，`captureLocalEdits`）、恢复或清空之后、CKSyncEngine 拉到新东西或收到 CloudKit 推送时、进入后台时还有没发出的改动。所有对 `SyncSession` 的调用排成一队，记录改动和一轮同步不会交叠。导入、恢复、清空进行中不开始新的一轮，等它们结束。失败后 30 秒起翻倍、最多 15 分钟再试；服务器要求等待就按它说的；空间满 15 分钟后再试；没登录等账户变化或回到前台；换了账户、云端数据被删除只等用户选。
- **重新开始的时机**：同步自己的 `sync-state.json` 可能对不上正在用的库时，下一轮之前先 `startOver()`（忘掉同步记得的东西，换一个新的设备 id，按首次开启合并，什么都不删）：库从 `state.backup.json` 或截断的照片导入里恢复打开（`LibraryStore.recoveredFromBackup`，加载时就读，下一次写入它就清掉了）、恢复备份或清空之后、这次安装从没同步过这个库（用旧手机的设备备份装的新手机，会把旧手机的同步文件和设备 id 一起带过来）。最后一种靠 `Application Support/Meowverse/Sync/<库>/this-install` 标记；整个 `Sync` 文件夹（引擎状态、mirror、标记）设了 `isExcludedFromBackup`，不随设备备份迁移。`sync-state.json` 本身在库目录里，是 Core 的文件，这里没有挪。
- **照片文件先于记录**：两个传输层在 `save` 里都会拦下照片记录，直到它指向的副本至少有一份已在云端（`SyncFileGate`），回 `missingFile`，下一轮再发。
- **和别的功能的先后**：用户的新修改不会被盖掉，靠 `applySynced` 的 revision 检查（期间库变了就整轮不写，重新来）；恢复备份之后按首次开启合并，iCloud 里的家会回来，提示里会写明。同步开着时「清除全部数据」多问一句（docs §7）：「只清除这台设备上的家」先关掉这台的同步再清空，云端和其他设备不动；「也删除 iCloud 里的家」再确认一次，先在同步队列里 `deleteHomeInCloud()`（发出全部删除），成功后才清空本机，其他设备同步后也变空；没网络或换了账户时什么都不删、不清空。iCloud 备份和同步可以同时开，导出在库的执行器上一次读完，不会读到一半。
- **测试开关**（Debug 和演练构建）：`-MeowverseSyncFolder <名字>` 用 App 容器里的普通文件夹 `Application Support/Meowverse/TestSync-<名字>` 代替 CloudKit，规则同 CloudKit（版本标签、冲突、按哈希存文件），两个测试库用同一个名字就互相同步；`FeatureFlags.iCloudSync` 为 false 时也能用。`-MeowverseSyncAccount <名字>` 模拟登录的账户，`-MeowverseSyncFault offline|signedOut|quota|full|deleted` 模拟没网络、没登录、放不下照片文件（只挡文件）、iCloud 全满（记录和文件都拒收，和 CKError.quotaExceeded 一致）、iCloud 数据被删除（选“重新上传”后恢复）。测试库不加开关时没有这一行、不碰 CloudKit；`-MeowverseRealICloudSync` 让测试库也走真正的 CloudKit（只在开关打开的构建里有效），用以库名命名的独立 zone，不会并进同一账户里真实的家。UI 测试是 `ICloudSyncUITests`。
- **工程设置**：CKSyncEngine 要 `aps-environment`（development；归档导出时由系统换成 production）和 `UIBackgroundModes` = `remote-notification` 才能收到别处改动的静默推送。这两项**只进带同步的构建**，默认构建（上架用的）的签名和 Info.plist 里都没有，免得审核问一个用不到的推送。做法在 `Config.xcconfig`：`MEOWVERSE_ICLOUD_SYNC`（默认 `NO`）为 `YES` 时，编译条件多 `MEOWVERSE_ICLOUD_SYNC`，App target 的 `CODE_SIGN_ENTITLEMENTS` 换成 `Meowverse-ICloudSync.entitlements`（`Meowverse.entitlements` 加 `aps-environment`，两份的 iCloud 部分要保持一致），`Meowverse-Info.plist` 经预处理（`INFOPLIST_PREPROCESS`）留下 `#ifdef MEOWVERSE_ICLOUD_SYNC` 里的后台模式。iCloud 备份的权益（云盘加 CloudKit）两种构建都有。只在 App target 上，扩展没有权益、不预处理。只加编译条件不加构建设置的 `xcodebuild` 会在 `FeatureFlags.swift` 的 `#error` 停下，不会出一个收不到推送的同步构建；`./build.sh` 见到旧写法会自己补上构建设置。

**构建打开同步的真机版本**（仓库里的默认值不变）：

```bash
cp <主检出>/ios/Local.xcconfig ios/          # 工作树里签名要用，文件不进 git
cd ios && ./build.sh device CURRENT_PROJECT_VERSION=<n> MEOWVERSE_ICLOUD_SYNC=YES
# 旧写法经 build.sh 仍然得到同一个构建：./build.sh device CURRENT_PROJECT_VERSION=<n> 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) MEOWVERSE_ICLOUD_SYNC'
codesign -d --entitlements - --xml build/DerivedData/Build/Products/Release-iphoneos/Meowverse.app   # 有 aps-environment
/usr/libexec/PlistBuddy -c "Print :UIBackgroundModes" build/DerivedData/Build/Products/Release-iphoneos/Meowverse.app/Info.plist   # remote-notification
```

不带 `MEOWVERSE_ICLOUD_SYNC=YES` 的 `./build.sh device` 是默认构建：同一条 `codesign` 里没有 `aps-environment`，`PlistBuddy` 报 `UIBackgroundModes` 不存在，iCloud 云盘和 CloudKit 的权益照旧。编译条件对扩展没有影响，Core 不用它。开发签名的构建连的是 CloudKit 的 Development 环境；TestFlight 和 App Store 连 Production，**上传前要在 CloudKit Console 里把 Development 的 schema（`MVPhoto`、`MVObservation`、`MVFurniture`、`MVRoom`、`MVCat`、`MVHome`、`MVFile` 和它们的字段）部署到 Production**，否则 Production 里第一次保存就会失败。Development 环境里的记录类型是第一次保存时自动建的。

**真机验证清单**（模拟器上没有 iCloud 账户，真正的 CloudKit 只能在真机上测；两台登录同一账户的设备，再加一个别的账户）：见 docs/ICLOUD_SYNC.md 第 11 节的 12 项，另外：

1. 打开开关前设置里没有任何 CloudKit 请求（抓包或看 Console 的 `cloudSync` / `syncTransport` 日志）；同意页数字与房间一致。
2. 第一次打开后，状态从“正在第一次同步”变成“上次同步：…”，没有“等待上传”。CloudKit Console（Development）里能看到两个 zone、各类记录和 `MVFile`。
3. 第二台打开同步后，家具、照片和日期出现，点开照片能看到原图；第一台改名字、移动家具，第二台回到前台或几秒内（推送）看到。
4. 一台在飞行模式下改，状态写“没有网络”和“还有 N 项改动等待上传”；联网后自动发出。
5. 系统设置里退出 iCloud：状态写“没有登录 iCloud”，库不变；登录另一个账户：出现“需要你决定”，两个选择都试。
6. 系统设置 › Apple 账户 › iCloud › 管理储存空间里删除 Meowverse 的数据：出现“同步数据已被删除”，选“重新上传”后另一台照常。
7. 清空资料库、恢复备份后，提示写明会合并回来，另一台的东西没少。
8. 后台时另一台改动，看推送是否把 App 唤醒同步（Console 里 `sync:` 日志）。
9. 用一台已同步设备的加密设备备份恢复另一台（或抹掉后恢复）：第一次启动时 Console 有 `sync started over`，两台之后各改一处都能到对方，没有东西丢失或被当成删除。

## 批量添加、待整理队列与原地编辑（2026-11-11）

- 批量选图时最多三张并发读取，读好一张保存一张，保存后才更新进度和待整理队列。每张请求限时 60 秒，重试一次 120 秒，仍不来算「没有导入」并继续，之后改为逐张读取（`LoadWatchdog`）。停止或失败时已到的照片会保存。给单件家具追加照片走同一条路。离开 App 后导入靠 `ImportBackgroundTime` 继续（iOS 26 起 `BGContinuedProcessingTask`，否则短宽限期）。
- 待整理队列按存档目录记住照片顺序和本批新建照片的初始版本，显示前会滤掉已删除或已放进家具的照片。逐张整理时点「跳过」会撤回本次新导入的照片，再打开下一张；系统相册原图、重复选到的旧照片和已经编辑或关联的记录都保留。点「留在照片库，看下一张」则保留这次导入。旧版待整理队列升级后，跳过也会保留已有照片。
- 进入单张审阅时才选择识别方式。有家具参考照片时比较本机特征（DINOv2，加载失败时 Apple Vision）；参考特征没算完时显示「正在准备识别」和进度，算完再比。批量导入后进度条走完「识别中」才开始整理。特征在后台补齐并存盘，重开时只核对哈希。没有参考照片时运行家具类别识别。
- 原地编辑在 `Room/RoomEditMode.swift`：草稿摆放用现有的 ghost 通道绘制，原家具隐藏，规则仍由 `GridRules.validate` 判断。
- 测试开关 `-MeowverseSyntheticPhoto` 下，房间菜单多一个「合成三张照片」，用来不经系统相册测试批量导入。
- 新测试：`testBatchImportThenSortQueueAcrossRelaunch`、`testLongPressEditsPlacementInTheRoomAndCancelKeepsIt`。

模拟器结果（iPhone 17，Debug，`./test-ui.sh`）：37 条，34 通过，2 条按设计跳过，1 条失败（设置页最大字号审计，见 STATUS.md）。

真机结果（iPhone 15 Pro，Debug，合成照片，2026-11-11）：只跑了四条——`testBatchImportThenSortQueueAcrossRelaunch`、`testLongPressEditsPlacementInTheRoomAndCancelKeepsIt`、`testSeveralPhotosPerFurnitureRemovalKeepsThemAndDeleteIsExplicit`、`testCancelThenConfirmThenRelaunchFindsTheSamePhoto`，全部通过；批量导入那条第一次在安装后首次启动时等首页超时，重跑通过。真实相册多选、拖动手感、触觉强弱和导入耗时还没有人工验证或测量。

## 先摆家具、收纳箱与照片板（2026-11-11，schema 6）

- 核心：`AppState.storage` 存收起的家具；`PhotoFurniture.sources` 可以为空；`Placement.wall` / `CatalogModel.mount` 表示挂墙；内置款 `wall-photo-board` 定义在 `FurnitureCatalog.builtInModels`，不在烘焙的 JSON 目录里。`LibraryStore` 新增 `addFurniture` / `stowFurniture` / `restoreFurniture` / `unlinkPhoto`，都是一次完整保存。猫的接近格由 `CatRoutine.accessCell(of:in:)` 决定。
- 界面：`Import/AddFurnitureFlowView.swift`（类别 → 款式 → 摆放，用 sheet 呈现，中途关闭不保存）、`Import/FurnitureChoiceViews.swift`（分组的类别选择，分组是穷尽 `switch`，新类别不分组就编译不过）、`Room/FurnitureListView.swift`（家具库：搜索、筛选、排序、多选；查询在 Core 的 `FurnitureLibrary.swift`，界面状态在 `App/AppModel+Furniture.swift`）、`Memories/RestoreFurnitureView.swift`。
- 场景：`Room/PhotoBoardArt.swift` 程序绘制照片板；`PlacementEditor` 和房间内编辑都支持换墙和沿墙滑动。
- 家具库是全高的 sheet，不声明 `presentationDetents`（声明了，系统无障碍审计会报裁切）。页面用普通的 `VStack` 而不是 `LazyVStack`：懒加载时，刚被批量收纳的那一行会继续按“选择”模式里的样子显示。删除确认用 `alert`，不挂 `confirmationDialog`（挂在整页上会让最大字号审计报裁切）。
- 新测试：`testFurnitureWithoutPhotoIsKeptAndGetsItsFirstPhotoLater`、`testStowedFurnitureKeepsItsPhotoAndComesBack`、`testPhotoCanBeTakenOffAPieceWithoutDeletingEither`、`testCatalogFlowAndStorageAtLargestTextSizePassAudit`，以及 `WallAndStorageSceneUITests` 两条。

模拟器结果（iPhone 17，Debug，`./test-ui.sh`）：43 条，40 通过，2 条按设计跳过，1 条失败（设置页最大字号审计，见 STATUS.md）。

真机结果（iPhone 15 Pro，Debug，2026-11-11）：只跑了本批相关的五条——`WallAndStorageSceneUITests` 两条和 `testFurnitureWithoutPhotoIsKeptAndGetsItsFirstPhotoLater`、`testStowedFurnitureKeepsItsPhotoAndComesBack`、`testPhotoCanBeTakenOffAPieceWithoutDeletingEither`，全部通过；第一次因手机锁屏没有启动，解锁后重跑。墙面拖动手感、照片板的观感和猫从侧面接近家具的样子还没有人工验证。

## 中英文、提醒与反馈（2026-11-12）

**语言。** 界面有简体中文和英文，跟随系统语言，其他语言显示英文（工程的 development region 是 `en`，2026-11-12 起）。界面文字都在 `Meowverse/Localizable.xcstrings`（源语言中文，每条都有英文，数量用英文复数）。内置的家具款式名和猫咪停留处的名字仍按中文存储和比较，只在显示时经 `CatalogNames.xcstrings` 翻译，所以资料库格式没有变。名字框里保留款式原名就存中文原名（之后随语言切换），用户自己改过的名字原样保存。句子里嵌名字用 `Wording` 里的辅助函数（中文的空格规则、英文的 “the …”）。改了文案后跑：

```bash
./build.sh sim
python3 check-localization.py --stringsdata build/DerivedData/Build/Intermediates.noindex/Meowverse.build/Debug-iphonesimulator/Meowverse.build/Objects-normal/arm64/
```

它在缺英文、过期、待审、数量没有复数、英文里有中文标点，或代码里有没走本地化的中文时失败。UI 测试一律用 `TestLanguage.chinese` 启动；`LocalizationUITests` 用英文走一遍主要页面，页面上出现汉字就失败。

**提醒（设置 › 提醒）。** 首次打开 App 会询问系统通知权限并展示提醒设置。三种提醒都由用户自行开启：猫咪的招呼（每天定时，可再加一次）、历史上的今天（只用已知拍摄日期，晚上 8 点左右）、家具的回忆（约每周一次，点开打开那件家具）。全部由本机 `UNUserNotificationCenter` 安排，通知只有文字、不带照片。计划由 `MeowverseCore/ReminderPlanner` 生成；测试用 `-MeowverseFakeNotifications granted|denied` 代替系统通知中心。

**反馈（设置 › 反馈问题）。** 用系统邮件写给 `bella.meowverse@gmail.com`，发送前用户能看到并修改全部内容，App 自己不发送。诊断信息（可关掉）只有版本、机型、语言与地区、辅助功能开关、照片和家具数量、资料库版本、剩余空间的大致范围、最近 20 次特征向量的耗时中位数（UserDefaults 里只存毫秒数和分析器名）和本次运行的最近日志，不含照片、文件名、便签、猫名和家具名（`MeowverseCore/FeedbackReport` 的测试会核对）。没有邮件账户时退回 `mailto:` 链接，并提供拷贝按钮。

## 互动扩展合入后的模拟器结果（2026-11-10）

iPhone 17 模拟器，Debug 构建，`./test-ui.sh`：18 条 UI 测试，16 条通过，2 条按设计跳过（录演示和测量专用），0 失败。新增的三条是 `testCatTreeInvitationsAndSourceAfterRelaunch`、`testScratchBoardInvitation`、`testRoomPostcardPreviewAndShareSheet`。核心包 135 项单测通过。合入后没有在真机上重跑，下面一节的真机数据是合入前的。

## 互动扩展前的真机实测结果

设备：iPhone 15 Pro，iOS 27.2，无线连接。日期：2026-11-09。自动测试全部使用合成照片。

### 功能

核心包 128 条单测通过。真机上 Debug 构建跑 `./test-ui.sh <udid>`：15 条 UI 测试，11 条通过，4 条按设计跳过，0 失败（约 11.5 分钟）。

| 真机通过的测试 | 覆盖 |
| --- | --- |
| `testCancelThenConfirmThenRelaunchFindsTheSamePhoto` | 取消后房间为空；确认后出现家具；重复导入被认出；彻底退出重开仍是同一张原图、日期和 SHA-256 一致 |
| `testFailedSaveKeepsRoomAndRetryWorks`、`testFailedPhotoOnlySaveCanBeRetried` | 注入一次保存失败：房间和照片库不变，重试成功 |
| `testBackgroundDuringImportThenCancelLeavesRoomEmpty` | 导入中切到后台再回来 |
| `testImportedPhotoCanJoinExistingFurniture` | 新照片加到已有家具 |
| `testPhotoOnlyImportLivesInLibraryAndKeepsEditsAcrossRelaunch` | 只存照片；收藏、便签、日期在重启后还在 |
| `testStoredPhotoBecomesFurnitureLater` | 照片库里的照片之后变成家具 |
| `testSeveralPhotosMoveBetweenPiecesAndBatchActionsInTheLibrary` | 多对多：照片也放进另一件家具、移出、从照片库选回来；照片库里批量收藏并撤销、按家具筛选、批量删除后家具都还在 |
| `testSeveralPhotosPerFurnitureRemovalKeepsThemAndDeleteIsExplicit` | 一件家具多张照片；移除家具保留照片；删除照片需明确确认 |
| `testBackupRoundTripClearAndRestore` | 导出备份 → 清除全部 → 预览 → 恢复，原图逐字节一致 |
| `testLargestTextSizeCompletesTheFlowAndPassesAudit`、`testLibraryAtLargestTextSizePassesAudit` | 最大无障碍字号走完流程并通过系统无障碍审计 |

跳过的 4 条：`testDemoWalkthrough`、`testProfilingWalkOnRunningApp`（只在录演示和测量时运行）；`testWebBackupImportFillsTheRoomAndDamagedFileChangesNothing`、`testSettingsAndRestorePreviewAtLargestTextSizePassAudit`（要从 Mac 上的路径读备份文件，只能在模拟器上跑，模拟器上通过）。

人工结果（用户在这台手机上）：用一张真实的“猫在床上”照片导入，本机识别的候选“还可以”。当时导入界面和房间叠在一起的问题已修复，在模拟器上用真实的系统照片选择器复现并确认修好，真机上还没有用真实选择器复查。

优化构建（Release）已装到手机并能启动；第二轮的功能没有在优化构建上逐项走查。

无障碍审计（`performAccessibilityAudit`）的已知排除，原因写在测试代码注释里：导航栏系统按钮不随字号放大、被禁用或被遮挡元素的对比度、日期行的一个"被裁切"误报、房间里透明点击区的对比度；底部一栏（状态文字和“添加照片”）在最大字号下封顶在 AX2 并提供“大内容查看器”，好让房间本身还看得见。

### Instruments（优化构建，第一轮的数据）

以下是加入猫咪走动、照片库和备份之前测的，**第二轮没有重测**；猫咪动画对内存、耗电和帧率的影响目前没有数据。

冷启动（App Launch 模板）：进程启动到第一帧约 **107 ms**（系统初始化 44 ms，UIKit 初始化 22 ms，首帧 14 ms）。

Points of Interest + Hangs（`measure-flow.sh`，一次录制）：

| 阶段 | 耗时 |
| --- | --- |
| 读取存档 LoadLibrary | 11 ms |
| 存档就绪 → 房间画好 | 约 0.6 s |
| 读取照片 PrepareImport（1200×900 JPEG） | 22 ms |
| 本机识别 Recognize | 127 ms（多次测量 30–127 ms） |
| 保存 Save | 55 ms |
| 打开原图 OpenOriginal | 31 ms |

| 时刻 | 内存占用（phys_footprint） |
| --- | --- |
| 存档就绪，3D 视图创建前 | 13 MB |
| 3D 视图创建后 | 90 MB |
| 房间画好 | 257 MB |
| 识别完成 | 295 MB |
| 摆放页（第二个 3D 视图） | 316 MB |
| 全流程峰值 | **327 MB** |
| 保存后回到房间、打开原图 | 276 MB → 247 MB |

主线程卡顿：启动时一次 **约 320 ms**（创建 RealityKit 视图），打开摆放页和详情页各一次约 105–125 ms。没有超过 500 ms 的卡顿。

没有测的：真实的大尺寸 HEIC/ProRAW 照片、长时间使用后的发热和耗电、存储空间不足。

## 已知限制

- **第二轮的功能只有自动测试的证据，没有人在真机上逐项用过。** 尤其是：猫咪走动看起来是否自然；系统分享面板把备份存到“文件”、再用系统文件选择器选回来这一整段（测试走的是不经过系统面板的演练按钮）；系统照片选择器的多选；真正从网页版导出的备份（测试用的是脚本生成的第 6 版备份，且只在模拟器上跑）。
- **VoiceOver 没有人工走查**（已推后）。每件家具在画面位置上有真实按钮和中文标签，摆放有带标签的方向按钮，自动审计通过。「减弱动态效果」已在模拟器的真实系统开关下核验，真机体验仍待确认。
- **真实照片的识别只有一次人工反馈**（一张“猫在床上”，结论“还可以”），没有成规模的评估。
- 性能数据是第一轮的。内存约 250–330 MB，主要是 RealityKit 本身；启动有一次约 0.3 s 的主线程卡顿。3D 视图持续渲染，现在还多了猫咪动画。
- 备份文件不压缩，整份要小于 4 GB。导入网页版备份是**替换**现有资料库，不是合并。
- 没有从网页版移植的：云端 Claude 识别、自己导入 GLB 家具和猫咪模型的工坊、照片的类别修正和自定义标签。
- 15×15 房间使用固定正交视角，支持在全景与互动近看之间连续缩放，旧房间保留家具原有的行列和墙面位置。
- 界面支持简体中文与英文，提醒按 App 语言生成。
- App 图标由 512 px 放大到 1024 px。
- 照片库按拍摄月份分组，没有按天的时间线，也没有搜索。一次给家具添多张照片时每张单独保存，中途失败会保留已添加的并提示剩余张数。
- 原图在 App 沙盒里，会随 iPhone 备份（"关于与隐私"里已说明）。缩略图去掉了元数据，原图保留。
- 模拟器上 Vision 分类不可用，阴影着色器编译报错；这两项以真机为准。
- 烘焙脚本在 Node 26.7 上运行过，与仓库 `.nvmrc` 不一致。

## 和 Web 版 / 契约的差异（待 lead 确认）

- **识别模式**：iOS 的识别在本机完成，记录的 `mode` 用了 `on_device`；现有契约的 `AnalysisMode` 只有 fixture / manual / remote，需要契约增加 `on_device`。从网页备份带过来的记录保留原来的 `fixture` / `remote` / `manual`。
- **存档格式**：iOS 的 `state.json` 使用自己的 `schemaVersion` 11（含多房间、多猫咪、15×15 坐标及照片与家具库字段）。原生类型统一定义在 `MeowverseCore`，网页契约保留其原有范围。
- **清除手填日期**：Web 版清除后变为未知；iOS 另存了 `exifCaptureDate`，清除后回到照片文件里的日期。便签直接存在照片记录的 `note` 上（Web 版在 `photoDetails`）；没有单独存 `captureDatePrecision`（有日期即为 `day`）。
- **网页备份里的 EXIF 日期**以这台设备重新从文件读到的为准，不照搬网页版记录的值。
- **猫咪大小**是网页版的 1.5 倍（手机屏幕上原尺寸太小）。

## 下一步

1. 你在手机上试一遍第二轮的功能（见上面第一条限制），尤其是备份存到“文件”再恢复。
2. 重测 Instruments（内存、卡顿、猫咪动画的耗电），再决定是否在静止时暂停渲染。
3. 重录演示，加入猫咪走动、照片库和备份。
4. VoiceOver 人工走查（已推后）。
5. 确认上面的契约差异，由 lead 写进 `contracts/`。
6. 发布与 TestFlight 状态见[项目状态](../STATUS.md)。
