# 识别评测（Mac）

用一文件夹你自己分好类的照片，量出 App 的两种本机识别有多准：

1. **类别建议**：审核页"本机识别"里的类别（Vision 图像分类）。
2. **像已有的家具**：拿一张照片去和已经放进家具的照片比（Vision feature print），看最像的那件是不是对的。猫的位置涂掉和不涂掉各算一遍。

两者用的都是 App 里的同一份代码（`MeowverseCore`），照片也按导入时的方式解码、缩成 512 px 缩略图。

## 照片怎么放

```
评测文件夹/
  sofa/                  ← 类别名，见下
    客厅灰沙发/           ← 一件具体的家具；放这件家具的所有照片
      IMG_0012.HEIC
      IMG_0388.JPG
    IMG_0101.JPG         ← 只知道是沙发、不分哪一件：只算类别
  catTree/
    阳台猫爬架/
      ...
  none/                  ← 看不出家具的照片
    IMG_0500.JPG
```

类别文件夹必须用这些名字：`chair` `stool` `bench` `table` `bed` `sofa` `scratcher` `catTree` `platform` `hideout` `toy` `litterBox` `windowPerch` `water` `photoBoard`，或者 `none`。

"像已有的家具"只用放在第二层文件夹里、且这件家具至少有两张照片的那些。每张照片轮流当作"新照片"，其余照片当作房间里已有的家具。

## 运行

```bash
cd ios/Tools/RecognitionEval
swift run -c release recognition-eval ~/Pictures/meowverse-eval
```

- `--misses`：额外列出认错的文件名。
- `--json 结果.json`：把同样的数字写进文件，方便对比。
- `--auto`：自动归类（严格规则）的模拟，见下。
- `--cluster`：冷启动分组，见下。
- `--by-place`：按 GPS 把照片分成几个地方，在每个地方里分别算，见下。
- `--brief`：只打印 pair check、每种方法最好的一行和总结行。完整的表有几百行。
- `--prints 向量.json`：用别的模型算好的向量代替 Vision 的，见下。
- `--coreml 模型`：用 App 自己的 DINOv2 代码（`DinoPhotoEmbedder`）算向量代替 Vision 的，见下。
- `--fixed-d 距离`：margin 规则的对照设置（k = 2、r = 1.25）不用第 2 百分位，改用这个固定的平方距离，也就是 App 里写死的常数。
- `--list-hashes 输出.json`、`--boxes 输出.json`：给本机脚本用的两个文件，见下。
- `--session-gap 分钟`："加上拍摄时间"那一组的时段间隔，默认 10 分钟。
- `--place-minimum 张数`：`--by-place` 里照片少于这个数的地方只列出、不打分，默认 20。
- `--no-cache`：不读也不写特征向量缓存。

用了 `--auto`、`--cluster` 或 `--by-place` 时只跑这几项，不跑类别建议和前面几份报告，也不跑 Vision 分类器。可以一起用：

```bash
swift run -c release recognition-eval ~/Pictures/meowverse-eval --auto
swift run -c release recognition-eval ~/Pictures/meowverse-eval --cluster
swift run -c release recognition-eval ~/Pictures/meowverse-eval --auto --cluster --brief --json 结果.json
swift run -c release recognition-eval ~/Pictures/meowverse-eval --by-place --auto --cluster --brief
```

### 比较的是哪几种向量

每份报告对每种向量（signal）各算一遍：

- Vision，整张图，猫涂掉（App 现在用的）
- Vision，整张图，猫不涂
- Vision，猫周围 1.5 倍、2.5 倍的区域，猫不涂和涂掉各一种：把 Vision 找到的猫框（几只猫就取包住它们的框）以中心放大到 1.5 或 2.5 倍，超出画面的部分切掉，只给这一块算 feature print。猫坐在家具上，这一块应该比整个房间更能说明是哪件家具。找不到猫的照片用整张图，开头会打印找到猫的照片有几张。
- 用了 `--prints` 时只算那个模型的向量，报告里用文件里的模型名。

距离都是平方欧氏距离。不同模型的距离尺度不一样，所以 `--auto` 的 d 和 `--cluster` 的切点除了固定值，还取这种向量自己所有照片两两距离的百分位数：`p1`、`p2`、`p5`、`p10`、`p20`（`--cluster` 再加 `p30`、`p50`），表里写成 `p5=0.21`。

### `--auto`：很有把握时自动归类

规则：新照片最近的 k 张已归类照片全在同一件家具里（且只在这一件里），最近那张的距离不超过 d，这件家具已经有至少 m 张照片，才把照片放进确认页。k 取 3、5、7，d 取 0.20 到 0.50 和上面的百分位数，m 取 1、3、5。最近的 k 张都在这件家具里时，它已经有 k 张照片，所以 m 不大于 k 时和 m = 1 完全一样；表里只列 m = 1 和 m > k 的行，"check"一行核对过这一点。

按拍摄时间（EXIF）排序，只用有拍摄时间的照片。没有子文件夹的类别文件夹算一件家具。无家具照片和"那件家具房间里还没有"的照片，只要被自动归类就算错。

