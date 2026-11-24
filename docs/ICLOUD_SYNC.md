# iCloud 多设备同步

状态（2026-11-18）：数据契约、合并规则和同步引擎在 MeowverseCore（`Sync*.swift`，测试 `Sync*Tests.swift`）；CloudKit 传输层和设置里的入口在 App（`ios/Meowverse/Sync/`），记录与 CKRecord 的互转、错误码含义和拉取缓存在 Core 的 `CloudKitSyncCoding.swift`、`CloudSyncMirror.swift`。编译开关 `FeatureFlags.iCloudSync` 在仓库里仍是 false，只有本地构建加编译条件才打开（ios/README.md「iCloud 同步」）。**真正的 CloudKit 还没有在任何设备上跑过**；UI 测试用普通文件夹代替云端（`-MeowverseSyncFolder`）。

和 iCloud 备份（iCloud Drive 里的 ZIP）是两件事，互不替代。备份是某一时刻的完整快照，恢复就是整包替换；同步是逐条记录合并。

## 1. 原则

- CloudKit 私有库、自定义 zone，按记录同步，逐记录合并，从不整包覆盖。
- 只同步 App 自己保存的副本（`originals/<sha256>.<ext>`：2048、1024 或整张），不读不传相册原图。缩略图每台设备自己生成。
- 编译开关 `FeatureFlags.iCloudSync`（默认 false，由 lead 加），加上设置里用户明确打开。1.0 全部免费，同步不挂在任何付费开关上（owner，2026-11-22）。
- 多房间、多猫咪在 1.0 由 `FeatureFlags.severalRoomsAndCats` 隐藏，只拦 App 里的新建（`AppModel.addRoom`、`addCat`）。同步不经过这两处，记录格式也不变：别的设备上已有的第二个房间、第二只猫照常合并进来，和恢复来的一样照常显示（按代码推断，没有专门的测试）。
- 合并结果与到达顺序、重复次数无关：所有合并都是半格（交换、结合、幂等）。

## 2. 记录类型与标识

每条云端记录都是一个信封 `SyncEnvelope{type, name, format, payload}`：`payload` 是排序键 JSON，`format` 现为 1。

| 类型 | 记录名 | 内容 |
| --- | --- | --- |
| `MVPhoto` | `photo.<sourceHash>` | 一张照片。`sourceHash` 取原文件的 SHA-256（缩小副本取 `reducedFrom.sha256`），同一张照片无论在哪台设备导入都落到同一条记录 |
| `MVObservation` | `obs.<observationId>` | 一次识别结果，写入后不改，只能删除 |
| `MVFurniture` | `furniture.<instanceId>` | 一件家具，摆着或收着都是这条（「收纳」是它的一个字段，不单独建类型） |
| `MVRoom` | `room.<roomId>` | 一个房间 |
| `MVCat` | `cat.<catId>` | 一只猫 |
| `MVHome` | `home` | 单例：房间顺序、猫的顺序、少量跟着用户走的设置 |

照片文件不放在这些记录里，而是不可变的 `MVFile` 记录 `file.<sha256>`（CKAsset），放在单独的 zone `MeowverseFiles`（见第 11 节），所以改备注不会让别的设备重新下载图片。

照片字段映射：

| 本机 `PhotoRecord` | 同步 | 说明 |
| --- | --- | --- |
| `photoId` | `photoIds`（集合） | 两台设备各自导入时 id 不同，并集，最小者为规范 id |
| `sha256`、`mimeType`、尺寸、`byteSize`、`reducedFrom` | `copies`（按 sha 并集） | 每台设备存的副本可能不同（2048 或 1024） |
| `originalFile`、`thumbnailFile` | 不同步 | 本机路径；新照片落到 `originals/<sha>.<ext>`、`thumbnails/<规范 id>.jpg` |
| `importedAt` | 取最早 | |
| `filename`、`exifCaptureDate` | 系统寄存器 | 来自文件本身 |
| `captureDate` + `captureDateSource` | `date: followFile / unknown / user(日)` | 用户寄存器，只有用户的操作会写，修复、重读 EXIF 不会碰它 |
| `isFavorite`、`note` | 各自寄存器 | |
| `cloudIdentifier` | 寄存器 | 跨设备的 PhotoKit 标识 |
| `assetIdentifier` | **不同步** | 只在导入的设备上有意义 |
| `revision` | 不同步 | 本机计数 |

**本机标识怎么各自保留**：`assetIdentifier` 永远只取自本机库，投影时也只从本机旧状态带过来，从不写进记录（测试 `photoLibraryIdentifiersOfOneDeviceNeverReachAnother` 检查所有上传的 payload 和对方的副本里都没有它）。另一台设备拿到的照片 `assetIdentifier == nil`，App 用同步来的 `cloudIdentifier` 经 `PHPhotoLibrary.localIdentifierMappings(for:)` 找本机相册里的同一张（`PhotoLibraryLink.asset(for:)` 已是这个顺序）；找到后如果 App 把本机 id 存进库，下次投影会保留，因为本机字段以本机为准。找不到就只用同步来的副本，界面照常显示。

家具字段：`place`（stored、roomId、modelId、x、z、宽、深、朝向、墙、饰面）是**一个**原子寄存器，避免两台设备各改一半拼出不存在的位置；`name`、`tags`、`locked`、`cover`、照片顺序 `order` 各一个寄存器；照片链接是「photoId → 来源或 nil」的寄存器表，每个链接独立合并。

## 3. 合并规则

**时钟**：混合逻辑时钟 `SyncStamp(毫秒墙钟, 计数, 设备 id)`，按三者字典序比较。设备 id 是每次安装随机生成的 12 位十六进制，不是硬件或账号标识。设备每次看到别人的戳都会跟上（`observe`），所以**看过别人的修改之后再做的修改一定排在后面**，即使本机时钟慢。

**两次安装用了同一个 id**：从旧手机的设备备份恢复的新手机，会带着库目录里的 `sync-state.json` 和其中的设备 id。App 遇到这种安装不重新开始，而是接着用带过来的同步文件、换一个新的设备 id（`SyncSession.startOnNewInstall`，见 §11）；引擎自己也查：拉到或冲突回来的记录里有本机 id 下、本机时钟从没走到过的戳，就说明另一处安装在用这个 id，本机改用新 id、时钟保留（`aDeviceThatHearsItsIdFromAnotherInstallTakesANewOne`）。同 id 时一方的删除会把另一方没被看到的修改当成看过的而藏掉。首次同步时不查（拉到的正是本 id 以前的写入）；误判（例如读回上一份同步文件之后）只是多换一个 id。查不出的情形：本机在听到对方之前已经写到更晚，这时只能靠 App 的安装标记。

**为什么不用 revision 或纯时间戳**：`revision` 是每台设备各自递增的，跨设备不可比；纯墙钟会让时钟慢的设备上「后做」的修改输掉。逻辑时钟在两者之间：保留「谁更晚」的直觉，又保证因果顺序。真正并发（互相没看到）的修改按墙钟决胜，这是唯一要靠墙钟的地方。

| 字段 | 规则 |
| --- | --- |
| 普通字段（名字、备注、收藏、日期选择、摆放、设置） | 按字段的后写者胜（LWW 寄存器）。同戳（理论上只有同设备）按 JSON 字节小者，保证确定 |
| 照片 `photoIds`、`copies` | 并集 |
| `importedAt`、家具 `createdAt` | 最早 |
| 家具 `updatedAt` | 最晚 |
| 照片链接 | 每个 photoId 一个寄存器；同一照片的多个别名 id 在投影时归到规范 id，取其中最新的写入 |
| 识别结果 | 不可变，只有删除 |

