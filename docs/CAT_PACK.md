# 猫咪包（cat pack）

房间里的猫咪由一个“猫咪包”提供：一份清单加上蒙皮网格与动作片段、静态姿态网格、贴图和可选的高精度检视模型。内置猫咪和用户导入的客制化猫咪使用同一种格式，App 运行时不做减面、绑定或动作制作。

## 文件

| 文件 | 必需 | 内容 |
| --- | --- | --- |
| `cat.json` | 是 | 清单，见下 |
| `ground-gaits.json` | 是 | 一份蒙皮网格、全部关节的逆绑定矩阵和动作片段的关节轨道，见下文“骨架与片段” |
| `sit.mesh.json` `loaf.mesh.json` `sleep.mesh.json` | 是 | 静态姿态网格。单位为房间格，+Y 向上，脚底 y = 0，面向 +Z。版本 1 的包靠它们显示坐、趴、睡，并带互动用的顶点偏移 `targets`；版本 2 的包不带 `targets`，只在骨架播放器加载失败时显示 |
| 清单 `materials` 引用的贴图 | 是 | PNG、JPEG 或 WebP |
| `inspect.usdz` | 否 | 高精度模型，只在“检视模型”界面加载 |
| `preview.png` | 否 | 选择列表里的缩略图 |
| 清单 `tiers` 引用的文件 | 否 | 低档（以后高档）替换的蒙皮网格、姿态网格和贴图，见下文“画质档” |

## 清单

```json
{
  "format": "meowverse.cat-pack",
  "version": 2,
  "id": "bella",
  "name": "Bella",
  "poses": { "sit": "sit.mesh.json", "loaf": "loaf.mesh.json", "sleep": "sleep.mesh.json" },
  "groundGaits": "ground-gaits.json",
  "materials": {
    "coat": { "baseColor": "coat.webp", "roughness": 0.7 }
  },
  "inspect": "inspect.usdz",
  "preview": "preview.png",
  "license": "…",
  "attribution": "…"
}
```

- `id` 只含小写字母、数字和连字符，长度 1–40。
- `materials` 的键是网格部件的 `material` 角色。网格里出现而清单没有的角色用中性灰材质。`sleepBaseColor` 只在睡姿使用，缺省时睡姿沿用 `baseColor`。
- 清单里的文件名都是不含目录的相对名。
- `version` 为 1 或 2，App 拒绝更新的版本。

## 骨架与片段

`ground-gaits.json` 的 `scale` 把骨架单位换成房间格。`joints` 列出每个关节的名字、父关节、静止平移和旋转以及逆绑定矩阵。`parts` 是蒙皮网格，每个顶点最多 4 个影响关节。`clips` 的每个片段有 `duration`（秒）和 `tracks`，每条轨道是一个关节的旋转（四元数）或平移关键帧，按时长均匀分布。

| | 版本 1 | 版本 2 |
| --- | --- | --- |
| `skeleton` | 无 | `"meowverse.cat-rig/2"` |
| 关节 | 恰好 34 个（共用模板骨架） | 20–128 个，内置管线输出 48 个 |
| 片段 | 四种地面步态 | 至少有四种步态和 `sit` `loaf` `sleep` `scratch` `bat_high` `bat_ground` `peek_out` `eat` `drink` `dig`，管线输出 26 个 |
| 片段字段 | `stride` | 另有 `loop`（是否循环，默认是）和 `still`（0–1，减弱动态效果时显示的帧）；非步态的 `stride` 为 0 |
| 坐、趴、睡和互动 | 静态网格加顶点偏移 | 在蒙皮网格上播放片段 |

每个静态姿态或骨架网格最多 128 个部件、65,536 个顶点和 393,216 个三角形索引。一个骨架最多 128 个片段、合计 4,096 条轨道、2,097,152 个标量关键帧分量。片段时长为 0.001 至 3,600 秒，步态步幅为 0.001 至 1,000 个网格单位。

骨架、片段和房间接触点的含义见 [猫咪骨架与动作](CAT_RIG.md)。

## 画质档（2026-11-20）

