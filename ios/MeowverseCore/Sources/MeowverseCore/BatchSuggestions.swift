import Foundation

// "建议归位": after photos are imported together, the app offers to file the ones that clearly
// belong to a piece already holding photos, on a confirmation page. Nothing is filed until the
// user confirms; a photo the user unticks or declines is never offered again; a photo already in
// a piece of furniture is never offered a move. The review asks about the most representative
// photos first, so the user's first few filings make the most other photos suggestible.

/// Every number the batch suggestions use, in one place. Fixed for every user, never tuned per
/// library (lead decision, 2026-11-17). Where they come from: `RECOGNITION_NOTES.md`, sections
/// "Margin rule scored on photos it was not chosen on (2026-11-17)" and "2026-11-17 DINOv2 as a
/// Core ML model". Distances are squared Euclidean between prints (`FeaturePrint.distance`).
public enum BatchSuggestionSettings {
    /// The `k` closest filed photos must all be in one piece, and only that piece.
    public static let neighbours = 2
    /// The closest filed photo of any other label (another piece or a photo board) must be at
    /// least this many times as far as the `k`-th closest.
    public static let margin: Float = 1.25
    /// The closest filed photo must be this close (`d`). 0.42 (the 2nd percentile of squared pair
    /// distances on the evaluation photos) turned out too strict on a real library on the phone
    /// (2026-11-18): photos of one piece sat 0.24 to 0.63 from each other, unrelated ones from
    /// about 0.8, and only 3 of 19 unfiled photos were offered. Loosened by the owner's decision;
    /// `k` and the margin still keep ambiguous photos out, and nothing is filed unconfirmed.
    public static let maximumDistance: Float = 0.6
    /// Two unfiled photos closer than this are neighbours when choosing which photo to ask about
    /// next: the 5th percentile of the same pair distances.
    public static let neighbourhoodRadius: Float = 0.52
    /// How many photos of a batch are asked about in representative order before the review
    /// goes back to the order the photos were picked in.
    public static let representativeRound = 10
    /// Smaller batches keep the order the photos were picked in.
    public static let representativeMinimumBatch = 12

    /// Recorded on every accepted suggestion (`PhotoObservation.analyzer`). Raise the revision
    /// whenever the rule or one of its numbers changes, so records say which rule made them.
    /// Revision 1 is the first rule that reached a build: k 2, margin 1.25, d 0.42 on DINOv2.
    /// Revision 2: d 0.6.
    public static let analyzer = "suggest.similarPhotos"
    public static let analyzerRevision = 2

    public static var rule: AutoFileRule {
        AutoFileRule(neighbours: neighbours, maximumDistance: maximumDistance, margin: margin)
    }

    /// The numbers above were measured on DINOv2 prints. Vision's prints are on another scale
    /// and do not separate pieces, so with them (the fallback when the model cannot load) there
    /// are no batch suggestions and no representative order. The colour grid is the UI tests'
    /// stand-in (DEBUG launch switch only).
    public static let measuredOn: Set<String> = [KnownAnalyzer.dinoV2, ColorGridEmbedder.analyzerName]

    /// Whether batch suggestions and the representative order run with prints of `analyzer`.
    public static func applies(to analyzer: String) -> Bool {
        measuredOn.contains(analyzer)
    }

    /// Photos asked about in representative order for a batch of `count` photos.
    public static func representativeRound(forBatchOf count: Int) -> Int {
        count >= representativeMinimumBatch ? representativeRound : 0
    }
}

/// An offer to file one photo into one piece. `fromBoards` are the photo boards the photo was on
/// when the offer was made (empty for an unfiled photo); accepting takes it off exactly those.
public struct BatchSuggestion: Sendable, Hashable, Identifiable {
    public var id: String { photoId }
    public let photoId: String
    public let instanceId: String
    /// The closest filed photo of that piece, and how far it is.
    public let closestPhotoId: String
    public let distance: Float
    public let fromBoards: Set<String>

    public init(photoId: String, instanceId: String, closestPhotoId: String, distance: Float, fromBoards: Set<String> = []) {
        self.photoId = photoId
        self.instanceId = instanceId
        self.closestPhotoId = closestPhotoId
        self.distance = distance
        self.fromBoards = fromBoards
    }

    /// What the user confirms on the page: this photo into this piece.
    public var choice: SuggestionChoice { SuggestionChoice(photoId: photoId, instanceId: instanceId) }
}

/// One ticked photo on the confirmation page, with the piece the page showed it under.
public struct SuggestionChoice: Sendable, Hashable {
    public let photoId: String
    public let instanceId: String

    public init(photoId: String, instanceId: String) {
        self.photoId = photoId
        self.instanceId = instanceId
    }
}