**规则如何守住硬约束**：

- *用户确认、修正不被模型或旧数据覆盖*：用户写的字段和系统写的字段分开存（`date` 与 `exifDay`），系统修复不会写用户寄存器；旧设备上的旧值戳更小，到达再晚也输（`aUsersDateCorrectionSurvivesAStaleDeviceAndOldDeliveries`）。首次开启时带进来的旧数据只是「提议」，墙钟为 0，输给开启后的每一次真实修改（§7）。
- *异步旧任务不覆盖新状态*：同步把整个结果交给 `LibraryStore.applySynced(ifRevision:generation:)` 一次写入，期间库被改过就拒绝（`localChanged`），重新捕获后再来；库被恢复或清空过就拒绝（`libraryReplaced`）。
- *来源、关系、日期真实，未知就是未知*：`unknown` 是用户寄存器里的一个明确值，不会被「跟随文件」的默认值覆盖；照片和识别结果还没到时链接不显示，记为 `pendingLinks`，界面不能因此说「还没有照片」。
- *家具只在用户确认后出现*：同步只搬运某台设备上已经存在（已确认）的家具，从不根据识别结果生成家具。

## 4. 删除与「删除对修改」

删除写墓碑 `tomb{seen, at}`：`seen` 是删除时这台设备手里该记录的**版本向量**（`SyncVersion`，每台设备在这条记录上最新的一次写入）。记录活着当且仅当没有墓碑，或者有某台设备的写入不被 `seen` 覆盖（那台设备的戳大于 `seen` 里它的那一项，或 `seen` 里根本没有它）。也就是 **删掉的是我看到的版本**：删除方没见过的别处修改会让它回来，哪怕那次修改的时间早于删除方自己最后一次修改；见过的修改之后再删就是真删（observed-remove）。两个删除合起来藏住两者见过的全部（逐设备取大）。

- 「写入」不只是字段变化：照片、家具、房间、猫的记录另有 `edits`，记下每台设备不改字段的写入，例如给同一张照片再导入一个 id、加一份副本，或把照片挂到家具上。所以别处在不知情时**把这张照片挂到家具上**，也会让被删的照片带着链接回来（`aPhotoLinkedWhileItWasDeletedElsewhereComesBackWithTheLink`）。识别结果没有 `edits`（不可变）：写一条识别来的链接时，它用到的识别结果把 `created` 换成这次写入的戳（合并取较新的 `created`），等于记下一次使用。否则撤销移出时照片回来了，识别结果却仍被删，链接因缺识别结果被丢掉、来源静默消失（`QAPhotoMenuTests.undoAgainstAnUnseenDeletion`）。记录格式不变。换戳和照片的 `touch` 一样不看记录死活：一轮同步挂在拉取上时，删除可能已经进了本机副本，用户这时点的撤销仍要连识别结果一起带回来（`QARound2SyncTests.undoDuringAHeldSyncThatBringsTheDeletion`）。只有本机库里还有这条识别结果时才换戳，`undoUnlink` 也不会放回缺识别结果的链接（别处收回了建议时，`undoAfterTheObservationWasTakenBackElsewhere`），所以有意删掉的识别结果不会因此复活。
- 记录里已知只剩墓碑的照片或识别结果，链接不算「还在路上」，不计入 `pendingLinks`（`aLinkToADeletedPhotoIsNotCountedAsWaiting`）。
- 删除照片：它从每件家具上摘下，家具保留；本机文件删掉。云端文件保留 24 小时（`SyncSession.fileGrace`）后再删，给还在路上的修改留时间。之后真有修改把它带回来，持有副本的设备会重新上传（`repairFiles`，每轮查 20 张，轮流）。
- **谁删云端文件**：任何一台刚拉取成功的设备，只凭记录判断，不看是谁上传的（上传的那台可能已经送人、恢复过或重新开始过，`filesOfADeletedPhotoLeaveTheCloudEvenWhenTheDeviceThatUploadedThemIsGone`）。删的是：删除超过 24 小时的照片的副本，以及活着的照片里不是最好那份、且最好那份确实在云端的副本。任何活着的照片还列着的副本不删（`aCopyALivePhotoStillHasStaysWhenAnotherRecordOfItIsDeleted`）；本机还有看不懂的记录时整步跳过，因为它们也可能列着副本。删过的记在 `collectedFiles`，条件还成立就不再重复删；照片回来、文件重新上传后从里面去掉。
- **视图可能不全**，所以清理另有四道保护：
  - 被复活的照片先传文件、后发记录，中间别的设备只看记录会把文件当成已删照片的。发记录前，本轮刚上传的文件再查一次，不在了就重传（`aFileUploadedForAPhotoThatComesBackIsNotDeletedBeforeItsRecordArrives`）。传输层能说出文件的存入时间（`SyncTransport.fileStoredAt`，服务器时钟）时，存入不到 24 小时的文件一律不删，发记录失败、过很久才重发也不怕（`aFileStoredJustNowStaysThoughTheRecordsSayItsPhotoIsDeleted`）。默认实现返回 nil（说不出），这时只有前一道。CloudKit 传输层用 `MVFile` 记录的 `creationDate` 回答（未在真实 CloudKit 上验证）。它的 `hasFile` 在一轮里沿用上传时记下的答案，所以前一道在 CloudKit 上查不出发记录前被删的文件，靠的是后一道；文件早已在云端、没有重传的复活不在 24 小时保护内，被误删时靠持有副本的设备补传（`repairFiles`）。
  - 一张已删的照片，如果某件活着的家具链接着它，而链接的那次写入照片记录没听说过（挂照片时照片记录也以同一个戳写一次，所以完整的视图里它一定是活的），说明本机缺了把它带回来的那个版本，文件留着（`aDeviceThatMissedAComebackDoesNotDeleteTheFileTheComebackNeeds`）。缺的版本只改了别的字段时认不出来，靠持有副本的设备补传（`repairFiles`）。
  - 一轮最多删 50 个文件（`collectLimit`），其余下一轮（`oneCycleDeletesAtMostItsShareOfFiles`）。
  - 要删的不少于 20 个、又超过记录列着的全部副本的一半时，算异常：只删删除已满 7 天的，其余留着，张数报在 `SyncReport.cleanupHeld`（`aCleanUpOfMostOfTheFilesWaitsAWeek`）。宁可多占一周空间。「删除 iCloud 里的家」之后的清理也走这条，所以那些文件 7 天后才删。
- 删除房间：房间里的家具进收纳箱（投影结果，不改家具记录本身）。
- 墓碑**永久保留**，目前连同字段一起。以后可以压缩为只留 `seen/at`，等真机看了数据量再定（owner 2026-11-18 确认）。
- 「删除对修改」采用「未见的修改胜」，宁可保留数据（owner 2026-11-18 确认，不改成照片删除永远胜）。

## 5. 同一张照片在两台设备导入

记录名基于内容，两台设备导入同一张照片（同 SHA、不同 photoId）自然合并成一条：`photoIds` 并集、规范 id 取最小、`importedAt` 取最早。每台设备**保留自己的副本**，不会因为合并去下载别人的；没有副本的设备下载最好的那份（像素多者，再字节多者）。两台设备各自给家具挂的链接按 photoId 别名合并成一条。这时不再是最好那份的副本，等最好那份确实在云端以后，由下一台刚拉取成功的设备删除（§4）。

