# iOS 产品预览图：来源与权利说明

简体中文 | [English](#english)

这里的中英两组、共六张图是完整 Meowverse 原生 iOS App 的开发版截图，供展示项目用途。这些图不作为源码候选包的运行截图；源码公开范围与正式 App 的素材范围分别说明。

## 拍摄时间与版本

本组中文、英文商店底稿由项目的 `StoreScreenshotsUITests` 和 `ios/store-shots.sh` 在 iPhone 18 Pro Max 模拟器（iOS 27.2）中生成，两种语言共用同一拍摄流程，取自 2026-11-15 的开发主线。对应结果包记录的时间是 **2026-11-15 21:55–22:04 UTC（美国东部时间当天下午）**。

这些图晚于 **0.1.0 (3)** 的 2026-11-14 归档，图中部分界面可能还没有进入 TestFlight，不标为任何已上传构建的截图。PNG 本身不提供可独立验证的 App 构建号。

六张文件尺寸均为 **1320 × 2868**，与模拟器截图相同。为减小仓库体积，原始 PNG 经 256 色调色板量化（Floyd–Steinberg 抖动）后重新保存，没有裁切、缩放、重绘界面或拼接额外功能。英文截图是真实的英文 UI，不是把中文截图的文字覆盖为英文。

## 照片与隐私

- `ios-room.png`、`ios-play.png` 及其 `-en.png` 对应图只展示 App 渲染的虚拟场景、猫咪和道具。
- `ios-memories.png`、`ios-memories-en.png` 内的来源图片是程序画出的猫咪与沙发示意图，来自 App 的合成测试导入流程。图上的拍摄日期和导入时间属于该合成测试图片，不代表任何真实猫咪照片的日期。
- 图中猫咪的名字是 App 的默认名 Kitty。这些图没有包含私人原照片、真实相册内容、个人姓名或设备标识。

## 权利范围与第三方署名

这六份 PNG 产品预览图作为展示材料保留权利，不随程序代码许可授予美术复用权。截图的公开展示不表示正式模型、贴图、动画或设计源文件一并开源。此说明不改变适用代码许可证授予的权利；第三方内容已有的许可和权利不受此声明影响。

- 图中的猫是 App 内置的猫咪，网格与毛色由 Meowverse 制作，骨架、蒙皮权重和动作片段来自 Meowverse 的猫咪骨架流程。App 的署名文件仍保留早期模板的来源署名，这里照录：**“3d modelling my cat: Fripouille” — guillaume bolis（2020）**，原作品适用 [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)。[原作页面](https://sketchfab.com/3d-models/3d-modelling-my-cat-fripouille-0ab14bf98e754f8d90fe1bf1c84ca66c) · [作者](https://sketchfab.com/guillaume.bolis)。
- 图中可见的家具（层层猫爬架、云朵贵妃沙发、莲花饮水器、甜甜圈猫窝）是 Meowverse 的原创程序模型；收纳箱、羽毛逗猫棒、地板与墙面，以及合成来源图片，由 Meowverse 的程序在本机生成或绘制。这组截图中没有出现 App 目录里来自 Kenney 或 3D Assets 的 CC0 家具。

本目录只包含展示用截图，没有包含上述正式几何体、纹理或动画源文件。

## 文件校验

来源路径均为原开发项目内的相对路径，用于说明拍摄出处。下表是本目录中压缩后文件的 SHA-256。

| 文件 | 来源 | SHA-256 |
| --- | --- | --- |
| `ios-room.png` | `docs/store-shots/zh-Hans/1-room.png` | `a270aba65fb59813ca94cffbe7efda70ea60c9e6d28e05c171403e417f6a9b04` |
| `ios-memories.png` | `docs/store-shots/zh-Hans/3-furniture-photo.png` | `3671dc73194f73c8bf9e4e03368e751ed762f74ef9b6e55c040ea7cd2e16a9f5` |
| `ios-play.png` | `docs/store-shots/zh-Hans/4-play.png` | `e3d5acce8bf1eadb89fb05d82626fd738fb4bc6154fb58028fade4c22579ee0a` |
| `ios-room-en.png` | `docs/store-shots/en-US/1-room.png` | `643e3af5908f31d19b7916a09d483cd3a3f91175c14325e3ac2d3223e07b3678` |
| `ios-memories-en.png` | `docs/store-shots/en-US/3-furniture-photo.png` | `e84af252543638efd6d3729254644038c9d5c32d423d10af18da235feea10ef2` |
| `ios-play-en.png` | `docs/store-shots/en-US/4-play.png` | `4542f8cd2d4c3ff32a8775dca082c89c0b70b9e754fc1659077edc9ce24726db` |

<a name="english"></a>

## English

These six images, one Chinese and one English set, are screenshots of a development build of the full native Meowverse iOS app, shown to present the project. They are not screens produced by running the source package.

**When and how.** Both languages were captured by the project's `StoreScreenshotsUITests` and `ios/store-shots.sh` on an iPhone 18 Pro Max simulator (iOS 27.2) from the development main line of November 15, 2026. The result bundle records **21:55–22:04 UTC on 2026-11-15**. They are newer than the 0.1.0 (3) archive of November 14, 2026, so some of what they show may not be in TestFlight yet; they are not labelled as screenshots of any uploaded build.

**Processing.** All six files keep the simulator size of **1320 × 2868**. To keep the repository small, the original PNGs were quantised to a 256-colour palette with Floyd–Steinberg dithering and saved again. Nothing was cropped, scaled, redrawn or composited. The English screenshots show the real English UI, not Chinese screenshots with replaced text.

**Photos and privacy.** The room and play images show only the app's rendered scene, cat and props. The source picture in the memories images is a programmatically drawn cat-and-sofa sample from the app's synthetic test import; its capture date and import time belong to that sample. The cat's name is the app default, Kitty. The images contain no private photos, real photo-library content, personal names or device identifiers.

**Rights and attribution.** The screenshots are presentation material; their rights are reserved and are not granted under the code license, and showing them does not open-source the production models, textures, animations or design files. The cat is the app's built-in cat, with mesh and coat made by Meowverse and the skeleton, skin weights and clips from Meowverse's cat rig. The app's attribution file still keeps the credit for the earlier template, reproduced here: **“3d modelling my cat: Fripouille” by guillaume bolis (2020)**, licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) ([model](https://sketchfab.com/3d-models/3d-modelling-my-cat-fripouille-0ab14bf98e754f8d90fe1bf1c84ca66c) · [author](https://sketchfab.com/guillaume.bolis)). The visible furniture (Tiered cat tower, Cloud chaise sofa, Lotus fountain and Donut bed) is original procedural work by Meowverse; the storage chest, feather wand, floor, walls and the synthetic source picture are generated or drawn locally by Meowverse code. No Kenney or 3D Assets CC0 furniture from the app catalog appears in these screenshots. The SHA-256 of each file is in the table above.
