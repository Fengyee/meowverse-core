# 猫咪小知识：来源表

「提醒 › 小知识」大约每周送来一条关于猫的小知识。文字在 `ios/Meowverse/CatFacts.xcstrings`，每条一个稳定 id；这里记每条的出处和核对情况。只有来源表里有链接、访问日期、核对角色和核对日期的条目才进入轮换：`ios/MeowverseCore/Sources/MeowverseCore/ReminderPlanner.swift` 里的 `CatFacts.verified` 必须和这些行一一对应，`CatFactsTests` 会检查。

## 规则

- 只从白名单机构取材：Cornell Feline Health Center、International Cat Care（含 ISFM）、AAFP 与 ISFM 联合指南、ASPCA、RSPCA、Cats Protection，以及大学兽医学院或研究机构发表的同行评议研究。中文来源暂缺，补之前只用以上来源，自己转述成中文。
- 转述，不抄原文。每条一两句，口吻温和，不用感叹号堆砌。
- v1 只收四类：习性与身体语言、身体构造与感官、陪伴与玩耍、历史与研究趣闻。不收疾病症状、用药、喂食量和饮食建议、有毒物品、绝育和疫苗，也不收「如果你的猫……就说明……」式的判断。以后若要放健康类内容，必须先有执业兽医审过。
- 产品起草；第二人逐条打开链接核对；owner 审口吻并最终批准。联网核对之前不得进入轮换。
- 表里只写核对人的角色，不写姓名。不收用户投稿。

## 改一条或加一条

1. 在 `CatFacts.xcstrings` 里改中英文（新条目用新 id，旧 id 不挪作他用），新 id 同时加进 `CatFacts.all`。
2. 在下面的来源表里写好机构、页面标题、链接、访问日期、核对角色、核对日期，再把 id 加进 `CatFacts.verified`。没核对完的行把链接和日期写成「—」，它就不会被发出。
3. 跑 `swift test --package-path ios/MeowverseCore --filter CatFactsTests`。

## 来源表