网页版导入的照片保留网页里的 id（不超过 200 字节，任意字符）。别的设备上，这种 id 不能当文件名时，缩略图按副本的 SHA 命名（`thumbnails/s-<sha>.jpg`），id 本身从不进路径（`aWebPhotoIdThatIsNotAFileNameStillReachesOtherDevices`）。

**日期**：网页记录明确写「未知」、文件里却有日期时，同步记成 `date = unknown`，别的设备上显示为来源 `unknown`、旁边留着文件日期。HEIF 主图修复把「`unknown` 加已知文件日期」也当作明确的未知，不改成文件日期（`aWebRecordsExplicitUnknownDaySurvivesTheHEIFRepairOnAnotherDevice`）；本机导入和编辑从不产生这一组合。网页记录写「未知」而旧版导入没读到文件日期的，记录里分不出是明确未知，会跟随文件。

**同一份副本落在两条记录里**（第十二轮审核 CLOUDKIT-1）：记录按来源命名，库却把相同的字节也算同一张照片（`PhotoRecord.isSamePhoto`），每份副本只存一次。「分享原文件」在相册原图不在或被编辑过时交出的就是 App 存的副本 R；另一台设备把 R 当成一张新照片导入，云端就有 `photo.O {copies: [R，来自 O]}` 和 `photo.R {copies: [R]}`。以前投影会把两张 sha 都是 R 的照片并排交给库，`applySynced` 每轮都拒收，两台设备从此收不到任何别处的修改。现在共用副本的活记录（可以经别的记录间接相连）在每台设备上按同样的规则归成一组（`SyncPhotoGroups`），显示成一张照片：photoId 取全组最小，导入时间取最早，备注、收藏、日期等寄存器在全组里合并，所以哪台设备改的都按时间先后胜出（`aStoredCopySharedToAnotherDeviceIsOnePhotoThereAndEditsStillArrive`）。记录本身不合并：每台设备仍把修改写进自己那张照片的记录；删除写进全组每条记录，否则另一条会把照片带回来（`deletingTheSharedPhotoOnEitherDeviceDeletesItOnEveryDevice`）。副本自己的事实各留各的：A 记着 R 来自 O，B 记着它导入的是整张文件；新设备下载时取知道来历的那份描述（`reducedFrom` 非空者）。文件自己的事实（文件名、EXIF 日期，没有人编辑它们）跟着来历所指的那条记录走，只有设备开着同步写过（修复）才按时间合并：否则两边导入时的“报价”里库更忙的一方胜出，原图的名字会被分享出来的 `shared.jpg` 换掉（`theOriginalsFileNameIsNotReplacedByTheSharesName`）。`cloudIdentifier` 指的是某一台设备相册里的某个资产，按照片自己那条记录取（来源哈希所指的记录），不跨组合并；新设备第一次显示时就从来历所指的记录取，下一轮也不变（`aLaterDevicesPhotoKeepsOneCloudIdentifierFromTheRecordItsHistoryCameFrom`）。

删除和“没看见的写入胜出”（§4）在组里也要整组生效：全组一起删掉后，另一台没看见删除的设备改了备注，只复活它自己那条记录。所以删除一张由几条记录显示的照片时，每条记录的墓碑里都写上这次一起删掉的记录名（`SyncTombstone.together`，几次删除合并时取并集），这台设备读不懂、写不了的组员也写上（`aDeletionThatCannotTombThePartnerLeavesThePhotoWhole`）。其中一条复活，和它共用副本、且任一方的列表点了对方名字的组员就重新并进组里（只看一方就够，因为没有列表的旧版本只会改写其中一方；只有名字、不共用副本的不算，`aDeletionListNamingAnUnrelatedPhotoLendsItNothing`），照片带着它们写过的确认日期、收藏一起回来，和只有一条记录时一样（`anUnseenEditThatBringsTheSharedPhotoBackKeepsTheConfirmedDay`；两次删除叠在一起也一样，`twoDeletionsThenAnUnseenEditBringTheSharedPhotoBackWhole`）。第一版按 `tomb.at` 相同来认“同一次删除”，既不必要也不充分：两次删除合并后 `at` 不同，一次批量删掉几张不相干的照片 `at` 却相同（QA 第二轮）。单独删掉的记录、和别的照片在同一批里删掉的记录都不并进来，所以以后有人再导入这份副本是一张新照片，旧备注不会跟着回来（`aPhotoDeletedOnItsOwnDoesNotLendItsNoteToALaterImportOfItsCopy`、`aBatchDeletionDoesNotLendADeletedPhotosNoteToOneThatComesBack`）。组里有一条记录这台设备现在读不懂（更新版本、数值越界或被下面的安全网扣下），按读得懂的最后一个版本照样归组，整张照片保持本机现状（id、备注都不变，组里的每个 id 仍指它，家具上的链接不会变成“等待中”，`aNewerVersionOfTheOtherRecordLeavesTheSharedPhotoAsItIs`、`aSplitKeepsThePhotosId`）；本机还没有的照片先不显示，也不下载（`aPhotoNotHereYetWaitsWhileOneOfItsRecordsIsNewer`）。`heldBack` 里只记读不懂的那一条，同组的别的记录不另算，界面上的条数才是照片的条数；伙伴是数值越界时它计入 `quarantined`，不会被说成来自更新版本（`aRecordHeldWithAnOutOfRangePartnerIsNotSaidToBeFromANewerVersion`）。从没读懂过那条记录的设备不知道它和谁共用副本，只能把另一条当普通照片显示。删除时读不懂的记录不写，只删自己那条（`aSharedPhotoDeletedWhileOneRecordIsNewerLeavesNothingUnsent`）。一台设备上如果有两张照片落在同一组（库认为是两张，例如先有 2048 副本、又导入了别人的 1024 副本），各自按自己的记录显示，库不替用户删照片；这时这台和别的设备显示的张数不同，但都能同步。随机收敛测试 `SyncSharedCopyConvergenceTests` 让设备互相导入对方的副本（固定种子，另扫过 60 个种子）。

投影交给库之前先用库自己的检查（`LibraryStore.consistencyFault`）过一遍。仍通不过时（只可能是 bug），先扣下「撞了 id 或文件的照片记录」，再在它之上按种类试：本机没有的照片和识别结果、家具、本机已有的照片和识别结果的记录（这些照片保持原样）、房间猫咪和家，先一种一种试，再两种、三种、四种。每次都从全部记录重新构建，没起作用的种类不留到下一次，第一个能过的扣下的种类最少，但不一定记录最少：种类数相同时先试本机没有的照片，所以本来只扣家具就够、而且更少时，也可能先扣了新照片（已知的局限，`SyncQuarantineTests`、`aFaultInAPhotoAlreadyHereDoesNotHoldBackEverythingElse`）；都不行就保持本机库原样、扣下全部。扣下的记在 `SyncProjectionResult.quarantined` 和 `heldBack` 里，其余照常进库，日志只写检查的代码。所以一条坏记录不会再让整台设备停止接收。`quarantined` 还包括构建时撞了 id 或文件的照片记录和数值越界的记录，经 `SyncReport.quarantined` 交给界面：这些不能说成“来自更新版本、更新 App 后才能同步”，iCloud 同步页另起一句说它们读不出或对不上、没有合并，本机已有的保持原样、还没有的先不显示，读不出的那些在本机的修改也先不上传，每次同步再试（`ICloudSync.xcstrings`）。未知的记录类型在任何 format 下都算来自更新版本（§9，`anUnknownRecordTypeIsFromANewerVersion`）。

