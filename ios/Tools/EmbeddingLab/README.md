# 图像向量实验（Mac）

把 DINOv2 转成 App 能直接用的 Core ML 模型，再拿你自己分好类的照片检查：转换后的向量和 PyTorch 原版是否一致，用 `recognition-eval` 打分时家具匹配的成绩还在不在。

为什么是 DINOv2、为什么取 patch token 的平均：见 `ios/MeowverseCore/RECOGNITION_NOTES.md` 的 2026-11-17 一节。

App 现在用的是 ViT-B/14 带 register、int8 这一个：来源、哈希和重做的命令见 `PROVENANCE.md`，App 里的代码是 `ios/Meowverse/App/DinoPhotoEmbedder.swift`。

模型的约定（App 照此调用）：

- 输入 `image`：224 × 224 RGB。整张照片压成正方形（不裁切）。App 从 512 px 缩略图用 PIL 的 bicubic（逐字节移植）缩到 224。
- 输出 `embedding`：一个向量，ViT-S 384 个数、ViT-B 768 个数，没有归一化。比较前缩放到单位长度。
- 0–255 → 0–1、ImageNet 的均值和方差、去掉 CLS 和 register token 后对 patch token 取平均，全在模型里。
- 位置编码按 224 px 预先插值好，作为常量放进模型。换输入尺寸要重新转换。
- 最低系统 iOS 18（App 的部署目标），ML Program 格式。

## 准备环境

环境放在仓库外面：

```bash
uv venv "$TMPDIR/embedding-lab/.venv" --python 3.12
uv pip install --python "$TMPDIR/embedding-lab/.venv/bin/python" -r ios/Tools/EmbeddingLab/requirements.txt
PY="$TMPDIR/embedding-lab/.venv/bin/python"
```

还需要 Xcode（`xcrun coremlcompiler` 用来编译模型、量编译后的大小）。

## 会下载什么

- Python 包：从 PyPI，版本钉在 `requirements.txt`。
- 模型权重：第一次运行时从 Hugging Face 下载，存在 `~/.cache/huggingface/hub`（设 `HF_HOME` 可以换地方），不进仓库。版本钉在 `common.py` 的 `MODELS`：

  | 键 | Hugging Face 仓库 | 大小 | 许可 |
  |---|---|---|---|
  | `small` | `facebook/dinov2-small`（ViT-S/14） | 约 88 MB | Apache 2.0 |
  | `base-reg` | `facebook/dinov2-with-registers-base`（ViT-B/14，4 个 register） | 约 350 MB | Apache 2.0 |

  DINOv2 由 Meta AI 发布（github.com/facebookresearch/dinov2）。转换出的模型元数据里写了来源、版本和许可。

## 运行

所有输出都必须在仓库和任何 Git 检出之外，否则脚本拒绝写（和 `recognition-eval` 同一条规则）。下面用 `$TMPDIR/embedding-lab`。

```bash
OUT="$TMPDIR/embedding-lab"; mkdir -p "$OUT/models" "$OUT/vectors"
cd ios/Tools/EmbeddingLab

# 1. 转换：默认 Float16、8 位线性量化（int8）、8 位调色板（pal8）三种
"$PY" convert.py --model small    --out "$OUT/models"
"$PY" convert.py --model base-reg --out "$OUT/models" --variants fp32 fp16 int8 pal8 pal6

# 2. 算向量：PyTorch 原版做参照，再用 Core ML 模型，每种计算单元各一份并计时
"$PY" embed.py ~/Pictures/meowverse-eval --model small --out "$OUT/vectors/small-torch.json"
"$PY" embed.py ~/Pictures/meowverse-eval --model "$OUT/models/dinov2-small-224-mean-int8.mlpackage" \
    --out "$OUT/vectors/small-int8.json" --compute-units all cpuAndGPU cpuOnly cpuAndNE

# 3. 和参照比较
"$PY" compare.py "$OUT/vectors/small-torch.json" "$OUT"/vectors/small-int8-*.json

# 4. 家具匹配的成绩
cd ../RecognitionEval
swift run -c release recognition-eval ~/Pictures/meowverse-eval --prints "$OUT/vectors/small-int8-all.json" --auto --cluster --brief
```

- `convert.py`：每种精度写 `<名字>-<精度>.mlpackage`，再编译成同名的 `.mlmodelc`，打印两者的大小和包里每个二进制文件的 SHA-256，并写一份 `<名字>-convert.json`（大小、哈希、来源版本、工具版本）。输出逐字节可复现：同样的 `requirements.txt` 和模型版本，在两个新建的环境里转出的哈希相同（coremltools 自己写的 spec 每次字节顺序不同、manifest 用随机 id，脚本保存后会重新整理）。精度：`fp32`、`fp16`、`int8`（逐通道对称线性量化）、`pal8`、`pal6`（k-means 调色板，每个权重一张表）。量化的都从 Float16 模型出发，计算仍是 Float16。`--attention eager` 换掉默认的 SDPA 注意力。
- `embed.py`：照片的读法和测量时一样：按 EXIF 摆正、转 RGB、整张压成 512 × 512、再压成 224 × 224（都是 PIL bicubic）。所以比较的只是模型本身，不含 App 里 Vision 的缩放。`--model` 给 `small` 或 `base-reg` 时用 PyTorch（CPU、float32），这就是参照。计时只算 `predict` 一次调用，第一张不计；模型加载另报。读不了的文件和重复的文件只计数。
- `compare.py`：每张照片和参照的余弦相似度（最小、第 5 百分位、中位数），以及"最像的另一张照片还是同一张"的比例。只打印数字。
- 照片文件夹的结构见 `../RecognitionEval/README.md`。没有 owner 的照片时，可以照那份 README 的做法用 `art/furniture/validation` 的渲染图冒烟。

## 隐私

照片只在本机原地读取，不复制、不上传。向量文件以照片内容的 SHA-256 为键，权限 600，只能写在仓库外；终端只打印数量和时间，不打印文件名。模型、向量、照片和哈希都不进 Git：`scripts/check-privacy.mjs` 会拒收未登记的二进制。用完删掉 `$TMPDIR/embedding-lab`。

## 结果和已知

实测的大小、余弦、Mac 上的时间和家具匹配成绩在 `ios/MeowverseCore/RECOGNITION_NOTES.md` 的 2026-11-17 两节。

- coremltools 9.0 会提示 torch 2.15 没测过，`torch.jit.trace` 也提示已弃用；转换结果逐张对过 PyTorch（8 位以上最小余弦 0.997 以上）。
- 4 位调色板（即使每 16 个通道一张表）的向量和原版无关，已从选项里去掉。6 位能用但掉成绩。
- Mac 上 `all` 选的是 GPU，不是神经网络引擎；`cpuAndNE` 才走 ANE，第一次加载要先为 ANE 编译。手机上 `all` 会选哪个、多快、占多少内存，都没有测过。
- `embed.py` 的缩放和 App 不一样（见上）。App 里用 ImageIO 缩略图加 Vision `.scaleFill` 时，向量的变化比 8 位量化还大，阈值要用 App 自己那条路径算出的向量来定。
