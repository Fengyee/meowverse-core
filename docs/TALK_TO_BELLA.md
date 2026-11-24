# Talk to Bella（语音指令 → 猫咪动作）

第十二轮的功能。owner 2026-11-20 提出：房间角落放一个 2D 猫咪头像按钮，点一下说一句话，猫咪用动作回应，不说话。工程上是一个「自然语言 → 预设动作」的控制器，不是聊天机器人。

## 用户看到的

1. 房间右下角、底部控件上方，浮着一个像素猫头像（复用口袋猫的头像画法）。
2. 点一下开始听，头像进入「在听」状态；说完自动停（约 1.2 秒静音，或最长 8 秒），也可以再点一下停。
3. 头像「想一想」，然后：
   - 听懂且房间能做到：头像点一下头，猫咪去做（走到沙发、跳上去、趴下）。
   - 听不懂、或房间做不到：头像歪头，旁边出现一句很短的说明（例如「房间里还没有沙发」），猫咪不动。
4. 猫咪全程不说话、没有语音回答、没有聊天记录。

## 管线（各段只做一件事）

```
BellaVoiceButton（2D 头像，只管外观）
  → SpeechListener（Speech 框架，强制设备上识别）       文字只在内存里
  → BellaCommandRules.match（固定说法，快）
  → 没匹配上时：BellaIntentModel（Foundation Models，iOS 26+，设备上）
  → BellaCommand（契约里的枚举，不是自由文本）
  → BellaCommandResolver.resolve（对着这间房的家具和通路判断能不能做）
  → BellaPlan → 和「互动」菜单完全相同的调用（CatInvitation / RoomPlaySession / 新的 CatSummon）
  → BellaActor 走路、跳、做动作
```

**模型不直接控制三维运动。** 模型只能选出一个 `BellaCommand`；怎么走、能不能跳、什么时候趴下，都是已有的 `CatRoutine` 和 `BellaActor` 决定的。

## 契约（lead 所有，改动经过 lead）

- `ios/MeowverseCore/Sources/MeowverseCore/BellaCommand.swift`：`BellaCommand`、`BellaCommandSource`、`BellaUnderstanding`、`BellaPlan`、`BellaRefusal`。
- `BellaCommandRules.match(_:catName:) -> BellaCommand?`、`BellaCommandRules.nameMayBeAWord(_:catName:) -> Bool`、`BellaCommandResolver.resolve(_:items:catalog:from:)`、`BellaCommandResolver.comeHereCell(items:catalog:from:)` 的签名。
- `RoomSceneView.summon: CatSummon?`、`BellaActor.come(to:)`、`BellaVoiceButton(state:accessibilityLabel:accessibilityValue:action:)`、`BellaVoiceState` 的签名。
- `FeatureFlags.talkToBella`、`NSMicrophoneUsageDescription`、`NSSpeechRecognitionUsageDescription`（`project.pbxproj` 和 `InfoPlist.xcstrings`）。

### 指令和房间的对应

| 说法（举例） | `BellaCommand` | 解析后 |
| --- | --- | --- |
| 去沙发上躺着 / lie on the sofa | `.visit(.loaf, .sofa)` | 沙发上提供 `loaf` 的站点；沙发没有 `loaf` 时按「相近动作」表退到 `sleep`、`sit` |
| 去睡一会儿 / take a nap | `.visit(.sleep, nil)` | 房间里任何提供 `sleep` 的可达站点，优先床、猫窝 |
| 喝水去 / go drink | `.visit(.drink, nil)` | 提供 `drink` 的站点（水碗类） |
| 去磨磨爪子 | `.visit(.scratch, nil)` | 猫抓板、猫爬架 |
| 躲起来 | `.visit(.hide, nil)` | 猫窝、纸箱等 |
| 去上厕所 | `.visit(.dig, nil)` | 猫砂盆 |
| 去玩一会儿 / play | `.play(treat: false)` | 先找房间里任何提供 `play` 的可达站点（玩具类排在前面）；没有就开始一次玩具互动（毛毡小鼠，自动放到最近的空地）。模型给出的 `.visit(.play, nil)` 也照这样处理 |
| 吃点东西 / 吃零食 | `.visit(.eat, nil)` 或 `.play(treat: true)` | 有提供 `eat` 的可达站点就去，没有就开始喂零食；说到「零食」直接 `.play(treat: true)`（小鱼饼干） |
| 过来 / 过来让我摸摸 / come here | `.comeHere` | 离镜头最近、走得到的地面格子（镜头在 +x、+z 方向，即房间前角），坐下面向镜头 |
| 给我唱首歌 | `.unsupported` | 不动，歪头 |