owner 定：包里只带中档的猫；低档（以后还有高档）按需下载；家具不分档。清单原有的字段（`poses`、`groundGaits`、`materials`）就是中档。多档写在可选的 `tiers` 里，每档只列它替换的文件，共用的不重复：

```json
"tiers": {
  "low": {
    "skin": "low-skin.json",
    "poses": { "sit": "low-sit.mesh.json", "loaf": "low-loaf.mesh.json", "sleep": "low-sleep.mesh.json" },
    "materials": { "coat": { "baseColor": "low-coat.webp", "sleepBaseColor": "low-sleep-coat.webp" } }
  }
}
```

| 字段 | 必需 | 内容 |
| --- | --- | --- |
| `tiers` | 否 | 只读 `low` 和 `high` 两个键；别的键（以后的档、误写的 `medium`）忽略，不报错 |
| `tiers.<档>.skin` | 否 | 这一档的蒙皮网格，格式见下。缺省时穿 `ground-gaits.json` 里中档的蒙皮网格 |
| `tiers.<档>.poses.sit` / `loaf` / `sleep` | 否 | 这一档的静态姿态网格，格式和上限与中档相同。缺哪个就用中档的那个 |
| `tiers.<档>.materials.<角色>` | 否 | 角色必须是中档 `materials` 里已有的。四个字段 `baseColor`、`sleepBaseColor`、`roughness`、`sleepRoughness`。粗糙度没写的沿用中档的值。贴图看这一档换没换网格：换了 `skin` 或任一姿态，网格就带着自己的 UV，中档的贴图贴上去是乱的，所以中档的每个角色都要在这里给自己的 `baseColor`，中档有 `sleepBaseColor` 的角色也要给自己的 `sleepBaseColor`。缺一张，这一档在 App 里就不可用（房间、明信片都用中档），导入的 `.meowcat` 整包拒收，内置猫的烘焙直接报错（`CatPackManifest.textureGap`，`CatPackTierTextureTests`）。只换贴图、不换网格的档，没写的贴图沿用中档的 |

- 每档至少替换一个文件。文件名和上面的规则一样（不含目录、扩展名对），并且不能和中档的任何文件、`cat.json` 或另一档的文件同名：所有档的文件放得进同一个文件夹。
- 骨架、逆绑定矩阵和全部动作片段只在 `ground-gaits.json` 里一份，各档共用。低档的网格必须绑在中档同一副骨架、同一个绑定姿态上。
- 贴图预算按档算：房间一次只穿一档，中档和低档各自不超过 16,777,216 个源像素。
- `version` 不变（仍是 2）。旧版本的 App 忽略 `tiers`，照样显示中档；没有 `tiers` 的旧包在任何画质下都用中档（Core 测试 `CatPackTierTests`）。

**蒙皮文件**（`skin`）：

```json
{
  "format": "meowverse.cat-skin/1",
  "skeleton": "meowverse.cat-rig/2",
  "jointNames": ["…", "…"],
  "parts": [ … ]
}
```

`parts` 和 `ground-gaits.json` 的 `parts` 完全同一种格式（每顶点 4 个影响，`jointIndices` 指中档骨架的关节，上限相同）。`skeleton` 必须和中档的一样，`jointNames` 必须按顺序等于中档 `joints` 的名字，否则拒收（导入时报 `badMesh`，房间里退回中档）。从低档管线产出的完整 rig 文件生成：`jq '{format: "meowverse.cat-skin/1", skeleton, jointNames: [.joints[].name], parts}' low-ground-gaits.json`。

**放在哪里**：