## 6. 不同步的本机状态

- 当前所在房间、相机位置、界面状态、提醒等本机偏好（App 端的 UserDefaults，不在库里）。
- `assetIdentifier`、文件路径、缩略图、`revision`。
- 家具在列表里的先后顺序，照片在全部照片里的先后顺序。各设备保留自己的，新到的排后。不同步（owner 2026-11-18 确认）。
- 同步自己的状态 `sync-state.json`：时钟、账户、副本、上次见到的库、待发、令牌、已清理的云端文件。它放在库目录里，跟着库走。每次写入先把上一份改名为 `sync-state.backup.json`；当前这份读不出（损坏、替换到一半）就用上一份，还没发出的修正不会因此丢掉（`aDamagedSyncFileDoesNotDropAnUnsentCorrection`）。两份都读不出才按首次开启重来。下载好、还没写进库的照片副本暂存在库目录的 `sync-incoming/`（§8 第 5 步）。

要同步的设置由 App 选键，通过 `SyncSession.setSetting(_:_:)` 写、`settings()` 读，每个键是一个后写者胜的寄存器（`aSettingFollowsTheUserAndTheLaterChoiceWins`）。首次同步前写入返回 false，App 需在首次同步后再写一次。具体哪些键由 lead 定。`setSetting` 不等正在联网的一轮：它立刻写盘，正在跑的那一轮在之后的每次写盘里都带上它（`aSettingChangedWhileASyncIsOnTheNetworkIsKept`）。

## 7. 首次开启与关闭

**首次开启**（本机还没有同步状态）：先拉取云端全部记录，再把本机库**并入**，不删任何东西：

- 两边都有的记录逐字段合并。家具用它自己的 `updatedAt` 作为「播种戳」，改得晚的那份胜。
- 照片的字段没有自己的时间。开启前的值，以及导入时文件给的值，都只是「提议」：戳的墙钟为 0，**一定输给开启后的真实修改**，哪怕那次修改是改回默认值（取消收藏、清掉拍摄日；`aCopyTurningSyncOnLaterDoesNotUndoChoicesMadeAfterSyncWasOn`、`restoringAnOlderBackupDoesNotUndoAChoiceMadeSince`）。两个提议之间，非默认值胜过默认值（默认值的戳就是「什么都没写」）；都不是默认值时，保存次数多（`revision` 大）的那份库胜，再相同就按值的字节。规则里没有设备 id，谁先开、谁的 id 大都一样（`SyncClock.seed(rank:)`）。
- 房间名、猫的名字和所在房间、房间与猫的顺序也没有自己的时间，开启前的值同样是提议：有名字胜过没名字（房间）或默认名 “Kitty”（猫），都有名字时保存次数多的那份库胜（一份库的旧副本输给之后接着改过的那份），再相同按名字的字节，较小者胜（“Luna” 胜 “Mochi”）（`theCatsNameIsNotReplacedByTheOtherDevicesDefault`、`renamesMadeOnOneCopyBeforeSyncSurviveWhicheverIdIsLarger`、`twoNamesFromBeforeSyncSettleTheSameWayWhicheverIdIsLarger`）。两份互不相关的库都给第一只猫（或第一个房间）起了名时只能留一个；「保存次数多者胜，再按字节」这条**待 owner 确认**。
- 两边备注不同：合并为「云端\n\n本机」。即使云端那份是开启后别处新写的也合并（owner 2026-11-18 确认）；一方已包含另一方时取长的；合起来超过 2000 字符时保留云端那份（`twoDifferentNotesFromBeforeSyncAreBothKept`、`aNewNoteKeepsTheCopysOlderNoteNextToIt`）。例外：云端那份是开启后的真实修改，而且是清空或删短（本机那份包含它），就照用户改后的样子，旧字不回来（`aNoteShortenedWithSyncOnDoesNotGrowBack`）。删短这一条是 QA 第二轮之后加的，**待 owner 确认**。
- 云端删过、本机还有的照片、家具、房间和猫，会**回来**（宁可保留），结果与两台设备 id 的大小无关（`turningSyncOnAgainKeepsWhatTheCloudDeletedWhicheverDeviceIdIsLarger`）。回来的东西带着本机的名字和值，按真实修改记（不是提议），删除前云端的旧名字盖不过它（`aRoomAndACatThatComeBackKeepTheNamesTheyHadHere`）。owner 2026-11-18 确认。用户明确选了「也删除 iCloud 里的家」时不同：那是真的删除，见下面「恢复备份或清空库」。
- 同一位置两边都摆了家具：两件都保留，各在自己记录的位置（会叠在一起），由用户自己挪开；第二阶段没有做整理提示，也不自动收起。合起来超过一个房间的 20 件时也全部保留，库照常打开，只是放不下新的（`aMergePastTheRoomsLimitKeepsEveryPieceAndTheLibraryOpens`）。owner 2026-11-18 确认。
- 房间超过 8 个、猫超过 6 只时，多出的在本机不显示（家具进收纳箱），记录仍在云端。

**关闭**：本机库原样保留，云端数据原样保留，只是不再收发。App 关闭时先取消正在跑的那一轮，调用 `SyncSession.close(forgetting: true)`（等那一轮停下，再忘掉同步文件，效果同 `startOver()`），之后清掉传输层的缓存，所以重新打开就是再走一次首次开启的合并（`turningSyncOnAgainKeepsWhatTheCloudDeletedMeanwhile`）。`startOver()` 忘掉副本，但**记得这个家同步过的账户**：换了账户，下一轮仍报 `accountChanged` 等用户选；用户选了「并入现在的账户」，App 调 `startOver(acceptingCurrentAccount: true)`（`startingOverDoesNotMergeTheHomeIntoAnotherAccount`）。删除 iCloud 里的家是另一个明确操作，只在「清除全部数据」里提供，见下一段。

**关闭后的隐私说明**：同步从开到关（手动关、「只清除这台设备上的家」、换过库后自动关）时，App 在 `cloudSync.leftInICloud.<库>` 记下「iCloud 里的家还在」（关闭时已是 `cloudDataDeleted` 则记「不在」）。两个开关都关着时，引导、相册说明和「关于与隐私」据此说「之前同步的家还在你自己的 iCloud 里」，不说「不会传到任何服务器」（`PhotoReach.offWithSyncDataLeft`）。没有这条记录的安装（关同步的是更早的构建），有「this-install」标记就当作还在。这是这台设备最后知道的情况，不联网核对：在别的设备或系统设置里删掉之后，这里不会知道。