- 「相近动作」：`loaf → sleep → sit`，`sleep → loaf`，`sit → loaf`。只在指定了家具、但那件家具没有原动作时退一步；没有指定家具时只找原动作。
- 同类家具有多件时：先选从门口出发路最短的；平手时按 `instanceId` 排序，保证同样的房间同样的结果。
- 「沙发」这类说法和 `FurnitureCategory` 的对应（中英文同义词）在 `BellaCommandRules` 里维护，模型的提示词也只列这间房里实际有的类别。
- 解析不到时返回 `BellaRefusal`：`.notUnderstood`、`.noSuchFurniture(类别)`、`.blocked`。每种对应一句短说明，不移动猫。

### Core 实现后定下的细则（2026-11-20，lead）

- 相近动作按「家具上有没有这个动作」判断，不按「到不到得了」：沙发有 `loaf` 但被挡住时返回 `.blocked`，不改去别的地方睡。说明要如实。
- 只说家具（「去沙发」）时，默认动作是 `CatRoutine.action(on: 类别)`：沙发 loaf，床 sleep，猫爬架 sit。
- `.play(...)` 和「eat 退到零食」都要求有能放下东西的空地（与 `placeNext` 一样，门口除外），没有就 `.blocked`。
- App 调 `resolve` 和 `comeHereCell` 时固定传 `.atEntrance`（默认值），与菜单的判断完全一致；「最近」也从门口算。
- 固定说法只要有一个字不认识、有否定词、一句话里有两种家具或两种动作，就返回 nil，交给模型。「Bella / 贝拉」总被当作称呼去掉，改名后也一样。
- 词表在 `BellaCommandRules.swift` 的 `furnitureWords` 和动作词表里，是这份说法表的唯一来源。

### 接线后补充（2026-11-20，lead）

- 新的字符串表放在 `ios/Meowverse/` 顶层（`TalkToBella.xcstrings`）：`check-localization.py` 只扫顶层。
- `.blocked` 不带类别，提示用指令里的目标类别（「去沙发的路被挡住了」），没有目标时说「去那里的路被挡住了」。
- UI 测试加 `-TalkToBellaRulesOnly`（只在 DEBUG），不调模型，结果可重复；有 Apple 智能的模拟器否则会走模型。
- 进行中的请求在这些时候作废：打开互动或家具、编辑、换装、导入、AR、退到后台、离开或切换房间、手动结束玩耍。

### QA 复核后补充（2026-11-20，lead）

- 说「我饿了」「我困了」「I want to sleep」这类说主人自己的话不是指令：固定说法返回 nil，交给模型或当作没听懂。
- 拒绝的说明必须真实：房间里确实没有这类家具时才说「房间里还没有沙发」；有这件家具但它不提供这个动作（包括装饰件）时，说「沙发上不能这样做」之类。由 App 按房间里有没有这个类别来区分，`BellaRefusal` 不变。
- 模型的生成结构允许所有家具类别；提示词只列这间房里有的。房间里没有的、装饰件，都由解析器挡住，不会让猫乱走。
- 猫的名字恰好是词表里的词（「饼干」「盒子」「Box」）、又出现在句首或句尾时，名字可能是在叫猫，也可能就是那样东西。两种读法得到的指令不同时，`BellaCommandRules.nameMayBeAWord` 返回 true，App 改问模型；模型的说明里写了猫的名字。模型不可用或没给出答案时，仍用固定说法的结果（名字当称呼）。不会让猫做没说过的事。

### 正在做别的事时

和「互动」菜单一致：**新指令总是接替旧的**。正在玩玩具或喂零食时，新的到家具指令先结束这次互动（`playSession.end()`）；`.play` 指令会开始新的互动。不排队，不拒绝。多只猫时只对领头的猫说。

## 隐私（不能破坏）

- 识别强制在设备上：`SFSpeechRecognizer` 的 `requiresOnDeviceRecognition = true`；设备不支持设备上识别时，头像显示「不可用」，点按打开「互动」菜单，不退回服务器识别。
- 声音和文字只在内存里，不写文件、不进日志（`Logger` 里不出现识别文字）、不进存档和备份、不上传。
- Foundation Models 只在 `SystemLanguageModel.default.availability == .available` 时调用；不可用时只用固定说法，没匹配上就当作没听懂。不假装模型分析过。
- 结果的来源（`BellaCommandSource`）保留，调试界面和测试能分清是固定说法还是模型选的。
- 隐私页（`public/privacy.html`）要加一段说明，草稿放在分支里；发布是对外动作，由 owner 决定。

## 不在第一版里

聊天记忆、语音回答、多步骤计划、主动对话、唤醒词、后台监听、Siri / App Intents。

## 测试

- Core：`BellaCommandRules`（中英文、带猫名、标点、空白、听错字的常见形式）、`BellaCommandResolver`（每种 `BellaCommand` × 有/无家具 × 通路被挡）。`swift test --no-parallel --filter Bella`。
- App：UI 测试用启动参数 `-TalkToBellaTranscript "<一句话>"` 代替麦克风（只在 DEBUG 构建生效），点头像后走完整条管线：到沙发、过来、听不懂三条。
- 模拟器上 Foundation Models 可能不可用，模型那一段在真机上验证，并记录设备和系统版本。