- **A. 一张一张来**：每张新照片和更早的照片比，更早的照片都已经归对（用户改过错）。列出自动归类了几张、对了几张、准确率和 95% 区间（Wilson）、占全部照片的比例和占"家具已在房间里"照片的比例，以及错的是哪些（真实标签 → 归到的标签，只有标签）。
- **B. 一批导入、房间是空的**：用户按时间顺序手动归第一张还没归的照片，每归一张就对剩下的所有照片重跑规则，把选中的放进一页确认。分两种：确认页照单全收（错的留在错的家具里，之后也参与投票）；用户把错的取消勾选（这些照片之后手动归，不再推荐）。列出手动决定了几张、自动归类几张、对几张。
- 总结行：没有一张错时推荐最多的设置；95% 区间下限不低于 90% 时对得最多的设置。

### `--auto` 里的边距规则：先选设置，再在没见过的照片上打分

边距规则：最近的 k 张已归类照片全在同一件家具里，最近那张不超过 d，并且离它最近的"别的标签"的照片（别的家具，或者放到照片墙的无家具照片）至少是第 k 近那张的 r 倍远（平方距离，相等算通过；还没有别的标签时直接通过）。k 取 1、2、3、5，d 同上（固定值和百分位数），r 取 1.0、1.1、1.25、1.5、2.0。按时间一张一张来，无家具照片放到照片墙，照片墙参与比较但从不被推荐。推荐的照片分两种算：留在推荐的地方（确认页照单全收，错的之后也参与比较），和用户改对。

设置不在打分的照片上挑：

- **时间对半**：按拍摄时间分成前一半和后一半，在前一半上选"没有一张错时推荐最多"的 (k, d, r)，只报后一半的推荐数、对的数和 95% 区间。并列时选更严的（r 大、d 小、k 大）。
- **留一个地方**（加 `--by-place` 时）：每个地方轮流拿出来，在其余地方上选设置，在拿出来的地方上打分，最后加总。同时也报每个地方各自时间对半再加总的结果。
- 每条都列出错的里面有几张是"新家具"错误（这张照片真正的家具当时归档的照片少于 3 张），几张是无家具照片。另附一行"k=2 d≤p2 r=1.25"按同样方式打的分，作对照：这个设置是看过全部照片后挑的，不算样本外的证据。

### `--cluster`：冷启动，一次导入很多照片、房间里还没有家具

不看标签，把所有照片分组；标签只用来打分。方法：层次聚类（平均连接、完全连接），按距离切开；以及按拍摄时间顺序的 leader 聚类。

- 每行：组数、单张组数、按家具和按类别的纯度、"3 张以上且 90% 以上是同一件家具的组"里的照片占比、调整兰德指数（ARI，1 = 和真实分组一样，0 = 随机），以及用户操作数：每组用多数标签命名一次，再把不属于这件的照片逐张改，和"每张都标一次"比。
- "none in furniture groups"：无家具照片有几张落进了以家具为主的组，有几个 3 张以上的家具组混进了无家具照片。每种方法最省操作的设置还会把无家具照片拿掉重新分组，比较家具照片的纯度和 ARI：两者一样就说明无家具照片没有搅乱分组。
- "pair check"：两张同一件家具的照片比"同类别的另一件"、"另一类别"、"无家具照片"更近的概率（0.5 = 随机，1 = 总是更近），直接回答这种向量能不能分开家具。只用放在第二层文件夹里的照片。

### 加上拍摄时间和地点

`--auto` 和 `--cluster` 都多算一组"vectors + time"：同一时段（相邻两张间隔不超过 `--session-gap`）的照片距离当作 0，先合并；两张都有 GPS 且相距超过 1 km 的照片永远不归到一起。`--cluster` 另有"time alone"一组，只按时段分组、完全不用向量，用来对照向量到底有没有用。

### `--by-place`：一个地方一个地方地算

App 里一个房间是一个家，而照片可能跨了好几个家。`--by-place` 先按 GPS 把照片分成几个地方（相距 1 km 以内的照片连成一片，单连接），地方用字母代替，照片最多的是 A，从不打印坐标。没有 GPS 的照片单独列为"unknown"，不参加打分。

1. 每个地方：照片数、有哪些家具（各几张）、拍摄年份。
2. 照片不少于 `--place-minimum` 张的地方，各自单独跑 pair check、`--auto`（A 和 B）和 `--cluster`，只拿这个地方的照片当参照。最后把各地方加总：自动归类的推荐数和对的数加起来再算 Wilson 区间，分组的操作数加起来，pair check 把各地方的照片对合在一起算。用了 `--brief` 时只打印每个地方的 pair check 和加总的结果。
3. "does a label mean one physical piece?"：同一个标签、同一个地方的两张照片，同一个标签、不同地方的两张，和同一个地方不同家具的两张，比较谁更近。同一个标签跨地方时如果不比"同一地方的不同家具"更近，这个标签多半不是同一件实物，或者向量量的主要是房间。

### App 里的 DINOv2：`--coreml`