/// The offers for one piece, for the confirmation page.
public struct SuggestionGroup: Sendable, Equatable, Identifiable {
    public var id: String { instanceId }
    public let instanceId: String
    public let offers: [BatchSuggestion]
}

/// A photo that may be offered, with the photo boards it is on now.
public struct SuggestionCandidate: Sendable, Equatable {
    public let photoId: String
    public let boards: Set<String>

    public init(photoId: String, boards: Set<String> = []) {
        self.photoId = photoId
        self.boards = boards
    }
}

/// Which photos a run of suggestions looks at.
public enum SuggestionScope: Sendable, Equatable {
    /// These photos, as far as they are in no furniture at all (a batch, or everything in 待整理).
    case unfiled([String])
    /// Every photo that is on a photo board and in no other piece.
    case photoBoards
}

public enum BatchSuggestions {
    /// Every link in the home as a reference: which piece holds which photo, and whether that
    /// piece is a photo board (boards vote as another label but are never offered).
    public static func links(in state: AppState, catalog: FurnitureCatalog) -> (links: [(instanceId: String, photoId: String)], boards: Set<String>) {
        let all = state.items + state.storage
        let boards = Set(all.filter { catalog.model(id: $0.modelId)?.category == .photoBoard }.map(\.instanceId))
        return (all.flatMap { piece in piece.sources.map { (piece.instanceId, $0.photoId) } }, boards)
    }

    /// The photos of `scope` that may be offered. Never a photo in a piece that is not a board.
    public static func candidates(_ scope: SuggestionScope, in state: AppState, catalog: FurnitureCatalog) -> [SuggestionCandidate] {
        let (links, boards) = links(in: state, catalog: catalog)
        var holders: [String: Set<String>] = [:]
        for link in links { holders[link.photoId, default: []].insert(link.instanceId) }
        let known = Set(state.photos.map(\.photoId))
        switch scope {
        case .unfiled(let ids):
            var seen = Set<String>()
            return ids.filter { known.contains($0) && holders[$0] == nil && seen.insert($0).inserted }
                .map { SuggestionCandidate(photoId: $0) }
        case .photoBoards:
            return state.photos.compactMap { photo in
                guard let held = holders[photo.photoId], !held.isEmpty, held.isSubset(of: boards) else { return nil }
                return SuggestionCandidate(photoId: photo.photoId, boards: held)
            }
        }
    }

    /// The offers, in the order of `candidates`. `references` are the filed photos with their
    /// prints (pieces and boards alike); `boards` are never offered. A candidate is never judged
    /// against its own print, and declined photos are never offered.
    public static func offers(for candidates: [SuggestionCandidate], prints: [String: FeaturePrint],
                              references: [FurniturePhotoPrint], boards: Set<String>, declined: Set<String>,
                              rule: AutoFileRule = BatchSuggestionSettings.rule) -> [BatchSuggestion] {
        candidates.compactMap { candidate in
            guard !declined.contains(candidate.photoId), let print = prints[candidate.photoId] else { return nil }
            let others = references.filter { $0.photoId != candidate.photoId }
            guard let match = rule.piece(for: print, among: others, notOffered: boards),
                  !boards.contains(match.instanceId) else { return nil }
            return BatchSuggestion(photoId: candidate.photoId, instanceId: match.instanceId, closestPhotoId: match.photoId,
                                   distance: match.distance, fromBoards: candidate.boards)
        }
    }

    /// Offers by piece: the piece with the most offers first, then by its first offer.
    public static func byPiece(_ offers: [BatchSuggestion]) -> [SuggestionGroup] {
        var order: [String] = []
        var members: [String: [BatchSuggestion]] = [:]
        for offer in offers {
            if members[offer.instanceId] == nil { order.append(offer.instanceId) }
            members[offer.instanceId, default: []].append(offer)
        }
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return order.sorted { a, b in
            let ca = members[a]!.count, cb = members[b]!.count
            return ca != cb ? ca > cb : position[a]! < position[b]!
        }.map { SuggestionGroup(instanceId: $0, offers: members[$0]!) }
    }

    /// The offers of `current` (worked out from the home as it is now) that the user confirmed:
    /// the same photo for the same piece as on the page. A photo whose offer has since moved to
    /// another piece is left alone, so nothing goes into a piece the user was not shown.
    public static func confirmed(_ chosen: Set<SuggestionChoice>, among current: [BatchSuggestion]) -> [BatchSuggestion] {
        current.filter { chosen.contains($0.choice) }
    }

