# iOS 产品预览图：来源与权利说明

这里的中英两组、共六张图是完整 Meowverse 原生 iOS App 的历史开发版截图，供展示项目用途。这些图不作为源码候选包的运行截图；源码公开范围与正式 App 的素材范围分别说明。

## 拍摄时间与版本

本组中文、英文商店底稿由项目的 `StoreScreenshotsUITests` 和 `ios/store-shots.sh` 在 iPhone 模拟器中生成，两种语言共用同一拍摄流程。对应结果包记录的开始时间是 **2026-11-13 02:33 UTC（美国东部时间 2026-11-12 晚间）**，PNG 导出时间约为 02:41 UTC。

这些图早于 **0.1.0 (3)** 的 2026-11-14 归档，不标为构建 3 的截图。PNG 本身不提供可独立验证的 App 构建号。界面与完整 App 的后续版本可能不同。

六张文件保持原始 PNG 字节，尺寸均为 **1320 × 2868**，未用图像生成工具重绘界面，也未拼接额外功能。英文截图是真实的英文 UI，不是把中文截图的文字覆盖为英文。

## 照片与隐私

- `ios-room.png`、`ios-play.png` 及其 `-en.png` 对应图只展示 App 渲染的虚拟场景、猫咪和道具。
- `ios-memories.png`、`ios-memories-en.png` 内的来源图片是程序画出的猫咪与沙发示意图，来自 App 的合成测试导入流程。图上日期属于该合成测试图片，不代表 Bella 真实照片的拍摄日期。
- 这些图没有包含私人原照片、真实相册内容、个人姓名或设备标识。

## 权利范围与第三方署名

这六份 PNG 产品预览图作为展示材料保留权利，不随程序代码许可授予美术复用权。截图的公开展示不表示正式模型、贴图、动画或设计源文件一并开源。此说明不改变适用代码许可证授予的权利；第三方内容已有的许可和权利不受此声明影响。

截图拍摄时的 Bella 形体与毛色由 Meowverse 制作；当时所用骨架、蒙皮权重布局和基础片段的来源署名保留如下：

- **“3d modelling my cat: Fripouille” — guillaume bolis（2020）**。原作品适用 [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)。[原作页面](https://sketchfab.com/3d-models/3d-modelling-my-cat-fripouille-0ab14bf98e754f8d90fe1bf1c84ca66c) · [作者](https://sketchfab.com/guillaume.bolis)。Meowverse 进行了对齐、Bella 外观制作及房间姿态、互动和原生资源转换。该署名依据截图拍摄时期的项目记录；后续 App 内置猫咪已继续迭代。
- **Kenney — Furniture Kit（2018 author release）**，适用 [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/)。[素材主页](https://kenney.nl/assets/furniture-kit)。截图中的旧家具来自当时的运行目录，已转换为原生绘制数据。
- **3D Assets — 宠物家具模型**，发布方标注 CC0 1.0，并标注使用 AI 工具制作；Meowverse 进行了尺度、结构和互动适配。[猫爬架](https://3dassets.dev/assets/companion-animals-and-pet-home-cat-tree-e126b0aa) · [软垫猫窝](https://3dassets.dev/assets/companion-animals-and-pet-home-cushion-bed-27a23ea4) · [花瓣饮水机](https://3dassets.dev/assets/companion-animals-and-pet-home-water-fountain-8b38ac17)。
- 图中的羽毛逗猫棒和合成来源图片由 Meowverse 的程序在本机绘制。

本目录只包含展示用截图，没有包含上述正式几何体、纹理或动画源文件。

## 文件校验

来源路径均为原开发项目内的相对路径，用于说明拍摄出处。

| 文件 | 来源 | SHA-256 |
| --- | --- | --- |
| `ios-room.png` | `docs/store-shots/zh-Hans/1-room.png` | `3296d636a0a3a7da5c55b70963c995cfc4daad46c04f4fca2bc7385d7a776803` |
| `ios-memories.png` | `docs/store-shots/zh-Hans/3-furniture-photo.png` | `ff11990f80209d95de9dac6162e3c7d6350f4146448ea27c778ba1b9d21f2173` |
| `ios-play.png` | `docs/store-shots/zh-Hans/4-play.png` | `48e689f51beb6cdd2cc8ef6fa5c2e71f744db6e27bd01a8efd95ef47d7b045c1` |
| `ios-room-en.png` | `docs/store-shots/en-US/1-room.png` | `31825b5d71aa552fc3196a9ef9e91ad43f1a41a36d27ef6b021b1e562f437990` |
| `ios-memories-en.png` | `docs/store-shots/en-US/3-furniture-photo.png` | `bb5f22012d40f22d871ef08b92f67e876822bc9194954929da646450cf0112c2` |
| `ios-play-en.png` | `docs/store-shots/en-US/4-play.png` | `30925c3393a20cbbb3b6888c5ab57b7ac5479c693cc64ff006eb309d1c526321` |