```bash
swift run -c release recognition-eval ~/Pictures/meowverse-eval \
    --coreml ../../Meowverse/Resources/Models/DinoV2ViTB14Reg.mlpackage --auto --cluster --brief
```

`Sources/recognition-eval/DinoPhotoEmbedder.swift` 是指向 `ios/Meowverse/App/DinoPhotoEmbedder.swift` 的软链，所以工具跑的就是 App 的那份代码：照片按导入时的方式做成 512 px 缩略图，同一份缩略图字节交给 `DinoPhotoEmbedder`。模型可以给 `.mlpackage`（先编译）或 `.mlmodelc`。模型加载失败时直接报错，不像 App 那样退回 Vision。

- `--coreml-units all|cpuOnly|cpuAndGPU|cpuAndNE`：计算单元，默认 `all`（和 App 一样）。
- `--write-prints 向量.json`：把算出的向量写成 `--prints` 的格式（权限 600，仓库里拒绝写），可以交给 `ios/Tools/EmbeddingLab/compare.py` 和 PyTorch 的向量比。只给这个参数、不给 `--auto` 等时写完就退出。
- 开头打印每张的中位耗时（解码、缩放和预测，Mac 上）。这些向量不进缓存。

### 用别的模型：`--prints`、`--list-hashes`、`--boxes`

先让工具写出照片的哈希和位置，交给本机的 Python 脚本（脚本不放进仓库）：

```bash
swift run -c release recognition-eval ~/Pictures/meowverse-eval --list-hashes "$TMPDIR/meowverse-hashes.json" --boxes "$TMPDIR/meowverse-cats.json"
```

- `--list-hashes`：只写 `{照片内容的 SHA-256: 绝对路径}`。
- `--boxes`：对每个 SHA-256 写 Vision 找到的猫框，`[x, y, 宽, 高]`，归一化到 0–1，原点在左上角（和多数图像库一样），找不到猫是空列表；没有文件名。
- 这两个文件只有你自己能读（权限 600）。目标在本仓库或任何 Git 仓库里时工具拒绝写，写到 `$TMPDIR` 之类的地方，用完删掉。只给了这两个参数时工具写完就退出。

脚本算完向量后写成：

```json
{ "model": "模型名", "dimension": 512, "vectors": { "<SHA-256>": [0.12, -0.03, ...] } }
```

`dimension` 可以不写，不写时取最常见的长度。工具会把每个向量缩放到单位长度，距离仍是平方欧氏距离。用不了的条目跳过并计数，不会猜：键不是 SHA-256、值不是数字列表、长度不对、有非有限数、全是 0。文件里没有向量的照片不参加，开头会打印有几张。然后：

```bash
swift run -c release recognition-eval ~/Pictures/meowverse-eval --prints "$TMPDIR/vectors.json" --auto --cluster --brief
swift run -c release recognition-eval ~/Pictures/meowverse-eval --prints "$TMPDIR/vectors.json" --by-place --auto --cluster --brief
```

## 隐私

照片只在本机原地读取，不复制、不上传。为了第二次跑得快，Vision 的向量和猫框缓存在系统临时文件夹里（`$TMPDIR/meowverse-recognition-eval/`，运行时会打印完整路径），每张照片一个文件，文件名是照片内容的 SHA-256，里面只有向量和猫框，没有文件名、时间和地点。Vision 版本、App 的缩略图管线或 macOS 版本变了会换一个新的子文件夹。删掉这个文件夹就清空了；`--no-cache` 完全不用它。拍摄时间和 GPS 每次从 EXIF 读，只在内存里用，不缓存、不打印、不写进任何文件。除此之外工具只写你点名的文件：`--json`（只有数字和标签）、`--list-hashes`（哈希和路径）、`--boxes`（哈希和猫框）。输出里只有数字和你的文件夹名（标签），文件名只在 `--misses` 时打印到终端。评测文件夹不要放进仓库。


## 看结果

- 类别建议：只有 6 个类别 Vision 有标签（sofa、chair、stool、bench、table、bed）。其余类别的照片会单独计数，它们永远不会被建议。
- 像已有的家具："closest piece is the right one" 是最像的那件家具就是对的比例。阈值表是：距离不超过这个值才显示建议时，有多少照片会显示建议，显示出来的有多少是对的。App 现在用 `SimilarFurniture.maxDistance`。工具会给出"对的比例不低于 90% 的最高阈值"，可以拿它来改这个常数。
- 两种遮猫方式里更准的那个，应该成为 `VisionPhotoEmbedder` 的默认值。
- "Learning from your own labels"：只用 feature print 和你的标注，比较几种办法（最近一张、5 张最近投票、每类平均、用你的照片训练的分类器）。分三种切法：留一张、只用别的时段（相隔 2 小时以上）的照片、按拍摄时间只用更早的照片。最后一种最接近 App 里的真实情况。"surest 25% / 50%" 是只在最有把握的四分之一、一半照片上给建议时的准确率，括号里是对应的置信度门槛。
- 类别文件夹也可以用中文名，例如 `沙发`、`猫爬架`、`无家具`；`纸盒`、`猫窝` 算作藏身窝。
