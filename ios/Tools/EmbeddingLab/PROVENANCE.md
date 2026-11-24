# App 里的 DINOv2 模型

`ios/Meowverse/Resources/Models/DinoV2ViTB14Reg.mlpackage` 是照片找家具用的模型，代码在
`ios/Meowverse/App/DinoPhotoEmbedder.swift`（analyzer `dinov2.vitb14reg.int8.meanpatch`，
revision 1）。Xcode 把它编译成 `DinoV2ViTB14Reg.mlmodelc` 放进 App。这份说明放在这里而不是
模型旁边，因为 `ios/Meowverse/` 下的文件会全部进 App。

- 来源：Hugging Face `facebook/dinov2-with-registers-base`，commit
  `a1d738ccfa7ae170945f210395d99dde8adb1805`（Meta AI 的 DINOv2 ViT-B/14，带 4 个 register）。
- 许可：Apache 2.0，版权归 Meta Platforms, Inc. 及其关联公司。许可证全文和改动说明以
  `Resources/Models/DINOv2-LICENSE.txt` 随 App 发布，在“设置 › 关于与隐私 › 开源与素材 › DINOv2”里能看到。
- 改动：转成 Core ML ML Program（iOS 18），8 位权重（逐通道对称线性）；位置编码插值到 224 px
  后存成常量；像素缩放、ImageNet 均值和方差、patch token 取平均（不含 CLS 和 register）都放进
  模型里。输入 `image` 是 224 × 224 RGB，输出 `embedding` 是 768 个浮点数，没有归一化。
- 做法：按 `README.md` 建环境（`requirements.txt` 钉了 torch 2.15.0、transformers 5.23.0、
  coremltools 9.0，Python 3.12，Apple silicon 的 macOS），然后
  `"$PY" convert.py --model base-reg --out "$OUT/models" --variants int8`，把
  `dinov2-with-registers-base-224-mean-int8.mlpackage` 复制成 `DinoV2ViTB14Reg.mlpackage`。
  输出逐字节可复现，重做必须得到这两个哈希：

  | 文件 | SHA-256 |
  |---|---|
  | `Data/com.apple.CoreML/model.mlmodel` | `40ebee500e44084b3e92ed0fe6ae000c8e33e4fa008a0609b42f28c3be5d18b9` |
  | `Data/com.apple.CoreML/weights/weight.bin` | `a032ac0fc3400a85880bfb0cb8421f39674ec492e1cb3403c1a27cd7795c5845` |

  `scripts/check-privacy.mjs` 的 `nativeArt` 登记的是同样两个哈希。`Manifest.json` 是文本，
  item id 固定。
- 测量（保真度、大小、耗时、家具指标、App 里的常数）：`ios/MeowverseCore/RECOGNITION_NOTES.md`。

换模型：重新转换，复制进去，在同一个提交里改这里和隐私检查的哈希，`DinoPhotoEmbedder.revision`
加一，再用 `recognition-eval --coreml` 重新量阈值。