**库从较早的一份打开**：`state.json` 损坏、从 `state.backup.json` 打开时，同步文件描述的是更晚的库。若照常捕获，库里少掉的那一段会被当成本机删除发出去，在所有设备上删掉、回退。所以打开备份时，库就地把同步文件的「上次见到的库」改成打开的这一份（两份同步文件都改），缺的那段由记录在下一轮带回来（`aLibraryOpenedFromItsBackupDoesNotDeleteOnOtherDevices`、`editsAfterOpeningTheBackupDoNotTurnTheGapIntoADeletion`）。捕获时再查一次：库的 revision 比「上次见到的库」还旧，同样只改基准不发删除。照片导入日志尾部损坏、库换到隔离后的文件夹时，同步文件一起搬过去（`aPickerQuarantineDuringACycleDeletesNothingElsewhere`）；一轮同步写库时发现库已被换掉（`libraryReplaced`）：新库里有同步文件（上面两种情形都会带着或改好它）就在新库上重来；没有（恢复、清空）就不在会话里重来，把错误交给 App，由 App 的重新开始先核对账户（第十二轮审核 SYNC-1：原来在这里直接当首次同步，清空后的库又被整个拉回来，也不查账户，`aCycleOutWhenTheLibraryIsClearedDoesNotFillTheClearedLibrary`）。

**恢复备份或清空库**：同步状态在库目录里，新库没有它，于是按首次开启合并，**绝不会把别的设备的东西批量删掉**（`aRestoreOrClearWhileSyncingNeverDeletesOnOtherDevices`）。恢复备份照这样做，完成提示写明「会和 iCloud 里的家合并」。

**在没有同步的时候换过库**：没有同步的构建（或同步关着）里恢复、清空，设置里的「同步开着」可能还留着（例如测试者从同步构建换到默认构建再换回来）。新库没有同步文件，下次同步构建一启动就会不声不响地按首次开启合并：清空的家被拉回，恢复的库把那份备份之后各处删掉的东西在所有设备上带回来。所以任何构建在同步没在跑时恢复、清空，都在 UserDefaults 里记 `cloudSync.replacedWithoutSync.<库>`；同步构建启动时读到它而设置仍是开着，就关掉同步并说明原因，不合并，用户再打开（经过同意页）才合并。之前的构建不会记，所以还有一条推断：本机同步过这个库（安装标记在）、设置开着、库里却没有同步文件也没有它的上一份（`SyncSession.hasSyncFile`），而本次启动没有任何重新开始能解释它，同样当作在没有同步时换过库（第十二轮审核 SYNC-2）。同步开着时恢复已损坏的库（设置还没读进来），按开着处理：照常合并，不记这一条。

清空（owner 2026-11-18 决定）：同步开着时，在「清除全部数据？› 继续清除」之后多问一句「iCloud 里的家也要删除吗？」，三个结果：

- **只清除这台设备上的家**：先关掉这台设备的同步（和设置里关闭一样），**等它完全停下**（`disableCloudSync` 返回的任务：正在跑的那一轮停下、同步文件忘掉、传输层缓存清掉），再清空。只把「忘掉」排在那一轮后面不够：联网中的那一轮会在清空后的库上重来，把整个家连照片拉回来（第十二轮审核 SYNC-1，`closingWaitsForTheCycleOnTheNetworkAndTheClearStaysEmpty`）。云端和其他设备不动。之后这台设备再打开同步，云端的家会按首次开启合并回来，所以这一项一定连同步一起关，问句、最后确认和完成提示都写明（`clearingOnlyThisDeviceLeavesTheCloudAndTheOthersAlone`）。
- **也删除 iCloud 里的家**：再确认一次，确认框写明所有打开了同步的设备上的家都会被清空。然后在同步队列里调 `SyncSession.deleteHomeInCloud()`：先拉取，再给本机见过的每张照片（包括文件还没下载到的）、识别结果、家具、房间和猫写墓碑，第一个房间和第一只猫改回空库的名字，全部发出；成功后才清空本机库。清空后的首次合并只拿到墓碑，什么都不回来；其他设备同步后也是空的（`deletingTheHomeInICloudEmptiesEveryDeviceAndNothingComesBack`）。同步保持开着。和所有删除一样，删掉的是本机见过的版本：别处还没同步上来的修改会留下（`anEditElsewhereThatTheDeletionNeverSawStays`）。新版本写的、本机读不懂的记录不动。云端的照片文件照 §4 由任何一台刚拉取成功的设备删除：照片多于约 20 张时，一次删掉的超过一半，按异常处理，7 天后才删。
  - 没有网络、换了账户：抛错，什么都没记、什么都没删，本机也不清空，提示说明原因（`offlineNothingIsDeletedAnywhere`、`inAnotherAccountNothingIsDeleted`）。
  - 发了一半断开：墓碑已落盘，剩下的随下一轮同步发出，到时这台设备的库也会按记录清空；本次不清空本机，提示写明（`aDeletionCutOffHalfwayFinishesWithTheNextSync`）。
  - 云端删完、本机清空失败：下一轮同步按记录把本机清空（`deleteHomeInCloud` 把同步的基准设成当时的库，没捕获的本机修改不会把东西带回来，`ifClearingThisDeviceFailsTheNextSyncEmptiesItAndAnUnsentEditDoesNotBringAPhotoBack`）。
- **取消**：什么都不做。

同步关着时照旧：两步确认后清空。

## 8. 照片上传下载与原子写入

**一次一个写入者**：`SyncSession` 是 actor，但每个 `await` 都会让别的调用插进来，而一轮同步会带着自己那份同步文件跨过整段联网。所以 `sync()`、`captureLocalEdits()`、`startOver()` 在会话内部排队，一个跑完下一个才开始；对同步文件的每次读改写另持一把短锁，从不跨联网。同一设备上两个 `sync()` 同时调用时，后一个等前一个（`twoSyncsAtOnceOnOneDeviceLoseNothingEitherLearned`：不排队时，被挂在网络上的那一轮会把另一轮刚应用的远端改名当成本机更新的修改，盖掉更晚的改名）。App 也把所有调用排成一队（`AppModel.enqueueSync`），两层互不依赖。

**关闭会话**：`close()` 之后会话里什么都不再做：正在跑的那一轮在下一步停下（拉取后、下载前、写库前，以及每次上传、每页拉取之前），之后排进来的调用一律抛 `CancellationError`；`close()` 等到会话里没有任何调用在跑才返回，所以调用方随后换库是安全的。一轮所在的任务被取消（推送或后台时间用完）也在同样的位置停下，不改库，不再把自己的超时报成「iCloud 现在很忙」。这些检查不依赖传输层响应取消：正在进行的那一次上传或拉取仍要等它结束。

一轮同步的顺序（`SyncSession.cycle`）：