    /// Whether `offer` still describes the home: the photo is still on exactly the boards it was
    /// on and in no other piece, and the target piece is still there. A photo the user filed or
    /// moved by hand since the offer was made fails, so the offer can never undo that.
    public static func isCurrent(_ offer: BatchSuggestion, in state: AppState, catalog: FurnitureCatalog) -> Bool {
        let all = state.items + state.storage
        guard state.photo(id: offer.photoId) != nil,
              let target = all.first(where: { $0.instanceId == offer.instanceId }),
              catalog.model(id: target.modelId)?.category != .photoBoard else { return false }
        let holding = Set(all.filter { $0.sources.contains { $0.photoId == offer.photoId } }.map(\.instanceId))
        return holding == offer.fromBoards
    }
}

/// Which photo of a batch to ask about next, so that the first few answers make the most other
/// photos suggestible: the photo with the most unfiled neighbours (within
/// `BatchSuggestionSettings.neighbourhoodRadius`). Measured on the owner's 168 photos with
/// DINOv2-B (lead, 2026-11-17): hand-filing the first 10 in this order made 56–65 others
/// suggestible, against 39–50 in time order.
public enum RepresentativeOrder {
    /// The photo to ask about next among `pool` (the unfiled photos, in the order they were
    /// picked). Neighbours are counted among all of `pool`; only photos with a print that
    /// `isEligible` allows (not declined, not on the confirmation page) can be chosen. Ties go to
    /// the earlier capture day (unknown days last), then to the earlier position in `pool`.
    public static func next(in pool: [String], prints: [String: FeaturePrint], days: [String: String],
                            isEligible: (String) -> Bool = { _ in true },
                            radius: Float = BatchSuggestionSettings.neighbourhoodRadius) -> String? {
        let printed = pool.filter { prints[$0] != nil }
        var best: (id: String, count: Int, day: String?, index: Int)?
        for (index, id) in printed.enumerated() where isEligible(id) {
            let print = prints[id]!
            var count = 0
            for other in printed where other != id {
                if let d = print.distance(to: prints[other]!), d <= radius { count += 1 }
            }
            let day = days[id]
            if let current = best {
                if count < current.count { continue }
                if count == current.count {
                    switch (day, current.day) {
                    case let (a?, b?) where a != b: if a > b { continue }
                    case (nil, _?): continue
                    case (_?, nil): break
                    default: if index > current.index { continue }
                    }
                }
            }
            best = (id, count, day, index)
        }
        return best?.id
    }

    /// The review queue: up to `picks` photos chosen one after another by `next` (each one as if
    /// the one before had been filed), then the rest of `order` as it was. With `picks` 0 this is
    /// `order` itself. The real next photo is chosen again after every filing and every answer
    /// on the confirmation page; this queue is what the review would do from here.
    public static func queue(_ order: [String], prints: [String: FeaturePrint], days: [String: String],
                             excluded: Set<String> = [], picks: Int,
                             radius: Float = BatchSuggestionSettings.neighbourhoodRadius) -> [String] {
        let chosen = self.picks(order, prints: prints, days: days, excluded: excluded, count: picks, radius: radius)
        let taken = Set(chosen)
        return chosen + order.filter { !taken.contains($0) }
    }

    /// The first part of `queue`: at most `count` photos, fewer when no photo with a print is
    /// left to choose (the rest are declined, on the confirmation page or have no print).
    public static func picks(_ order: [String], prints: [String: FeaturePrint], days: [String: String],
                             excluded: Set<String> = [], count: Int,
                             radius: Float = BatchSuggestionSettings.neighbourhoodRadius) -> [String] {
        var pool = order
        var chosen: [String] = []
        for _ in 0..<max(0, count) {
            guard let pick = next(in: pool, prints: prints, days: days, isEligible: { !excluded.contains($0) }, radius: radius) else { break }
            chosen.append(pick)
            pool.removeAll { $0 == pick }
        }
        return chosen
    }
}

/// How a photo came to be on a piece, for the interface and the records.
public enum FilingProvenance: Sendable, Equatable {
    /// The user chose the piece themselves.
    case handPicked
    /// A category recognition the user kept (`mode` says on this device, or the web's cloud analysis).
    case recognised(AnalysisMode)
    /// Offered by the app because it looks like the piece's other photos, and confirmed by the
    /// user on the batch confirmation page.
    case suggestedBySimilarPhotos
    /// Demo data.
    case demo
}

extension AppState {
    public func provenance(of source: PhotoCarrierSource) -> FilingProvenance {
        switch source.origin {
        case .user: return .handPicked
        case .curatedFixture: return .demo
        case .model:
            guard let id = source.observationId, let observation = observation(id: id) else { return .recognised(.onDevice) }
            if observation.analyzer == BatchSuggestionSettings.analyzer { return .suggestedBySimilarPhotos }
            return .recognised(observation.mode)
        }
    }
}