- 内置猫：App 包里的 `<id>-cat.json` 带 `tiers`，但这一档的文件**不进** App 包。每只猫每档一个 Apple 托管的资源包（asset pack），ID 是 `cat-<id>-<档>`（例如 `cat-bella-low`），文件放在资源根目录的 `cats/<id>/<档>/<文件名>`，文件名不带 `<id>-` 前缀，下载策略 `onDemand`。烘焙脚本（`scripts/ios/bake-ios-assets.mjs`）把 `assets/cats/<id>/cat.json` 的 `tiers` 原样写进 App 里的清单（并按上面的规则检查文件名），不拷这些文件；`--asset-packs <目录>` 另把每档整理成资源包（`scripts/ios/cat-asset-packs.mjs`：`root/cats/<id>/<档>/` 加 `manifests/cat-<id>-<档>.json`），各档的文件从 `--tier-source <目录>/<id>/<档>/` 读，不给时从 `assets/cats/<id>/` 读。目录必须在仓库外或被 git 忽略（`ios/build/asset-packs`）。打包、本机服务、上传见 ios/README.md「画质」和 [TestFlight](TESTFLIGHT.md)「猫的低档资源包与下载扩展」。`.meowcat`（`build-pack.mjs`）暂时仍不带 `tiers`：它得把各档文件一起打进 zip，这一步没做。
- 导入的 `.meowcat`：各档文件和其余文件一起放在 zip 根目录，导入时一起校验、一起装好，不用下载。上限仍是 32 个条目。

**怎么选**：房间按「解析后的画质档」（自动已经按内存和发热定好）要同名的猫档：这一档在包里、文件已就绪就用，否则用中档；「高」在还没有高档时就是中档。切换画质、下载完成或失败时，房间原地换网格，猫的位置、朝向和正在做的事不变（和换猫包是同一个办法，UI 测试 `CatTierUITests`）。换的那一下猫会消失到新网格读完（几百毫秒，没在真机上量）。某一档的文件读不出来时，这一档记为不可用，回到中档，到下次换画质或重开 App 再试。「查看 3D 模型」只读 `inspect.usdz`，和档无关；明信片用现有最好的一档（有高档就用高档，否则中档，永远不用低档）；「放到桌上看看」和房间用同一档。

## 按需下载（2026-11-20 调研）

规模：每只猫每档约 2–4 MB，八只猫，一档 8 个资源包，加上高档也只有 16 个。

**结论：用 Background Assets（Managed，Apple 托管），不用 On-Demand Resources。** 依据（2026-11-20 用 curl 读 Apple 文档 JSON 和 App Store Connect 帮助页）：

- On-Demand Resources 已弃用：`NSBundleResourceRequest` 在 iOS 27 标为 deprecated，说明是 “Use Background Assets instead.”（`documentation/foundation/nsbundleresourcerequest`）。App Store Connect 帮助「On-Demand Resources size limits」写明 iOS 27 起弃用、以后移除，并且「2027 年初起，App Store Connect 不再接受从没用过这一功能的新 App 或旧 App 上传含 ODR 的构建」。Meowverse 从没用过 ODR，属于后者。它的大小限制我们碰不到（iOS 18 起每个资源包 8 GB、托管总量 70 GB，更早的系统 512 MB 和 20 GB；同时在用的 iOS 18 起不限，更早 2 GB），但很快就传不上去了。
- Background Assets 的 Apple 托管：`AssetPackManager`（iOS 26 起），每个 App 最多 200 个资源包、合计 200 GB（帮助页「Apple-hosted asset pack size limits」），TestFlight 和 App Store 都能用；资源包和构建分开上传（Transporter、`altool --upload-asset-pack`、API），给外部测试要先过一次资源包的 TestFlight 审核，同一资源包一次只有一个版本在外部测试；测试者要用有测试资格的 Apple 账户登录设备，不支持沙盒账户（帮助页「Test Apple-hosted asset packs」）。更新资源包不用发新构建。
- 本机先测：`xcrun ba-package` 打包，`xcrun ba-serve` 起模拟服务器，要自签根证书并在设备上信任，设备开发者模式里「Background Assets Testing」填服务器地址（文章「Testing asset packs locally」）。
- 接入需要（文章「Downloading Apple-hosted asset packs」）：一个下载扩展 target（模板 Background Download，类型选 “Apple-Hosted, Managed”）；App 和扩展共用一个 App Group；App 的 Info.plist 加 `BAAppGroupID`、`BAHasManagedAssetPacks = YES`、`BAUsesAppleHosting = YES`，其余 BA 键都不写。新扩展也要带自己的 `PrivacyInfo.xcprivacy`（见 tech-craft「发版」）。2026-11-20 接好了：扩展是 `ios/MeowverseAssets/`（ExtensionKit，`StoreDownloaderExtension`，什么都不改写；Xcode 模板生成的 Info.plist 只有 `EXExtensionPointIdentifier = com.apple.background-asset-downloader-extension`），部署目标 iOS 26；App Group 用 App 已有的 `group.<套装 ID>`（模板的默认值就是它；`Config.xcconfig` 的 `MEOWVERSE_APP_GROUP`），所以 App 的两份权益文件都不用改，iCloud 同步和普通构建一样。
- 我们的最低系统是 iOS 18，`AssetPackManager` 要 iOS 26：iOS 18–25 的设备一直用中档。