1. **捕获**：对比「上次见到的库」和「现在的库」，把本机修改写进副本并标为待发，先落盘再联网。为防止把刚应用的远端修改误当本机修改，一个字段只有在「现在」既不同于上次的库、也不同于副本投影出来的结果时才算本机修改。
2. **发送**：照片记录发送前，先确保它指向的文件在云端（必要时上传本机副本）。所以别的设备永远不会拿到一条指向不存在文件的记录。这张照片的文件传不上去时（空间满、云端拒收这个文件、本机副本读不出），只扣下这张照片的记录，其他记录照发，拉取照常。云端拒收和本机副本读不出记为本轮的问题（App 显示「这次没能同步完」并稍后重试），张数在 `SyncReport.photosNotUploaded`（`onePhotoThatCannotBeUploadedDoesNotHoldBackEveryOtherEdit`、`aPhotoWhoseCopyCannotBeReadIsReportedAndHoldsNothingElseBack`）。补传（第 4 步）遇到本机副本读不出也照样报。离线、限流、换账号这类整个云端都用不了的错误，照旧停下这一轮的发送和拉取。
3. **拉取**：分页拉取，合并到副本。
4. **整理文件**：只在拉取成功（视图是新的）之后才补传缺失文件、清理不再需要的文件。
5. **投影与下载**：由副本生成新库。缺副本的照片下载最好的那份，校验 SHA-256，在本机生成缩略图，一张一张落到库目录里的 `sync-incoming/`（`LibraryStore.syncIncomingDir`）再下下一张，内存里同时只有一张，几百张的首次同步也一样。暂存的副本留到写库成功：这一轮因为用户编辑重来（`localChanged`）、或者写库失败，下一次直接用，不再下载（`editsDuringAFirstSyncsDownloadsDoNotThrowAwayEveryDownload`、`downloadsOutlastAFailedWriteAndLeaveNothingBehind`）。写进库的在写完后删掉，不再等的在这一轮结束时删，关闭同步（`startOver`）时全删。暂存的不属于库：备份、恢复、孤儿文件检查都不看它。下载不到的照片暂不显示，下轮再试（`waitingForFiles`）。
6. **写入**：先把副本落盘，再 `applySynced` 一次写入：校验库没变、新库自洽，把暂存的图片复制（APFS 上是克隆）进 `originals/`、`thumbnails/` 并 fsync，然后提交库（有删除时走与 `deletePhotos` 相同的删除日志）。任何一步失败，库保持原样（`aStoreWriteThatFailsMidApplyIsRetriedWithNothingHalfDone`）。库写完、同步状态写之前崩溃，下次也不会把远端修改当成本机修改重发（`aCrashBetweenTheLibraryWriteAndSyncsOwnFileDoesNotReplayTheRemoteChangeAsNew`）。

## 9. 版本

- 库 schema **不升**，仍是 12：`AppState` 和 `Models.swift` 没有改动，同步状态是库目录里的独立文件，备份只打包库和图片，不含它。旧版本 App 读得了开过同步的库，只是不会同步。
- 记录有自己的 `format`。新版本写的更高 format 或未知类型，旧版本原样保存，不上传、不覆盖，涉及的那件东西保持本机现状并报告 `heldBack`（`aRecordFromANewerAppIsKeptAndLeftAlone`）。以后改记录格式就升 format，新版本必须能读旧 format。
- 同一条记录有两个都看不懂的版本时，每台设备留同一个（format 高者，再 payload 字节大者），与到达顺序无关。升级后能看懂了：读同步文件时把这些版本合并进副本，并清掉令牌、重新全部拉取一次，因为当初留下的未必是最新的（`aRecordHeldBackByAnOlderBuildIsReadAfterTheUpgrade`、`unreadableVersionsAreKeptTheSameWayEverywhereAndReadAfterTheUpgrade`）。
- 版本向量（§4）没有升 format，仍是 1：之前的记录（`seen` 是单个戳、没有 `edits`）照样能读，单个戳读成只有一台设备的版本，没有 `edits` 读成空（`recordsFromBeforeVersionVectorsStillRead`）。旧删除只记了一个戳，新规则下它别的设备的写入没被覆盖，个别旧删除可能回来；同步在仓库构建里没开过，只影响本地开过同步的测试构建。
- 记录里的数值要在范围内才算读得懂（第十二轮审核 CLOUDKIT-4，`SyncRecord.isInRange`）：副本的宽、高、字节数在 0 到 Int32.max，戳的计数在 0 到 2^60（`SyncStamp.maxCounter`），家具的格子坐标和尺寸在 ±2^20。超出的记录像更新版本的记录一样原样保存、不合并、不上传，涉及的东西保持本机现状并计入 `heldBack`（也计入 `quarantined`，界面不叫用户更新）；云端之后来了同一 format 读得懂的版本就替换它（更新 format 的不替换，分不出哪个新）。旧版本没有这项检查时合并进同步文件的越界记录：只是戳的计数越界的，读文件时把这些计数压回范围，记录照常读、本机没发出的修改照常发出（`anUnsentRenameInARecordHeldFromTheSyncFileIsNotLost`）。越界的计数彼此保持先后，排在 `SyncClock.ceiling` 紧下面：删除之后的重新导入仍在删除之后，照片不会被误删（`clampingDoesNotMakeALaterEditLookSeenByAnEarlierDeletion`）；时钟到了顶从 `ceiling` 接着走，所以本机下一次修改、别的设备看见它之后的修改都还排在后面（`aRenameAfterTheUpgradeWinsOverTheClampedOne`）。负的计数压成 0；别的数值越界的不猜，只把那一条当读不懂扣下，整个文件照样读得出（`aRecordAnOlderBuildMergedWithoutTheRangeCheckDoesNotLoseTheSyncFile`）。从云端来的越界记录不压，照样扣下。66c1994 的测试构建存在最顶上的时钟也一样（`aClockStoredAtTheTopStillMovesAfterTheUpgrade`）。时钟不跟上这种戳（`observe`），计数用完时进到下一毫秒；时钟停在最大的可读戳（最后一个毫秒、计数 2^60）上时再也走不动，本机之后的修改彼此分不出先后，所以 `tick` 遇到这种状态从 `SyncClock.ceiling`（同一毫秒、计数 2^59）接着走（`theClockStillMovesAfterTheLargestReadableStamp`、`ticksKeepMovingPastTheCeiling`）。以前两份 40 亿像素边长的副本会在排序时让 `width * height` 溢出，计数为 Int.max 的戳会让下一次 `tick` 溢出，每次启动都崩。墙钟不设上限：时钟快的设备写的记录是诚实的。
- 墓碑的 `together`（§5）是加进同步记录的新字段，没有升 format（审核 COMPAT-1 要求说明）。可选字段，缺了就当这次删除只删了它自己，所以旧记录照样读；只删一条记录时不写这个键，字节和以前一样（`SyncTombTogetherTests`）。没有它的版本（build 7 到 9e0f732）读得懂带它的记录，照样按删除处理，只是合并时丢掉列表，凡是它们写的记录（改了又活过来的，或自己再删一次的）发出去都不带列表。上一版这里写“写过就又活了”，不对：旧版本自己删照片时写的也是死记录（QA 第三轮，`anOlderBuildsDeletionDoesNotSplitWhatDevicesShow`）。所以并组看双方：旧版本不分组，只写它自己那张照片的那一条，同组别的记录的列表仍点着它的名字，每台设备都看得到，照片照样整张回来，各设备显示一致（`aRecordBroughtBackByAnOlderBuildStillBringsItsPartnersBack`）。没堵住的情况：同组的每条记录都被旧版本改写过，这时读过列表的新设备还留着列表、新加入的设备没有，两边的某个字段（例如确认的日期）可能显示不同，照片本身不会丢。一台 build 7 就够：它的「删除 iCloud 里的家」把本地记录里每条活着的记录都写成不带列表的墓碑，不管自己的库里有没有这张照片，所以不受 CLOUDKIT-1 影响。完整的链条是：整组删除写下列表，两次没看到删除的修改让两条记录都活过来，build 7 删除 iCloud 里的家，再有一台从没拿到列表的设备修改。链条长，记为已知缺口，暂不修（第十二轮 QA 第三轮复核，`oneOldDeviceDeletingTheHomeStripsEveryListOfTheGroup`，测试在 QA 分支 `qa/round12-taskB-iter3`，没并入 main）。代价：66c1994 和 9e0f732 这两个测试构建写下的整组删除没有列表，之后有一条复活时其余组员不跟着回来（这两个构建只在本地测试里跑过）；build 7 根本不分组，一份副本落在两条记录里时它本来就收不动（CLOUDKIT-1），这一点与本字段无关。升 format 反而会让旧版本把每张删掉的共享照片都扣下。
- `SyncDeviceState.version` 管同步状态文件；后加的字段缺了就当空（`syncsOwnFileFromBeforeStillReads`）；读不懂就按首次开启重来（合并，不删）。

