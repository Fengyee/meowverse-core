import BackgroundAssets
import ExtensionFoundation
import StoreKit

/// The downloader extension for the built-in cats' 低 (later 高) meshes: Apple-hosted, managed
/// Background Assets (docs/CAT_PACK.md, "按需下载"). The system runs it to fetch and update asset
/// packs while the app is not running. Every cat asset pack is `onDemand` and the app asks for it
/// (`BackgroundAssetsCatTierTransport`), so the default implementation does everything: no
/// `shouldDownload(_:)` filter on purpose. Built from Xcode's "Background Download" template,
/// "Apple-Hosted, Managed". Its App Group is the app's (`BAAppGroupID` in Meowverse-Info.plist).
@main
struct MeowverseAssetDownloader: StoreDownloaderExtension {}