**做到了哪一步**：

- Core：`CatTierDownloads`（`CatPackTiers.swift`）是下载状态机：未下载 → 下载中（带进度）→ 已就绪 / 失败。资源包已在设备上就直接就绪；下载完要核对清单列的每个文件都在，缺一个就是失败；`ensure` 不重试失败，`retry`（换画质、重开 App 时）才重试；取消或重新开始后，迟到的旧结果被丢掉（按代号核对），不会盖掉新状态。传输层是协议 `CatTierTransport`，测试用替身（`CatPackTierTests`）。
- App：`BackgroundAssetsCatTierTransport`（`App/CatTierSupport.swift`）按上面的 ID 和路径调 `AssetPackManager`（`ensureLocalAvailability`、`statusUpdates`、`url(for:)`）。Info.plist 里 `BAHasManagedAssetPacks` 为 YES 且系统是 iOS 26 起时用它（现在所有构建都是 YES），否则用 `UnavailableCatTierTransport`：低档立即记为失败，猫一直是中档。
- 设置 › 画质：画质要的档猫还穿不上时，「画面」一节和画质页的页脚多一句：下载中「正在准备简化的猫咪模型，准备好之前先用标准模型」，失败「暂时下载不了，先用标准模型。换一次画质或下次打开 App 时会再试」，iOS 26 以前「这台设备的系统版本用不了」（`AppModel.catTierNote`）。房间里不提示。
- **模拟器上跑通过**（2026-11-20，iPhone 18 Pro、iOS 27.2）：`ba-serve` 在本机 `https://localhost:54753` 上服务八只猫的真低档 `cat-<id>-low`（`ios/ba-local.sh stage` 现做），App 选低档后经 Background Assets 下载、核对文件，猫原地换成低档：当天八只都下载并穿上过一次，系统放进 staging 的文件和服务的逐字节相同；留在仓库里的测试只走 Bella（`CatTierUITests.testLiveAssetPackDownloadFromALocalServer`）：下载 → 低档，低画质下做的明信片上是中档，重开 App 直接是低档；服务停掉时是中档加失败的说明。步骤见 ios/README.md「画质」。模拟器认 Development Overrides：开发安装的 App 读 `com.apple.backgroundassets.managed` 里的 `MBAURLOverride`（设备上就是「设置 › 开发者 › Background Assets Testing」那一项写的，模拟器没有界面，用 `simctl spawn … defaults write`）。不设它时，App 去 App Store 取清单（模拟器上是 404），也就是中档加失败的说明。
- **没验证**：真机（要 Mac 局域网地址的证书、在手机上信任根证书、开发者模式里填 URL Override）；没有上传过资源包，TestFlight 和 App Store 上都没跑过；低档在真机上的样子、帧时间和省下的内存都没量过。资源包的 manifest 由 `cat-asset-packs.mjs` 生成：`{"assetPackID": "cat-bella-low", "downloadPolicy": {"onDemand": {}}, "fileSelectors": [{"directory": "cats/bella/low"}], "platforms": ["iOS"], "sourceRoot": "../root"}`，`xcrun ba-package evaluate` 认得它，列出的路径就是 App 要的那几个。
- 测试开关（DEBUG 和演练构建）：`-MeowverseCatTiers <ready|hang|fail|after:<秒>|live|live-kept>`。内置猫都有真低档，清单不改。`live` 走真的 Background Assets 下载 `cat-<id>-low`（先删掉上次下好的，每次从未下载开始），`live-kept` 保留上次下好的；配本机 `ba-serve` 就是真低档。其余几种不下载，用猫自己的中档文件按清单里低档的文件名顶替（睡姿贴图顶替睡姿贴图，所以不缺贴图），下载分别是：已在设备上、永远下不完、半秒后失败、若干秒后下完；只用来测选择、回退和说明，看不出低档的样子。