| id | 机构 | 页面标题 | 链接 | 访问日期 | 核对角色 | 核对日期 |
| --- | --- | --- | --- | --- | --- | --- |
| `fact.dawn-dusk` | Cats Protection | Cat crazy time explained | https://www.cats.org.uk/cats-blog/cat-crazy-time-explained | 2026-11-15 | 事实核对（联网） | 2026-11-15 |
| `fact.slow-blink` | 朴次茅斯大学、萨塞克斯大学（同行评议，Scientific Reports 2020，doi:10.1038/s41598-020-73426-0） | The role of cat eye narrowing movements in cat–human communication | https://pmc.ncbi.nlm.nih.gov/articles/PMC7536207/ | 2026-11-15 | 事实核对（联网） | 2026-11-15 |
| `fact.tail-up` | International Cat Care | Cat Communication | https://icatcare.org/articles/cat-communication | 2026-11-15 | 事实核对（联网） | 2026-11-15 |
| `fact.purr` | Cats Protection | Why does my cat purr? | https://www.cats.org.uk/cats-blog/why-does-my-cat-purr | 2026-11-15 | 事实核对（联网） | 2026-11-15 |
| `fact.kneading` | Cats Protection | Why do cats knead? Kneading behaviour explained | https://www.cats.org.uk/cats-blog/why-do-cats-knead | 2026-11-15 | 事实核对（联网） | 2026-11-15 |
| `fact.scratching` | ASPCA；Cornell Feline Health Center | Destructive Scratching；Feline Behavior Problems: Destructive Behavior | https://www.aspca.org/pet-care/cat-care/common-cat-behavior-issues/destructive-scratching<br>https://www.vet.cornell.edu/departments-centers-and-institutes/cornell-feline-health-center/health-information/feline-health-topics/feline-behavior-problems-destructive-behavior | 2026-11-15 | 事实核对（联网） | 2026-11-15 |
| `fact.cheek-rub` | International Cat Care | Cat Communication | https://icatcare.org/articles/cat-communication | 2026-11-15 | 事实核对（联网） | 2026-11-15 |
| `fact.carpal-whiskers` | Cats Protection | Why do cats have whiskers? | https://www.cats.org.uk/cats-blog/why-do-cats-have-whiskers | 2026-11-15 | 事实核对（联网） | 2026-11-15 |
| `fact.night-eyes` | Cats Protection | Can cats see in the dark? | https://www.cats.org.uk/cats-blog/cat-eyesight-facts | 2026-11-15 | 事实核对（联网） | 2026-11-15 |
| `fact.high-hearing` | RSPCA；AAFP/ISFM 指南（JFMS 2013）；Heffner & Heffner（Hearing Research 1985，doi:10.1016/0378-5955(85)90100-5） | Cat Care Tips, Advice & Health Information；AAFP and ISFM Feline Environmental Needs Guidelines；Hearing range of the domestic cat | https://www.rspca.org.uk/adviceandwelfare/pets/cats<br>https://catvets.com/wp-content/uploads/2024/01/EnvironmentalNeedsGLS.pdf<br>https://pubmed.ncbi.nlm.nih.gov/4066516/ | 2026-11-15 | 事实核对（联网） | 2026-11-15 |
| `fact.no-sweet` | Monell 化学感官中心等（同行评议，PLoS Genetics 2005） | Pseudogenization of a Sweet-Receptor Gene Accounts for Cats' Indifference toward Sugar | https://pmc.ncbi.nlm.nih.gov/articles/PMC1183522 | 2026-11-15 | 事实核对（联网） | 2026-11-15 |
| `fact.tongue` | 佐治亚理工学院（同行评议，PNAS 2018，Noel & Hu） | Cats use hollow papillae to wick saliva into fur | https://pmc.ncbi.nlm.nih.gov/articles/PMC6298077 | 2026-11-15 | 事实核对（联网） | 2026-11-15 |
| `fact.flehmen` | Cats Protection；International Cat Care | How do cats communicate with each other?；Cat Communication | https://www.cats.org.uk/cats-blog/how-do-cats-communicate-with-each-other<br>https://icatcare.org/articles/cat-communication | 2026-11-15 | 事实核对（联网） | 2026-11-15 |
| `fact.meow-for-you` | International Cat Care；Cats Protection | Cat Communication；How do cats communicate with each other? | https://icatcare.org/articles/cat-communication<br>https://www.cats.org.uk/cats-blog/how-do-cats-communicate-with-each-other | 2026-11-15 | 事实核对（联网） | 2026-11-15 |
| `fact.high-places` | AAFP/ISFM 指南（JFMS 2013，doi:10.1177/1098612X13477537） | AAFP and ISFM Feline Environmental Needs Guidelines | https://catvets.com/wp-content/uploads/2024/01/EnvironmentalNeedsGLS.pdf | 2026-11-15 | 事实核对（联网） | 2026-11-15 |
| `fact.separate-resources` | AAFP/ISFM 指南（JFMS 2013） | AAFP and ISFM Feline Environmental Needs Guidelines | https://catvets.com/wp-content/uploads/2024/01/EnvironmentalNeedsGLS.pdf | 2026-11-15 | 事实核对（联网） | 2026-11-15 |
| `fact.hiding-spot` | AAFP/ISFM 指南（JFMS 2013） | AAFP and ISFM Feline Environmental Needs Guidelines | https://catvets.com/wp-content/uploads/2024/01/EnvironmentalNeedsGLS.pdf | 2026-11-15 | 事实核对（联网） | 2026-11-15 |
| `fact.catch-the-toy` | AAFP/ISFM 指南（JFMS 2013） | AAFP and ISFM Feline Environmental Needs Guidelines | https://catvets.com/wp-content/uploads/2024/01/EnvironmentalNeedsGLS.pdf | 2026-11-15 | 事实核对（联网） | 2026-11-15 |
| `fact.wildcat-ancestor` | International Cat Care；Driscoll 等（同行评议，Science 2007，doi:10.1126/science.1139518） | The origins of cats；The Near Eastern origin of cat domestication | https://icatcare.org/articles/the-origins-of-cats<br>https://pubmed.ncbi.nlm.nih.gov/17600185/ | 2026-11-15 | 事实核对（联网） | 2026-11-15 |
| `fact.kitten-social` | Cats Protection；AAFP/ISFM 指南（JFMS 2013） | Kitten Socialisation；AAFP and ISFM Feline Environmental Needs Guidelines | https://www.cats.org.uk/help-and-advice/pregnancy-and-kitten-care/kitten-socialisation<br>https://catvets.com/wp-content/uploads/2024/01/EnvironmentalNeedsGLS.pdf | 2026-11-15 | 事实核对（联网） | 2026-11-15 |

## 核对记录

