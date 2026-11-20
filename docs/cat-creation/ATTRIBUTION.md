# 猫咪制作材料：来源与使用说明 / Sources and use

这些文件服务于[猫猫参考图征集流程](README.md)，不包含 App 正式模型、贴图、动作或设计源文件，也不包含用户实拍原照片。它们不是 `MeowverseCore` 的运行资源，不自动适用仓库的 PolyForm Noncommercial 代码许可。

These files support the [cat-reference workflow](README.en.md). They contain no production app models, textures, animations, design sources or real source photos. They are not Core runtime resources and do not automatically inherit the software license.

## 姿态模板 / Pose guide

`POSE_GUIDE.png` 是原参考材料 1.1 中的原字节文件；`guides/` 里的八张单视角灰模是 2026-11-20 起用于逐视角生成的同一灰模、同一机位的单独渲染。两者都基于 **guillaume bolis** 的 **3d modelling my cat: Fripouille** 制作无花纹灰模视图。原始完整署名与改动说明逐字保留在 [TEMPLATE_ATTRIBUTION.md](TEMPLATE_ATTRIBUTION.md)。

- [原作 / Original work](https://sketchfab.com/3d-models/3d-modelling-my-cat-fripouille-0ab14bf98e754f8d90fe1bf1c84ca66c)
- [原作者 / Author](https://sketchfab.com/guillaume.bolis)
- [Creative Commons Attribution 4.0 International（CC BY 4.0）](https://creativecommons.org/licenses/by/4.0/)
- 原参考材料描述的改动：移除个体毛色和胡须，使用中立站姿、正交方向与统一取景，整理为五个全身方向和三个头部视角的灰模说明图。

The eight single-view renders in `guides/` (added 2026-11-20 for view-by-view generation) use the same clay model and cameras as `POSE_GUIDE.png`. The original reference material identifies the neutral guide as derived from *3d modelling my cat: Fripouille* by **guillaume bolis**, under **CC BY 4.0**. Its stated changes remove individual coat textures and whiskers, use a neutral pose and orthographic framing, and arrange five body views plus three head views. Attribution and the applicable third-party rights remain in force; this repository's noncommercial code license does not replace or restrict them. The original author does not endorse this project.

原署名中的既有 Bella 模型链接仅用于追溯来源，不是使用本用户包需要下载的材料；本包不附模型源文件。既有改动署名另有[可公开读取的网页副本](https://fengyee.github.io/meowverse/licenses/bella-cat.txt)。

The original attribution is preserved verbatim in [TEMPLATE_ATTRIBUTION.md](TEMPLATE_ATTRIBUTION.md). Its pre-existing Bella model link records provenance; users do not need to download that model, and it is not included in this kit. The existing adaptation credit also has a [publicly readable web copy](https://fengyee.github.io/meowverse/licenses/bella-cat.txt).

模板控制姿态、相机与取景；猫的长相和花纹应来自用户自行选择的照片，不能把模板的脸型或灰色材质当成个体特征。模板图片不提供源模型文件。

The guide controls pose, camera and framing; individual appearance comes from the user's chosen photos. The model source file is not included.

## 提示词与说明 / Prompt and instructions

`prompts/` 里的十条提示词供用户按本指南逐条复制，配合对应的灰模向自己的图像服务请求总览和八个视图（2026-11-20 起取代原先一次请求八视图的 `GENERATE_ALL_VIEWS.txt`）；它不是模型服务、成功保证或 App 内自动生成接口。说明文稿与排版保留相应权利；第三方已有许可与法定权利不受影响。材料包只收录本流程所需的用户文件，不收录 Blender、GLB、相机工程或私有制作目录。

The ten prompts in `prompts/` may be copied and used with the matching guides for this workflow. They replace the earlier one-message `GENERATE_ALL_VIEWS.txt` (November 20, 2026). It is not a hosted service, a guarantee of successful output or an automatic app feature. Documentation and layout retain their applicable rights; existing third-party licenses and statutory rights are unaffected. The user kit excludes model/Blender sources and private production folders.

## Bella 中英文操作海报 / Bella workflow posters

`cat-creation-flow-bella.png`、`cat-creation-flow-bella-en.png` 于 **2026-11-15** 使用内置 imagegen 生成并编辑。Bella 身份参考来自本项目已公开的品牌插画；本次操作没有向图像工具提交私人猫咪原照片。英文版是中文海报的文字本地化，功能二维码单独使用本机生成的标准码精确嵌入。

海报画的是 2026-11-15 的一条消息版流程（`GENERATE_ALL_VIEWS.txt`，一次请求八个视角）；现行步骤以说明页为准。海报中的照片卡、灰模小图、参考图和手机房间都是**流程示意插画**，不是实际下载的姿态模板、已提交的用户照片或真实 App 截图。请下载独立的 `POSE_GUIDE.png` 作为输入，不要使用流程海报代替它。

The poster was generated and edited with the built-in imagegen tool on **November 15, 2026**, using existing public Bella brand illustrations as identity references. No private cat source photos were submitted for this edit. The posters show the November 15, 2026 one-message version of the workflow (`GENERATE_ALL_VIEWS.txt`, eight views in one request); the guide pages describe the current steps. Photo cards, guide thumbnails, generated views and the phone room are **workflow illustrations**, not the actual guide, submitted user photos or app screenshots.

The English edition, `cat-creation-flow-bella-en.png`, localizes the Chinese poster's wording. A locally encoded English-guide QR is inserted precisely as a functional graphic; it is not a generated approximation of a code.

海报底部二维码指向本仓库的[完整中文教程](https://github.com/Fengyee/meowverse-core/blob/main/docs/cat-creation/README.md)。二维码先在本机以标准编码生成，再作为图像输入合成到海报；已对海报原图、444 像素宽缩小版和 JPEG 压缩版实际解码，均得到同一地址。旁边的仓库地址与首页入口文字供无法扫码时使用。

The footer QR code opens the [full Chinese guide](https://github.com/Fengyee/meowverse-core/blob/main/docs/cat-creation/README.md), which links to the English guide, downloads and request form. It was locally encoded and supplied as an insert for the image edit. Decoding the finished poster, a 444-pixel-wide version and a JPEG version returned the exact intended URL. The printed repository address and home-page entry provide a text alternative.

英文海报的二维码直接指向[完整英文教程](https://github.com/Fengyee/meowverse-core/blob/main/docs/cat-creation/README.en.md)，页面中同样提供材料和投稿入口。它不依赖中文版跳转。

The English poster links directly to the [full English guide](https://github.com/Fengyee/meowverse-core/blob/main/docs/cat-creation/README.en.md), including downloads and submission links.

成品海报仅供本项目展示与分享本流程；不随代码授权为可拆分使用的 Bella 美术素材，也不授予品牌独立使用权。第三方标识仍属于各自权利人。

The finished poster is provided to present and share this workflow. It does not release reusable Bella production assets or independent branding rights. Third-party marks remain with their owners.

## 用户投稿 / User submissions

Issue 附件不成为本材料包的一部分，也不自动适用仓库的代码或模板许可。公开投稿和为本次请求处理的范围见[指南中的公开边界](README.md)；并入内置猫库、训练集、公开素材包或其他发行须另外确认。

Issue attachments are not part of this kit and do not automatically inherit the code or template license. What a public submission covers and what is handled for your request are described in the guide's [public visibility section](README.en.md#public-visibility-and-how-the-project-may-use-your-references). Reference review and work on the request are separate from permission for built-in app inclusion, training, asset-pack distribution or other releases, which require separate agreement.
