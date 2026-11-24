import MeowverseCore
import Photos

enum PhotoDelivery {
    /// `timeZone` is the one the confirmation used to explain the copies' dates.
    nonisolated static func save(_ files: [PhotoExport], timeZone: TimeZone) async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
        guard status == .authorized || status == .limited else { throw PhotoDeliveryError.addPermission }
        try Task.checkCancellation()
        try await PHPhotoLibrary.shared().performChanges {
            for file in files {
                let request = PHAssetCreationRequest.forAsset()
                // The plan the confirmation explained: an unknown day, or a day the zone skipped
                // entirely, gets no date rather than a neighbouring one.
                if let date = file.copyDate(in: timeZone).creationDate { request.creationDate = date }
                request.addResource(with: .photo, fileURL: file.url, options: nil)
            }
        }
    }

    /// Add existing assets to a regular album, without creating a second image or changing the library bindings.
    nonisolated static func collect(_ photos: [PhotoRecord], linked: Bool) async throws -> Int {
        var assets: [PHAsset] = []
        for photo in photos {
            try Task.checkCancellation()
            do { assets.append(try await PhotoLibraryLink.asset(for: photo, linked: linked)) }
            catch PhotoSourceIssue.missing { continue }
            catch PhotoSourceIssue.unlinked { continue }
        }
        guard !assets.isEmpty else { throw PhotoDeliveryError.noOriginals }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", "Meowverse")
        let album = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options).firstObject
        if let album, !album.canPerform(.addContent) { throw PhotoDeliveryError.albumUnavailable }
        let selected = assets
        try Task.checkCancellation()
        try await PHPhotoLibrary.shared().performChanges {
            let change: PHAssetCollectionChangeRequest
            if let album {
                guard let request = PHAssetCollectionChangeRequest(for: album) else { return }
                change = request
            } else {
                change = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "Meowverse")
            }
            change.addAssets(selected as NSArray)
        }
        // Confirm membership, including assets already in the album.
        guard let saved = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options).firstObject else {
            throw PhotoDeliveryError.albumUnavailable
        }
        let lookup = PHFetchOptions()
        lookup.predicate = NSPredicate(format: "localIdentifier IN %@", selected.map(\.localIdentifier))
        return PHAsset.fetchAssets(in: saved, options: lookup).count
    }
}

enum PhotoDeliveryError: Error {
    case addPermission, noOriginals, albumUnavailable
}