第一批 20 条于 2026-11-15 联网核对，每条都打开了原文页面。草稿来自第五轮产品简报，判定「需改写」的条目已按核对结果改写，`CatFacts.xcstrings` 里是改写后的文字。

| id | 核对结论 | 引文（原页面上的英文短句） |
| --- | --- | --- |
| `dawn-dusk` | 支持 | "Cats are crepuscular which means that they are most active during dawn and dusk" |
| `slow-blink` | 需改写 | "cats had a higher propensity to approach the experimenter after a slow blink interaction"；"slow blink sequences may function as a form of positive emotional communication" |
| `tail-up` | 支持 | "the ‘tail up’ position … signals friendly intent when a cat approaches another cat, animal or person" |
| `purr` | 支持 | "If your cat is purring at the vets, or while there is lots of noise and activity going on around them"（原文接着说这可能是紧张）；"Look for other clues that could show how they're feeling." |
| `kneading` | 需改写 | "Nursing kittens knead around the teat of their mother to better stimulate the flow of milk"；"cats experience similar feelings of happiness"（原文标为最常见的说法，并说成年后为何还踩“no one really knows”） |
| `scratching` | 支持 | ASPCA: "cats scratch on things to remove frayed, worn outer claws"；"They scratch while stretching."；Cornell: "deposits scent from special glands on the cat's paws" |
| `cheek-rub` | 需改写 | "When your cat rubs around your legs to greet you, they are doing the same as they would in greeting another cat" |
| `carpal-whiskers` | 需改写 | "on the back of their front legs. All these whiskers serve the same purpose." |
| `night-eyes` | 支持 | "This is what causes cats’ eyes to glow when light shines on them in the dark"；"Like us, cats can’t see in the dark when there is absolutely no light available." |
| `high-hearing` | 支持 | RSPCA: "they can detect higher frequencies of sound than dogs or humans"；指南: "cats can hear the ultrasonic chatter of rodents"；Heffner: "extends from 48 Hz to 85 kHz" |
| `no-sweet` | 需改写 | "do not prefer and may be unable to detect the sweetness of sugars"；"cat Tas1r2 is an unexpressed pseudogene" |
| `tongue` | 需改写 | "feature a hollow cavity at the tip that spontaneously wicks saliva from the mouth"；"the papilla is in fact scoop shaped" |
| `flehmen` | 支持 | Cats Protection: "If you've ever noticed your cat open their mouth and curl their lip slightly, this is the Flehmen response."；"the vomeronasal organ, located on the roof of their mouth" |
| `meow-for-you` | 支持 | iCatCare: "in most circumstances, meows are directed at people, rather than other cats"；"they are rarely heard during adult cat–cat interactions" |
| `high-places` | 需改写 | "Access to an elevated area increases the cat’s vertical space and allows it to monitor its environment."；"A perch on the roof of the box will enable the cat to feel safe and secure" |
| `separate-resources` | 需改写 | "Each environmental resource … should be in a separate location"；"Food and water resources should be separated from each other." |
| `hiding-spot` | 需改写 | "Provide individual hiding places for the cat."；"A cardboard box placed on its side … provides a safe place from a perceived threat." |
| `catch-the-toy` | 需改写 | "Let the cat catch the toy on the end of the rod or wand to simulate a capture" |
| `wildcat-ancestor` | 需改写 | iCatCare: "a cat found deliberately buried with its owner in a grave in Cyprus, around 9,500 years ago"；Driscoll: "cats were domesticated in the Near East" |
| `kitten-social` | 支持 | Cats Protection: "from two weeks to seven weeks old"；指南: "The most critical age for kittens to socialize with and adapt to humans is between 2 and 7 weeks" |

### 逐条说明（改写原因和风险）