## 10. 失败、重试、空间、账号

| 情况 | 做法 |
| --- | --- |
| 离线、限流（`retryLater`） | 修改留在本机待发，下轮再发；本轮其他部分照跑 |
| 发了一半断开 | 没确认的记录保持待发，重发是幂等的（`aSaveCutOffHalfwayIsRetriedWithoutLossOrDuplicates`） |
| 冲突（服务器版本更新） | 合并服务器版本后再发，不覆盖 |
| iCloud 空间满 | CloudKit 对记录和文件都可能拒收（`CKError.quotaExceeded`）：发得出去的照发，被拒的留在本机，这一轮不算同步成功，不更新「上次同步」；设置里写「储存空间已满」和等待上传的数量，15 分钟后重试。另一台设备上收到家具、照片还没到时，家具详情写「照片还在同步」，房间里的读屏标签写「…，照片还在同步」，不写「还没有照片」（来自 `SyncReport.pendingLinks`，按家具记） |
| 一张照片的文件传不上去（云端拒收、本机副本读不出） | 只扣下这张照片，其他照常收发；报 `rejected`（App 里是「这次没能同步完」，按退避重试），`photosNotUploaded` 记张数。设置里还没有专门的一行，待 lead 定文案 |
| 退出登录 | 停止同步，本机库不动；设置里写「没有登录 iCloud」。登录后（CKSyncEngine 的账户事件或回到前台）接着同步 |
| 换账号 | 检测到账号变了就停下（`accountChanged`）。设置里出现「需要你决定」：「把这台设备的家并入现在的账户」（`startOver`）或「关闭同步」，选之前什么都不发。从不把旧账号的数据静默推进新账号。传输层收到 CKSyncEngine 的登出或换账户事件时丢掉引擎状态和拉取缓存。提示文案按现行默认写好，**待 owner 确认** |
| 云端数据被用户在系统设置里删除（`cloudDataDeleted`） | 拉取到 zone 被删除（purged、加密数据重置）、已建好的 zone 不见了、或 zone 的标记记录换了（这台设备离线时 zone 被删又被别处重建）时，传输层此后每次调用都报这个错，本轮停下。设置里询问：「重新上传这台设备的家」（`startOver` 并重建 zone）或「关闭同步」 |
| 服务器出错、记录太大 | 记录 payload 超过 512 KB 时改为 CKAsset（`payloadAsset`，带 SHA-256）；单次请求最多 250 条由 CKSyncEngine 的批次控制。其他 CloudKit 错误映射成上表的几种，界面照实说，App 按 30 秒起翻倍、最多 15 分钟重试 |

**隐私政策需要补充**（`public/privacy.html` 目前写着「当前没有开放 App 内的 iCloud 房间同步」）：

- 开启同步后，房间、家具、猫、照片记录和 App 保存的图片副本存进用户自己的 iCloud 私有数据库。开发者无法访问。
- 会占用用户的 iCloud 空间，相册原图不会上传。
- 关闭同步不会删除 iCloud 里的数据；删除方法：App 里「清除全部数据」选「也删除 iCloud 里的家」（所有同步的设备一起清空），或在系统设置里删除 App 的 iCloud 数据。
- 设备之间用随机同步 id 区分，不用设备或账号标识。

## 11. 传输层

接口（`SyncTransport`）：`accountKey`、`fetchChanges(since:)`、`save(_:)`（带 base tag 做冲突检测）、`hasFile / uploadFile / downloadFile / deleteFile`，以及可选的 `fileStoredAt`（文件存入云端的服务器时间，默认 nil，见 §4 清理的保护）。内存实现 `SyncMemoryCloud` 可以注入离线、半途断开、重复与乱序投递、空间满和换账号；App 的测试开关 `FolderSyncCloud` 是同样规则的文件夹版，供 UI 测试用。

**CKSyncEngine**（`ios/Meowverse/Sync/CloudKitSyncTransport.swift`）：最低系统 iOS 18，CKSyncEngine 从 iOS 17 起可用。它替我们处理推送订阅、变更令牌、批量与重试、账号变化事件，这些手写 `CKFetchRecordZoneChangesOperation` / `CKModifyRecordsOperation` 都要自己做，而且最容易出错。我们的合并在记录内容层，CKSyncEngine 只负责搬运，正好分工。适配方式：