## 存放位置

- **内置**：打进 App 包，资源名为 `<id>-<文件名>`，例如 `bella-cat.json`、`bella-sit.mesh.json`。
- **导入**：`Application Support/CatPacks/<id>/<文件名>`。分发形态是把上述文件放在根目录的 zip，扩展名 `.meowcat`。

导入时校验清单格式和版本、必需文件、网格与片段能否解码，以及关节数和必需片段是否齐全（按上表），每条轨道的关节和关键帧数是否有效。上限是单文件 40 MB、总计 120 MB、最多 32 个条目，贴图最长边 8192 像素。同一包的房间材质贴图按不同文件累计，最多 16,777,216 个源像素。房间显示时最长边采样至 2048 像素，设置列表预览采样至 132 像素。检视用 USDZ 仍单独遵守文件体积上限。校验全部通过后才一次性写入，失败不留任何文件。内置猫的 `id`（如 `bella`）不能被导入的包覆盖；重复导入同一个 `id` 会先询问是否替换。导入的包只保存在本机，不随备份导出。

zip 里文件必须直接放在根目录，不能带文件夹或 `__MACOSX`、`.DS_Store` 条目。管线用 `zip -j -X` 打包；访达的“压缩”做出来的 zip 会被拒绝。

## 在 App 里

“猫咪管理 → 猫咪模型”（房间顶部的「猫咪」；第十轮前在设置里）按屏幕宽度排成卡片网格（iPhone 竖屏两列，更宽时更多列，无障碍字号一列），列出内置和已导入的猫。点内置的猫先打开她的角色卡（剪影、名字、性别、品种、一句「<名字>的铲屎官赞助了我们的喵空间！」、性格小标签、小趣事（写好了才显示，没写时整行不出现）和「查看 3D 模型」），卡底的「就选它」才切换，关掉卡不改变选择；角色卡的数据和内置猫的显示名在 App 端的 `ios/Meowverse/App/CatProfiles.swift`，不在清单里（清单的 `name` 保持不变）。导入的猫没有角色卡，点一下就切换，房间里的猫立刻换成新模型。“导入猫咪模型…”选择 `.meowcat` 文件，只在 Debug 和演练构建里有（owner，2026-11-20：普通用户拿不到这种文件；TestFlight 和商店的正式构建都没有这一行，以前导入的猫照样列出、能删）；导入的猫在它那一行的“…”菜单里删除；删除正在使用的猫会回到 Bella。清单带 `inspect` 时出现“查看 3D 模型”，可以单指旋转、双指缩放查看高精度模型。

新增内置猫：把来源文件夹放到 `assets/cats/<id>/`，把 `<id>` 加进 `scripts/ios/bake-ios-assets.mjs` 的 `BUILT_IN_CATS` 和 `ios/Meowverse/App/CatPackLibrary.swift` 的 `builtInIDs`，再运行烘焙。

## 生产

见 [猫咪骨架与动作](CAT_RIG.md)。旧的 [v1 管线](CAT_PIPELINE.md) 产出版本 1 的包。

低档（`tiers.low`）：`build-pack.mjs --low` 把重建流水线的 `build_low/` 和中档一起打包；已经装进 App 的猫用 `tier-pack.mjs`，不动中档，只出低档的文件和加了 `tiers` 的清单。源文件夹的 `cat.json` 里，低档写成 `"tiers": {"low": {"rigged": "low-rigged.glb", "midSha256": "…", "materials": {…}}}`，`pack.mjs` 从它生成 `low-skin.json` 和三个姿态网格；低档的文件不在 `packFiles` 返回的 `files` 里，另放在 `tierFiles`。命令和拒绝打包的条件见 [CAT_LINE.md](CAT_LINE.md)「低档进猫包」。