- `slow-blink`：论文没有用 friendly，用的是 positive，作者也说情绪状态还需要更多研究（第一个实验只有 21 只猫）。改成“可能是”。草稿里“更可能靠近你”是第二个实验的结果，保留。
- `kneading`：Cats Protection 明确说成年猫为什么还踩“没人真正知道”，“安心满足”只是最常见的一种说法。草稿写得像定论，改成“常被认为”。
- `cheek-rub`：原文支持“交换气味、像和别的猫打招呼”。“把你算作自己人”是引申，原文没有，删掉。
- `carpal-whiskers`：白名单来源只确认了“前腿后侧有胡须，作用和别处胡须一样”。“抓东西时帮它感知”没有在白名单页面找到（只有宠物杂志和科普网站这样写），删掉。“靠近爪子”也没有白名单原文，改成“前腿后侧”。
- `no-sweet`：论文说的是 may be unable to detect，失效的是甜味受体两个基因中的一个（Tas1r2）。“尝不出”改成“很可能尝不出”，“基因不起作用”改成“一个基因失效”。
- `tongue`：中空的是倒刺的尖端（papilla 尖端有空腔、呈勺状），不是整根倒刺。改了措辞。“又快又干净”里的“快”原文没有，改成“特别有效”。
- `high-places`：草稿 perfect spots 有点夸，改成平实说法；核心意思原文支持。
- `separate-resources`：指南写的是建议（should be），不是“猫喜欢”的观察，改成“最好各在一处”。**提示：这条读起来像照护/布置建议**（涉及猫砂盆和食盆位置），但不属于疾病、用药、饮食量或有毒物品。是否保留由 owner 定。
- `hiding-spot`：指南举的例子是纸箱和猫包，草稿里的“隧道、带顶的窝”在原文里没有找到，换成原文的例子。
- `catch-the-toy`：原文是“模拟一次捕获”，没有说“更满足”，删掉“更满足”。**提示：这条也带一点陪玩建议的口吻**，但属于“陪伴与玩耍”类，不涉及健康。
- `wildcat-ancestor`：
  - 祖先：Driscoll 2007 把 F. s. lybica 称作 Near Eastern wildcat，并把 southern African wildcat（F. s. cafra）列为不同亚种；iCatCare 说也有人把它叫 Felis lybica lybica。单写“非洲野猫”会和南非野猫混淆，改成“近东野猫（也叫非洲野猫）”。
  - 年代：“一起生活大约一万年”是驯化年代，学界仍有争议。iCatCare 页面自己也写了早期遗址里的“likely these were wildcats”，近年还有研究认为真正的家猫更晚、可能出自北非。所以不写驯化年代，只写有确切年代的塞浦路斯合葬（约 9,500 年前，原始论文 Vigne 等 2004 Science 需登录，未读全文，年代引自 iCatCare）。
- `purr`：原文还提到疼痛时也可能呼噜，属于健康内容，**没有写进去**。草稿只说“紧张”，原文支持，保留。
- `dawn-dusk`、`night-eyes`：草稿依据写的是 Cornell，但我没有找到 Cornell 的对应页面；Cats Protection 原文完全支持，来源换成 Cats Protection。
- `high-hearing`：如以后想写具体数字，Heffner 1985 的上限是 85 kHz（70 dB SPL 条件下），网上常见的 79 kHz 等数字不要用。

### 访问限制

- icatcare.org 和 pubmed.ncbi.nlm.nih.gov 拒绝自动抓取。iCatCare 两页是在浏览器里打开读的；PubMed 两条的摘要通过 Europe PMC 接口读取（同一条 PubMed 记录），链接仍写 PubMed。
- Science 上 Vigne 2004 的全文需要登录，没有读，也没有当作引文来源。

### 语气改写（2026-11-15）

应 owner 要求，20 条的中英文于 2026-11-15 改写成更亲切的口吻，来源、链接和日期不变。改写只换语气，没有加回上面删掉的引申，保留了“可能”“很可能”“常被认为”“多半”“通常”这类限定。改写稿随后对照上面的原文引文逐条复核（没有重新打开网页），修正了 7 处：

- `purr`（英文）：耳朵和尾巴只是“更多线索”，不是全部答案。
- `night-eyes`（英文）：补回“被光照到才发亮”，不写成全靠反光膜才看得清。
- `high-hearing`（英文）：主语是小型啮齿动物，不说它们的超声都听得见（猫的上限约 85 kHz）。
- `meow-for-you`（中文）：改回“喵声大多是对人发的”，避免“对你叫就是叫给你听”的循环说法。
- `high-places`（英文）：“watch over everything”说满了，改成“keep watch around it”。
- `separate-resources`（英文）：写明是猫科兽医的指南。
- `wildcat-ancestor`（英文）：“cats”包括大型猫科，改成“House cats”。

`separate-resources` 和 `catch-the-toy` 原先带一点照护或陪玩建议的口吻；owner 同意保留，改写后两条都是描述，不再叫用户去做什么。

通知标题：中文「猫咪小知识」，英文「A Little Cat Fact」；设置里的开关仍叫「猫咪小知识 / Cat Facts」。