- **zone 按资料库分**：zone 属于整个 iCloud 账户，资料库却按文件夹分。用户自己的家（`Library`）用 `Meowverse` 和 `MeowverseFiles`，名字不变；别的资料库（测试库 `-MeowverseStore`）用自己的一对 zone，名字是 `Meowverse-<可读的库名>-<库名哈希>` 和 `MeowverseFiles-…`（`CloudKitSyncZones.forLibrary`），绝不并进真实的家（`onlyTheHomeLibraryUsesTheHomeZones`）。
- 信封映射到 `CKRecord`：类型为 `type`，名字为 `name`，字段 `format`、`payload`（bytes），放在资料库的记录 zone。`payload` 超过 512 KB 时（单条记录约 1 MB 的上限之内）改放 CKAsset 字段 `payloadAsset`，另存 `payloadSHA256`，读回时核对。真实数据量还没在真机上量过。
- 文件作为 `file.<sha>` 记录的 `CKAsset`，不可变，从不修改只会删除。
- `recordChangeTag` 映射到 `tag`；`serverRecordChanged` 映射到 `conflict`。
- `SyncSession` 仍是「一轮拉一次」的接口，没有改。CKSyncEngine 会自己拉（启动、收到推送时），拉到的记录先写进磁盘上的 `CloudSyncMirror`（每条记录的最新版本、change tag 和系统字段，按顺序编号），再写引擎的状态序列化，所以引擎的令牌前进了也不丢记录。`fetchChanges(since:)` 先让引擎拉一次，再从 mirror 交出令牌之后的记录；令牌是「mirror 纪元:序号」，纪元不同（mirror 被清掉过）就全部交出，合并本来就是幂等的。
- **mirror 和引擎状态的先后**（`CloudSyncMirrorFiles`）：mirror 没写进磁盘，引擎状态就不写（磁盘上旧的那份仍与旧 mirror 一致，重启后引擎从旧令牌再拉一次）；mirror 不见了或读不出（损坏、更新版本写的），引擎状态一起丢掉，引擎从头全部拉取。交给一轮同步的令牌只到磁盘上的 mirror 为止，只在内存里的记录重启后会再交一次（`theEnginesStateIsNotSavedWhileTheMirrorIsNot`、`aRecordHandedOutButNeverOnDiskIsHandedOutAgainAfterARelaunch`、`aMirrorThatIsGoneOrUnreadableTakesTheEnginesStateWithIt`）。
- **读不出的记录**：引擎交来的记录解不出（多半是超过 512 KB 的 payload 附件没下载下来）时不跳过，记进 mirror 的 `unfetched`，此后每次 `fetchChanges` 按记录单独重取（每次最多 50 条，带附件）；服务器上已没有的就忘掉。还有没读出的记录时不删任何云端文件（`deleteFile` 报 `retryLater`），因为它可能列着那份文件。设置页显示「别的设备改过的 N 项内容还没能从 iCloud 取下来」。
- **zone 标记**：记录 zone 里有一条 `MVZoneMarker` 记录 `zone.marker`，带一个随机 id，第一次见到 zone 时采用或新建。每轮第一次联网时核对；id 变了（或 mirror 记着 id、服务器上却没有标记）说明这台设备离线期间 zone 被删又被别处重建，此时它看不到删除，不在待发列表里的记录也不会重发，所以按 `cloudDataDeleted` 停下，由用户选「重新上传这台设备的家」，即按首次开启重新合并上传。标记出现之前就已被重建的 zone 认不出来。
- 发送只在 `save` 里：把这批记录加进引擎的待发列表、立刻 `sendChanges`，结果从 `sentRecordZoneChanges` 事件取，结束时从引擎状态里移除，引擎不会自己重发（未确认的由 `SyncSession` 的 dirty 列表管）。发送中被杀时引擎状态里会残留待发项：引擎对 `recordProvider` 返回 nil 的项只是跳过、仍留在待发列表里，会一再来要，所以引擎建好时清掉全部残留，`nextRecordZoneChangeBatch` 里没有记录的项也明确移除（`aPendingSaveWithNoRecordIsRemovedNotSkipped`）。base tag 对应 mirror 里那一版的系统字段，所以服务器版本变了就回来 `serverRecordChanged`，映射成 `conflict`。冲突错误里的服务器记录不带附件（`CKAsset.fileURL` 的文档写明 `serverRecordChanged` 时不下载），payload 放在附件里的大记录要按 id 单独取回服务器版本再交给合并。只因同批别的记录失败的（`batchRequestFailed`）在同一次调用里再发一次。
- 文件不经过 CKSyncEngine：引擎拉的是整条记录，会把每张照片的每个副本都下载下来。`MVFile` 放在 `MeowverseFiles` zone，用 `records(for:desiredKeys:)` 查有没有、下载，`modifyRecords` 上传（已存在就算成功，文件不变）和删除。「有没有」一次问一批（最多 100 个：要问的那个，加上 mirror 里活着的照片列着、本段还没问过的文件，从要问的那个往后按照片顺序取，和同步逐张检查的顺序一致；服务器嫌多时退回只问一个），答案在本轮里沿用，拉取之后作废重问；所以一轮的修复和清理只要一两次往返，不是每张照片一次。下载后按 SHA-256 核对，不一致当作缺文件。
- `accountKey` 是 CloudKit 用户记录 id 的 SHA-256 前 10 字节，不存原 id；和 mirror 记的账户不同时丢掉 mirror 和引擎状态。
- 状态：引擎状态 `engine-state.json` 和 `mirror.json` 在 `Application Support/Meowverse/Sync/<库>/`，同步自己的 `sync-state.json` 仍在库目录里。`Sync` 文件夹不进设备备份。
- 照片记录要等它的副本至少一份已在云端才发（两个传输层的 `save` 都查，`SyncFileGate`），否则回 `missingFile`。
- App 在下一轮之前调用 `startOver()`，按首次开启合并、换新的设备 id 的情形：库从 `state.backup.json` 或截断的照片导入恢复打开；恢复备份、清空之后；用户打开同步时。标记里记着上次重新开始时的账户（哈希过的 key）；现在登录的不是它，就报 `accountChanged` 等用户选，不静默并入。`startOver()` 本身也保留同步过的账户（§7），只有用户选了「并入现在的账户」时 App 才传 `acceptingCurrentAccount: true`；两道检查互不依赖（例如重新开始前同步文件已经读不出时，只剩标记这一道）。同一台设备上所有 `SyncSession` 调用排在一个队列里，会话内部也一次只跑一个（§8）。
- 这次安装从没同步过这个库、同步却开着（`Sync/<库>/this-install` 标记不在，例如新手机是从旧手机的设备备份恢复的：设备备份带走库和其中的 `sync-state.json`、带走 UserDefaults，不带 `Sync` 文件夹）时，App 不重新开始，而是调用 `SyncSession.startOnNewInstall()`：接着用带过来的同步文件，换一个新的设备 id，清掉变更令牌（新安装的传输层什么都没拉过）。旧手机记下但没发出的修改照常发出，备份之后别处的删除照常生效；重新开始会丢掉前者、在所有设备上复活后者（第十二轮审核 FAMILY-1）。库比同步文件的基准新的那一段（保存了、还没来得及捕获）按旧手机最后的时间记，不按现在：按现在记，旧值会盖掉旧手机之后的新修改（QA 第十二轮，`aNewPhoneDoesNotRestampAnEditTheOldPhoneLaterReplaced`）。同步文件读不出或从没同步过，才重新开始。文件里的账户保留，换了账户照样停下等用户选。
- 需要的工程设置：iCloud 权益里的 `CloudKit`（原来就有）、`aps-environment`、后台模式 `remote-notification`。后两项只在带同步的构建里（构建设置 `MEOWVERSE_ICLOUD_SYNC=YES`，ios/README.md「iCloud 同步」），默认构建的签名和 Info.plist 里没有。App 收到 CloudKit 推送时跑一轮同步（最多约 25 秒）。超时取消的是正在跑（或排着要跑）的那一轮本身（`CloudSyncUIState.cycleTask`），不是队尾。

**真机验证清单**（两台登录同一账号的设备，加一台不同账号）：

1. 开关打开后首次合并：两边各有家具和照片，结果为并集，备注合并。
2. 同时改同一件家具的名字和位置，后改者胜；改不同字段都保留。
3. 一台飞行模式下改几件，恢复网络后合并；期间另一台删掉其中一件。
4. 同一张照片两台各自导入，最后只有一张，各自不重新下载。
5. 另一台能通过 `cloudIdentifier` 在相册里找到大图；找不到时用副本显示。
6. 拍照或导入大图后立即杀掉 App，再打开不丢、不重复。
7. iCloud 空间接近满时的提示与恢复。
8. 退出 iCloud 再登录另一个账号：出现询问，不混数据。
9. 在系统设置里删除 App 的 iCloud 数据。
10. 恢复备份、选「只清除这台设备上的家」后，另一台设备的东西没有被删除，清空的这台同步已关闭；选「也删除 iCloud 里的家」后，另一台回到前台或收到推送时变空，CloudKit Console 里只剩第一个房间、第一只猫和 `home` 是活的。
11. 500 张照片、50 件家具的首次同步时长、流量和电量；后台同步是否被系统按时唤醒。
12. 隐私：抓包确认只连 Apple 的 CloudKit 服务。

## 12. owner 的决定（2026-11-18）

原来待确认的 8 项，owner 的答复：

1. 删除对修改：保持现行，未见的修改让被删的东西回来。
2. 首次开启时，云端删过、本机还有的照片和家具会回来：保持现行。
3. 首次开启时两边不同的备注合并为两段：保持现行。
4. 墓碑永久保留，以后再压缩：保持现行。
5. 首次开启后两件家具占同一位置：保持现行，都保留，由用户挪开。
6. 同步开启时恢复备份：合并回来（现行）。清空：多问一句是否同时删除 iCloud 里的家，三个结果「只清除这台设备上的家（同时关闭这台的同步）」「也删除 iCloud 里的家（其他设备也清空，二次确认）」「取消」，已实现，见 §7。
7. 换账号时的提示文案与默认选项：按现行文案，待 owner 在真机上看过再定。
8. 家具与照片在列表中的先后顺序：不同步。
