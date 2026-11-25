import MeowverseCore

/// The privacy promises about the photos, one wording per `PhotoReach`. Meowverse has no server:
/// what leaves the device goes only into the user's own iCloud, and only because the user turned
/// on Back Up to iCloud Drive or iCloud sync. Each sentence names whichever of the two is on,
/// and only with both off says that nothing is uploaded (round 12 audit, PRIVACY-4, PRODUCT-8).
/// With both off, copies an earlier switch left in iCloud are named, not hidden behind "never".
extension PhotoReach {
    /// The guide's first stop, in the cat's voice.
    var guideWords: String {
        switch self {
        case .thisDeviceOnly:
            String(localized: "你好，我是这间房间里的猫。挑一张猫咪的照片吧。照片只留在这台设备上，不会上传。")
        case .iCloudDriveBackup:
            String(localized: "你好，我是这间房间里的猫。挑一张猫咪的照片吧。照片存在这台设备上，备份只存进你自己的 iCloud 云盘。")
        case .iCloudSync:
            String(localized: "你好，我是这间房间里的猫。挑一张猫咪的照片吧。照片存在这台设备上，只通过你的 iCloud 同步到你自己的设备。")
        case .backupAndSync:
            String(localized: "你好，我是这间房间里的猫。挑一张猫咪的照片吧。照片存在这台设备上，只通过你的 iCloud 同步到你自己的设备，备份也只存进你自己的 iCloud 云盘。")
        case .offWithBackupsLeft:
            String(localized: "你好，我是这间房间里的猫。挑一张猫咪的照片吧。照片存在这台设备上，喵空间不会再上传。之前的备份还在你自己的 iCloud 云盘里。")
        case .offWithSyncDataLeft:
            String(localized: "你好，我是这间房间里的猫。挑一张猫咪的照片吧。照片存在这台设备上，喵空间不会再上传。之前同步的家还在你自己的 iCloud 里。")
        case .offWithBothLeft:
            String(localized: "你好，我是这间房间里的猫。挑一张猫咪的照片吧。照片存在这台设备上，喵空间不会再上传。之前的备份和同步的家还在你自己的 iCloud 里。")
        }
    }

    /// The photo-library explanation before the first photos (`PhotoLibraryIntro`).
    var libraryIntroWords: String {
        switch self {
        case .thisDeviceOnly:
            String(localized: "喵空间只读取你亲手选进来的照片，不会翻看其他照片，也不会把任何照片上传。")
        case .iCloudDriveBackup:
            String(localized: "喵空间只读取你亲手选进来的照片，不会翻看其他照片。你打开了“备份到 iCloud 云盘”，喵空间存的照片（较小的照片和在 App 里拍的照片就是原文件）会随备份存进你自己的 iCloud 云盘。")
        case .iCloudSync:
            String(localized: "喵空间只读取你亲手选进来的照片，不会翻看其他照片。你打开了 iCloud 同步，喵空间存的照片（较小的照片和在 App 里拍的照片就是原文件）会通过 Apple 的 iCloud 同步到你自己的设备。")
        case .backupAndSync:
            String(localized: "喵空间只读取你亲手选进来的照片，不会翻看其他照片。你打开了 iCloud 同步和“备份到 iCloud 云盘”，喵空间存的照片（较小的照片和在 App 里拍的照片就是原文件）会通过 Apple 的 iCloud 同步到你自己的设备，也会随备份存进你自己的 iCloud 云盘。")
        case .offWithBackupsLeft:
            String(localized: "喵空间只读取你亲手选进来的照片，不会翻看其他照片。现在不会上传任何照片，但之前存进你自己 iCloud 云盘的备份还在，里面有喵空间存的照片副本。")
        case .offWithSyncDataLeft:
            String(localized: "喵空间只读取你亲手选进来的照片，不会翻看其他照片。现在不会上传任何照片，但之前同步的家还在你自己的 iCloud 里，里面有喵空间存的照片副本。")
        case .offWithBothLeft:
            String(localized: "喵空间只读取你亲手选进来的照片，不会翻看其他照片。现在不会上传任何照片，但之前的备份和同步的家还在你自己的 iCloud 里，里面有喵空间存的照片副本。")
        }
    }

    /// 关于与隐私 › 你的照片.
    var aboutPhotosWords: String {
        switch self {
        case .thisDeviceOnly:
            String(localized: "照片保存在这台设备上，喵空间不会把它们传到任何服务器。如果你用了设备备份（iCloud 或电脑），系统会把它们一起备份。")
        case .iCloudDriveBackup:
            String(localized: "照片保存在这台设备上。你打开了“备份到 iCloud 云盘”，备份里的照片副本存在你自己的 iCloud 云盘，由系统上传，开发者拿不到。喵空间没有自己的服务器。如果你用了设备备份（iCloud 或电脑），系统会把它们一起备份。")
        case .iCloudSync:
            String(localized: "照片保存在这台设备上。你打开了 iCloud 同步，喵空间存的照片副本还会通过 Apple 的 iCloud 同步到你自己的其他设备，开发者拿不到。如果你用了设备备份（iCloud 或电脑），系统会把它们一起备份。")
        case .backupAndSync:
            String(localized: "照片保存在这台设备上。你打开了 iCloud 同步和“备份到 iCloud 云盘”：喵空间存的照片副本会通过 Apple 的 iCloud 同步到你自己的其他设备，备份存在你自己的 iCloud 云盘，开发者都拿不到。如果你用了设备备份（iCloud 或电脑），系统会把它们一起备份。")
        case .offWithBackupsLeft:
            String(localized: "照片保存在这台设备上，喵空间不会再上传。之前存进你自己 iCloud 云盘的备份还在，里面有照片副本，可以在“文件”App 的 iCloud 云盘 › Meowverse 里删除。开发者拿不到它们，喵空间没有自己的服务器。如果你用了设备备份（iCloud 或电脑），系统会把它们一起备份。")
        case .offWithSyncDataLeft:
            String(localized: "照片保存在这台设备上，喵空间不会再上传。之前同步的家还在你自己的 iCloud 里，包括照片副本。开发者拿不到它们，喵空间没有自己的服务器。如果你用了设备备份（iCloud 或电脑），系统会把它们一起备份。")
        case .offWithBothLeft:
            String(localized: "照片保存在这台设备上，喵空间不会再上传。之前的备份和同步的家还在你自己的 iCloud 里，包括照片副本，备份可以在“文件”App 的 iCloud 云盘 › Meowverse 里删除。开发者拿不到它们，喵空间没有自己的服务器。如果你用了设备备份（iCloud 或电脑），系统会把它们一起备份。")
        }
    }
}
