import Foundation
import Synchronization
import Testing
@testable import MeowverseCore

/// "建议归位": strict offers on a confirmation page, the representative review order, and how
/// a confirmed suggestion is recorded and undone.
@Suite struct BatchSuggestionTests {
    private func p(_ values: Float...) -> FeaturePrint {
        FeaturePrint(analyzer: "test", revision: 1, vector: values)
    }

    private func ref(_ piece: String, _ photo: String, _ print: FeaturePrint) -> FurniturePhotoPrint {
        FurniturePhotoPrint(instanceId: piece, photoId: photo, print: print)
    }

    private func offers(_ candidates: [String], prints: [String: FeaturePrint], references: [FurniturePhotoPrint],
                        boards: Set<String> = [], declined: Set<String> = []) -> [BatchSuggestion] {
        BatchSuggestions.offers(for: candidates.map { SuggestionCandidate(photoId: $0) }, prints: prints,
                                references: references, boards: boards, declined: declined)
    }

    // MARK: The fixed rule

    @Test func theRuleIsFixedAtTwoNeighboursAndAMarginOfOnePointTwoFive() {
        let rule = BatchSuggestionSettings.rule
        #expect(rule.neighbours == 2)
        #expect(rule.margin == 1.25)
        #expect(rule.maximumDistance == BatchSuggestionSettings.maximumDistance)
        #expect(rule.minimumPhotos == 1)
        // Measured on DINOv2 prints of the owner's photos, through the app's own print path.
        #expect(BatchSuggestionSettings.maximumDistance == 0.6, "2nd percentile of squared pair distances")
        #expect(BatchSuggestionSettings.neighbourhoodRadius == 0.52, "5th percentile")
        #expect(BatchSuggestionSettings.representativeRound(forBatchOf: 11) == 0)
        #expect(BatchSuggestionSettings.representativeRound(forBatchOf: 12) == 10)
        #expect(BatchSuggestionSettings.representativeRound(forBatchOf: 100) == 10)
    }

    /// The numbers were measured on DINOv2 prints only. On Vision's scale they mean nothing and
    /// Vision prints do not separate pieces, so with the Vision fallback there are no batch
    /// suggestions and no representative order (the per-photo look-alike rows stay).
    @Test func suggestionsRunOnlyOnPrintsTheNumbersWereMeasuredOn() {
        #expect(BatchSuggestionSettings.applies(to: KnownAnalyzer.dinoV2))
        #expect(KnownAnalyzer.dinoV2 == "dinov2.vitb14reg.int8.meanpatch")
        #expect(BatchSuggestionSettings.applies(to: ColorGridEmbedder().analyzer), "the UI tests' stand-in")
        for other in [VisionPhotoEmbedder(masking: .none).analyzer, VisionPhotoEmbedder(masking: .coverCat).analyzer,
                      "dinov2.vitb14reg.fp16.meanpatch", "", "test"] {
            #expect(!BatchSuggestionSettings.applies(to: other), "\(other)")
        }
    }

    @Test func aPhotoWhoseTwoClosestFiledPhotosAreOnePieceIsOffered() {
        let refs = [ref("sofa", "s1", p(0, 0)), ref("sofa", "s2", p(0.1, 0)), ref("bed", "b1", p(3, 0))]
        let result = offers(["new"], prints: ["new": p(0.05, 0.05)], references: refs)
        #expect(result.map(\.instanceId) == ["sofa"])
        #expect(result.first?.closestPhotoId == "s1" || result.first?.closestPhotoId == "s2")
        #expect(result.first?.fromBoards == [])
    }

    @Test func oneFiledPhotoIsNotEnough() {
        let result = offers(["new"], prints: ["new": p(0, 0.01)], references: [ref("sofa", "s1", p(0, 0))])
        #expect(result.isEmpty, "k = 2 needs two filed photos")
    }

    @Test func theSecondClosestMustBeInTheSamePiece() {
        let refs = [ref("sofa", "s1", p(0, 0)), ref("bed", "b1", p(0.1, 0)), ref("sofa", "s2", p(0.2, 0))]
        #expect(offers(["new"], prints: ["new": p(0, 0)], references: refs).isEmpty)
    }

    @Test func tooFarAwayIsNotOffered() {
        let d = BatchSuggestionSettings.maximumDistance
        let refs = [ref("sofa", "s1", p(0, 0)), ref("sofa", "s2", p(0, 0))]
        // Squared distance just inside and just outside the cut.
        #expect(offers(["in"], prints: ["in": p((d * 0.99).squareRoot(), 0)], references: refs).count == 1)
        #expect(offers(["out"], prints: ["out": p((d * 1.01).squareRoot(), 0)], references: refs).isEmpty)
    }

    @Test func anotherLabelCloserThanTheMarginBlocksTheOffer() {
        // The 2nd closest sofa photo is at squared distance 0.01.
        let base = [ref("sofa", "s1", p(0, 0)), ref("sofa", "s2", p(0.1, 0))]
        let query = ["new": p(0, 0)]
        // Another piece at 1.2 × 0.01: blocked. At 1.3 × 0.01: offered.
        let blocked = base + [ref("bed", "b1", p(0, (0.012 as Float).squareRoot()))]
        let clear = base + [ref("bed", "b1", p(0, (0.013 as Float).squareRoot()))]
        #expect(offers(["new"], prints: query, references: blocked).isEmpty)
        #expect(offers(["new"], prints: query, references: clear).map(\.instanceId) == ["sofa"])
    }

    @Test func photoBoardsCountAsAnotherLabelAndAreNeverTheTarget() {
        // Two board photos closest: never offered to the board.
        let onlyBoard = [ref("wall", "w1", p(0, 0)), ref("wall", "w2", p(0.1, 0)), ref("sofa", "s1", p(3, 0)), ref("sofa", "s2", p(3, 0.1))]
        #expect(offers(["new"], prints: ["new": p(0, 0)], references: onlyBoard, boards: ["wall"]).isEmpty)
        // A board photo just behind the sofa's photos blocks through the margin.
        let boardClose = [ref("sofa", "s1", p(0, 0)), ref("sofa", "s2", p(0.1, 0)), ref("wall", "w1", p(0, 0.105))]
        #expect(offers(["new"], prints: ["new": p(0, 0)], references: boardClose, boards: ["wall"]).isEmpty)
    }

    @Test func declinedPhotosAreNeverOfferedAgain() {
        let refs = [ref("sofa", "s1", p(0, 0)), ref("sofa", "s2", p(0.1, 0))]
        let prints = ["a": p(0, 0), "b": p(0.05, 0)]
        #expect(offers(["a", "b"], prints: prints, references: refs).map(\.photoId) == ["a", "b"])
        #expect(offers(["a", "b"], prints: prints, references: refs, declined: ["a"]).map(\.photoId) == ["b"])
    }

    @Test func aPhotoWithoutAPrintIsNotOffered() {
        let refs = [ref("sofa", "s1", p(0, 0)), ref("sofa", "s2", p(0.1, 0))]
        #expect(offers(["a"], prints: [:], references: refs).isEmpty)
    }

    @Test func aBoardPhotoIsNeverJudgedAgainstItsOwnPrint() {
        // "w1" is on the board and is the candidate: its own print (distance 0) must not block it.
        let refs = [ref("wall", "w1", p(0, 0)), ref("sofa", "s1", p(0.05, 0)), ref("sofa", "s2", p(0.1, 0))]
        let result = BatchSuggestions.offers(for: [SuggestionCandidate(photoId: "w1", boards: ["wall"])], prints: ["w1": p(0, 0)],
                                             references: refs, boards: ["wall"], declined: [])
        #expect(result.map(\.instanceId) == ["sofa"])
        #expect(result.first?.fromBoards == ["wall"])
    }

    @Test func offersAreGroupedByPieceLargestFirst() {
        let offers = [
            BatchSuggestion(photoId: "1", instanceId: "bed", closestPhotoId: "x", distance: 0),
            BatchSuggestion(photoId: "2", instanceId: "sofa", closestPhotoId: "x", distance: 0),
            BatchSuggestion(photoId: "3", instanceId: "sofa", closestPhotoId: "x", distance: 0),
            BatchSuggestion(photoId: "4", instanceId: "chair", closestPhotoId: "x", distance: 0),
        ]
        let groups = BatchSuggestions.byPiece(offers)
        #expect(groups.map(\.instanceId) == ["sofa", "bed", "chair"])
        #expect(groups.first?.offers.map(\.photoId) == ["2", "3"])
    }

    // MARK: Which photos may be offered

    private func home() throws -> (AppState, FurnitureCatalog) {
        let catalog = try FurnitureCatalog.bundled()
        func photo(_ id: String) -> PhotoRecord {
            PhotoRecord(photoId: id, filename: nil, sha256: id, mimeType: "image/jpeg", byteSize: 1, width: 1, height: 1,
                        originalFile: "originals/\(id).jpeg", thumbnailFile: "thumbnails/\(id).jpg", captureDate: nil,
                        captureDateSource: .unknown, exifCaptureDate: nil, importedAt: Date(timeIntervalSince1970: 0), revision: 1)
        }
        func piece(_ id: String, _ model: String, _ photos: [String]) -> PhotoFurniture {
            PhotoFurniture(instanceId: id, modelId: model, x: 0, z: 0, width: 2, depth: 2, turn: 0, finish: .original,
                           displayName: id, sources: photos.map { .manual(photoId: $0) }, tags: [], revision: 1)
        }
        var state = AppState.empty
        state.photos = ["free", "inSofa", "onWall", "wallAndSofa", "stored"].map(photo)
        state.items = [piece("sofa", "kenney-chair", ["inSofa", "wallAndSofa"]),
                       piece("wall", "wall-photo-board", ["onWall", "wallAndSofa"])]
        state.storage = [piece("box", "kenney-chair", ["stored"])]
        return (state, catalog)
    }

    @Test func onlyPhotosInNoFurnitureAreUnfiledCandidates() throws {
        let (state, catalog) = try home()
        let ids = ["free", "inSofa", "onWall", "stored", "gone", "free"]
        #expect(BatchSuggestions.candidates(.unfiled(ids), in: state, catalog: catalog) == [SuggestionCandidate(photoId: "free")])
    }

    @Test func boardCandidatesAreNeverAlsoInAPiece() throws {
        let (state, catalog) = try home()
        #expect(BatchSuggestions.candidates(.photoBoards, in: state, catalog: catalog) == [SuggestionCandidate(photoId: "onWall", boards: ["wall"])])
    }

    @Test func anOfferStopsBeingCurrentOnceThePhotoIsFiledByHand() throws {
        var (state, catalog) = try home()
        let offer = BatchSuggestion(photoId: "free", instanceId: "sofa", closestPhotoId: "inSofa", distance: 0)
        #expect(BatchSuggestions.isCurrent(offer, in: state, catalog: catalog))
        state.storage[0].sources.append(.manual(photoId: "free"))
        #expect(!BatchSuggestions.isCurrent(offer, in: state, catalog: catalog), "the hand filing wins")
        let boardOffer = BatchSuggestion(photoId: "onWall", instanceId: "sofa", closestPhotoId: "inSofa", distance: 0, fromBoards: ["wall"])
        #expect(BatchSuggestions.isCurrent(boardOffer, in: state, catalog: catalog))
        let toBoard = BatchSuggestion(photoId: "onWall", instanceId: "wall", closestPhotoId: "x", distance: 0, fromBoards: ["wall"])
        #expect(!BatchSuggestions.isCurrent(toBoard, in: state, catalog: catalog), "a board is never a target")
        let gone = BatchSuggestion(photoId: "free", instanceId: "nowhere", closestPhotoId: "x", distance: 0)
        #expect(!BatchSuggestions.isCurrent(gone, in: state, catalog: catalog))
    }

    /// The confirmation page is a snapshot; the offers are worked out again before filing. A
    /// photo whose offer now names another piece than the one the user saw is not filed: the
    /// user confirmed "this photo into that piece", not "this photo anywhere" (QA, round 8).
    @Test func aConfirmationOnlyFilesThePhotoIntoThePieceThePageShowed() {
        let shown = [BatchSuggestion(photoId: "p", instanceId: "sofa", closestPhotoId: "a", distance: 0.1),
                     BatchSuggestion(photoId: "q", instanceId: "sofa", closestPhotoId: "a", distance: 0.1)]
        let now = [BatchSuggestion(photoId: "p", instanceId: "stool", closestPhotoId: "b", distance: 0.1),
                   BatchSuggestion(photoId: "q", instanceId: "sofa", closestPhotoId: "a", distance: 0.2),
                   BatchSuggestion(photoId: "r", instanceId: "sofa", closestPhotoId: "a", distance: 0.1)]
        let chosen = Set(shown.map(\.choice))
        #expect(BatchSuggestions.confirmed(chosen, among: now).map(\.photoId) == ["q"],
                "p now points at the stool, which the page never showed; r was never on the page")
        #expect(BatchSuggestions.confirmed([], among: now).isEmpty)
    }

    // MARK: Representative order

    /// Three photos close together (a, b, c), two (d, e), one alone (f); radius covers the clusters.
    private var clusters: [String: FeaturePrint] {
        ["a": p(0, 0), "b": p(0.1, 0), "c": p(0, 0.1), "d": p(5, 0), "e": p(5.1, 0), "f": p(9, 9)]
    }

    @Test func nextIsThePhotoWithTheMostUnfiledNeighbours() {
        let order = ["f", "d", "e", "c", "b", "a"]
        #expect(["a", "b", "c"].contains(RepresentativeOrder.next(in: order, prints: clusters, days: [:], radius: 0.05)!))
        // Ties among a, b, c go to the earlier position in today's order.
        #expect(RepresentativeOrder.next(in: order, prints: clusters, days: [:], radius: 0.05) == "c")
        // Without the dense cluster, the pair wins over the lone photo.
        #expect(RepresentativeOrder.next(in: ["f", "d", "e"], prints: clusters, days: [:], radius: 0.05) == "d")
    }

    @Test func tiesGoToTheEarlierCaptureDayThenUnknownDaysLast() {
        let order = ["c", "b", "a"]
        #expect(RepresentativeOrder.next(in: order, prints: clusters, days: ["a": "2020-01-01", "b": "2021-01-01"], radius: 0.05) == "a")
        #expect(RepresentativeOrder.next(in: order, prints: clusters, days: ["b": "2021-01-01"], radius: 0.05) == "b")
    }

    @Test func declinedOrOfferedPhotosAreNotAskedButStillCountAsNeighbours() {
        let order = ["a", "b", "c", "d", "e", "f"]
        let next = RepresentativeOrder.next(in: order, prints: clusters, days: [:], isEligible: { !["a", "b"].contains($0) }, radius: 0.05)
        #expect(next == "c", "c still has two unfiled neighbours")
    }

    @Test func theQueueAsksRepresentativesFirstThenKeepsTodaysOrder() {
        let order = ["f", "d", "e", "c", "b", "a"]
        #expect(RepresentativeOrder.queue(order, prints: clusters, days: [:], picks: 0, radius: 0.05) == order)
        let queue = RepresentativeOrder.queue(order, prints: clusters, days: [:], picks: 2, radius: 0.05)
        // c first; then a, b, d and e each have one neighbour left, and d comes first in today's order.
        #expect(queue == ["c", "d", "f", "e", "b", "a"])
        // A photo without a print is never picked but keeps its place.
        var partial = clusters
        partial["c"] = nil
        #expect(RepresentativeOrder.queue(order, prints: partial, days: [:], picks: 1, radius: 0.05) == ["d", "f", "e", "c", "b", "a"])
    }

    /// The round shows how many representatives there are; with fewer photos left to choose
    /// from than asked for, there are fewer.
    @Test func picksStopWhenNoPhotoIsLeftToChoose() {
        let order = ["f", "d", "e", "c", "b", "a"]
        #expect(RepresentativeOrder.picks(order, prints: clusters, days: [:], count: 2, radius: 0.05) == ["c", "d"])
        let few = RepresentativeOrder.picks(order, prints: clusters, days: [:], excluded: ["a", "b", "c", "d"], count: 10, radius: 0.05)
        #expect(few == ["e", "f"] || few == ["f", "e"])
        #expect(few.count == 2)
        #expect(RepresentativeOrder.picks(order, prints: [:], days: [:], count: 10).isEmpty, "no prints, no picks")
    }

    // MARK: Recording a confirmed suggestion

    private let sofaAt44 = Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2)
    private let stoolAt00 = Placement(modelId: "kenney-stoolBar", x: 0, z: 0, width: 1, depth: 1)
    private let boardOnLeft = Placement(modelId: "wall-photo-board", x: 3, z: 0, width: 3, depth: 1, wall: .left)

    private func sandbox() -> (parent: URL, root: URL) {
        let parent = TestSupport.tempDir()
        return (parent, parent.appendingPathComponent("store", isDirectory: true))
    }

    private struct Fixture {
        let store: LibraryStore
        let sofa: String
        let stool: String
        let board: String
        let free: String
        let onBoard: String
    }

    private func fixture(_ root: URL) async throws -> Fixture {
        let store = LibraryStore(root: root, catalog: try FurnitureCatalog.bundled())
        let sofa = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 1), placement: sofaAt44, displayName: "沙发", decision: .manual)
        let stool = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 2), placement: stoolAt00, displayName: "凳子", decision: .manual)
        let board = try await store.addFurniture(placement: boardOnLeft, displayName: "")
        let free = try await store.addPhoto(draft: try TestSupport.draft(seed: 3))
        let onBoard = try await store.addPhoto(draft: try TestSupport.draft(seed: 4))
        _ = try await store.linkPhoto(photoId: onBoard.photoId, toInstance: board.instanceId)
        return Fixture(store: store, sofa: sofa.instanceId, stool: stool.instanceId, board: board.instanceId,
                       free: free.photoId, onBoard: onBoard.photoId)
    }

    @Test func aConfirmedSuggestionIsRecordedAsSuggestedAndConfirmedNotHandPicked() async throws {
        let (parent, root) = sandbox()
        defer { try? FileManager.default.removeItem(at: parent) }
        let f = try await fixture(root)
        let before = await f.store.snapshot()
        let receipt = try await f.store.fileSuggestions(
            [BatchSuggestion(photoId: f.free, instanceId: f.sofa, closestPhotoId: "x", distance: 0.1)], printsBy: "test.colorGrid")
        #expect(receipt.filed.map(\.photoId) == [f.free] && receipt.skipped.isEmpty)
        let after = await f.store.snapshot()
        #expect(after.revision == before.revision + 1, "one write")
        let link = try #require(after.item(id: f.sofa)?.sources.first { $0.photoId == f.free })
        #expect(link.origin == .model && link.objectIndex == 0 && link.addedAt != nil)
        let observationId = try #require(link.observationId)
        let observation = try #require(after.observation(id: observationId))
        #expect(observation.analyzer == BatchSuggestionSettings.analyzer)
        #expect(observation.analyzerRevision == BatchSuggestionSettings.analyzerRevision)
        #expect(observation.mode == .onDevice && observation.origin == .model && observation.photoId == f.free)
        #expect(observation.objects == [ObservedObject(kind: .chair, label: "test.colorGrid", confidence: 1)])
        #expect(after.provenance(of: link) == .suggestedBySimilarPhotos)
        let handPicked = try #require(after.item(id: f.sofa)?.sources.first { $0.photoId != f.free })
        #expect(after.provenance(of: handPicked) == .handPicked)
        #expect(await f.store.integrityReport().isClean)
        // Reloading reads the same record.
        let reopened = LibraryStore(root: root, catalog: try FurnitureCatalog.bundled())
        #expect(try await reopened.load() == after)
    }

    @Test func aMoveMadeByHandBeforeConfirmingWins() async throws {
        let (parent, root) = sandbox()
        defer { try? FileManager.default.removeItem(at: parent) }
        let f = try await fixture(root)
        let offer = BatchSuggestion(photoId: f.free, instanceId: f.sofa, closestPhotoId: "x", distance: 0.1)
        _ = try await f.store.linkPhoto(photoId: f.free, toInstance: f.stool)
        let before = await f.store.snapshot()
        let receipt = try await f.store.fileSuggestions([offer], printsBy: "t")
        #expect(receipt.filed.isEmpty && receipt.skipped == [f.free])
        #expect(await f.store.snapshot() == before, "nothing written")
    }

    @Test func aBoardPhotoLeavesItsBoardAndUndoPutsItBackWhereItWas() async throws {
        let (parent, root) = sandbox()
        defer { try? FileManager.default.removeItem(at: parent) }
        let f = try await fixture(root)
        let second = try await f.store.addPhoto(draft: try TestSupport.draft(seed: 5))
        _ = try await f.store.linkPhoto(photoId: second.photoId, toInstance: f.board)
        let before = await f.store.snapshot()
        #expect(before.item(id: f.board)?.sources.map(\.photoId) == [f.onBoard, second.photoId])
        let receipt = try await f.store.fileSuggestions(
            [BatchSuggestion(photoId: f.onBoard, instanceId: f.sofa, closestPhotoId: "x", distance: 0.1, fromBoards: [f.board]),
             BatchSuggestion(photoId: f.free, instanceId: f.stool, closestPhotoId: "x", distance: 0.1)], printsBy: "t")
        #expect(receipt.filed.count == 2)
        let filed = await f.store.snapshot()
        #expect(filed.item(id: f.board)?.sources.map(\.photoId) == [second.photoId])
        #expect(filed.item(id: f.sofa)?.sources.contains { $0.photoId == f.onBoard } == true)

        #expect(try await f.store.undoSuggestions(receipt) == 2)
        let undone = await f.store.snapshot()
        #expect(undone.item(id: f.board)?.sources == before.item(id: f.board)?.sources, "same links, same order")
        #expect(undone.item(id: f.sofa)?.sources == before.item(id: f.sofa)?.sources)
        #expect(undone.item(id: f.stool)?.sources == before.item(id: f.stool)?.sources)
        #expect(undone.observations == before.observations, "the suggestion's records go with it")
        #expect(await f.store.integrityReport().isClean)
    }

    @Test func aStaleBoardOfferIsSkipped() async throws {
        let (parent, root) = sandbox()
        defer { try? FileManager.default.removeItem(at: parent) }
        let f = try await fixture(root)
        let offer = BatchSuggestion(photoId: f.onBoard, instanceId: f.sofa, closestPhotoId: "x", distance: 0.1, fromBoards: [f.board])
        _ = try await f.store.unlinkPhoto(photoId: f.onBoard, fromInstance: f.board)
        let receipt = try await f.store.fileSuggestions([offer], printsBy: "t")
        #expect(receipt.filed.isEmpty && receipt.skipped == [f.onBoard], "taken off the board by hand since")
        let toBoard = BatchSuggestion(photoId: f.free, instanceId: f.board, closestPhotoId: "x", distance: 0.1)
        #expect(try await f.store.fileSuggestions([toBoard], printsBy: "t").filed.isEmpty, "a board is never a target")
    }

    @Test func undoLeavesAPhotoMovedByHandSinceAlone() async throws {
        let (parent, root) = sandbox()
        defer { try? FileManager.default.removeItem(at: parent) }
        let f = try await fixture(root)
        let receipt = try await f.store.fileSuggestions(
            [BatchSuggestion(photoId: f.free, instanceId: f.sofa, closestPhotoId: "x", distance: 0.1)], printsBy: "t")
        _ = try await f.store.movePhotos(photoIds: [f.free], fromInstance: f.sofa, toInstance: f.stool)
        let moved = await f.store.snapshot()
        #expect(try await f.store.undoSuggestions(receipt) == 0)
        #expect(await f.store.snapshot() == moved)
        let link = try #require(moved.item(id: f.stool)?.sources.first { $0.photoId == f.free })
        #expect(moved.provenance(of: link) == .handPicked, "the hand move is recorded as the user's")
    }

    @Test func aConfirmedSuggestionSurvivesABackupAndRestore() async throws {
        let (parentA, rootA) = sandbox(), (parentB, rootB) = sandbox()
        defer { try? FileManager.default.removeItem(at: parentA); try? FileManager.default.removeItem(at: parentB) }
        let f = try await fixture(rootA)
        _ = try await f.store.fileSuggestions(
            [BatchSuggestion(photoId: f.onBoard, instanceId: f.sofa, closestPhotoId: "x", distance: 0.1, fromBoards: [f.board])], printsBy: "t")
        let original = await f.store.snapshot()
        #expect(original.schemaVersion == 12, "no new fields: the schema did not change")
        let url = parentA.appendingPathComponent("backup.zip")
        _ = try await f.store.exportBackup(to: url, appVersion: "9.9")
        let catalog = try FurnitureCatalog.bundled()
        let target = LibraryStore(root: rootB, catalog: catalog)
        let prepared = try BackupArchive.prepare(file: url, stagingURL: target.makeStagingURL(), catalog: catalog)
        let restored = try await target.replaceLibrary(with: prepared)
        #expect(restored == original)
        let link = try #require(restored.item(id: f.sofa)?.sources.first { $0.photoId == f.onBoard })
        #expect(restored.provenance(of: link) == .suggestedBySimilarPhotos)
        #expect(await target.integrityReport().isClean)
    }

    @Test func otherModelLinksKeepTheirOwnProvenance() {
        var state = AppState.empty
        let vision = PhotoObservation(observationId: "o1", photoId: "p", origin: .model, mode: .onDevice, analyzer: "vision.classifyImage",
                                      analyzerRevision: 2, objects: [], createdAt: Date())
        let web = PhotoObservation(observationId: "o2", photoId: "p", origin: .model, mode: .remote, analyzer: "web-remote",
                                   analyzerRevision: 0, objects: [], createdAt: Date())
        state.observations = [vision, web]
        func link(_ id: String?, _ origin: SourceOrigin = .model) -> PhotoCarrierSource {
            PhotoCarrierSource(photoId: "p", observationId: id, objectIndex: id == nil ? nil : 0, origin: origin, relationToCat: .unclear)
        }
        #expect(state.provenance(of: link("o1")) == .recognised(.onDevice))
        #expect(state.provenance(of: link("o2")) == .recognised(.remote))
        #expect(state.provenance(of: link(nil, .user)) == .handPicked)
        #expect(state.provenance(of: link(nil, .curatedFixture)) == .demo)
    }

    // MARK: Making a batch's prints

    private actor Gauge {
        private(set) var calls = 0
        private(set) var running = 0
        private(set) var most = 0
        func enter() { calls += 1; running += 1; most = max(most, running) }
        func leave() { running -= 1 }
    }

    @Test func aBatchsPrintsAreMadeConcurrentlyButBoundedOnceEachWithProgress() async throws {
        let dir = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var urls: [String: URL] = [:]
        for index in 0..<9 {
            let url = dir.appendingPathComponent("\(index).jpg")
            try TestSupport.imageData(seed: index).write(to: url)
            urls["p\(index)"] = url
        }
        let lookup = urls
        let gauge = Gauge()
        let reports = Mutex<[Int]>([])
        let cache = FeaturePrintCache(fileURL: dir.appendingPathComponent("prints.bin"), analyzer: "test", revision: 1)
        let ids = (0..<9).map { "p\($0)" }
        let embed: @Sendable (Data) async throws -> FeaturePrint = { data in
            await gauge.enter()
            try await Task.sleep(for: .milliseconds(20))
            await gauge.leave()
            return FeaturePrint(analyzer: "test", revision: 1, vector: [Float(data.count), 1])
        }
        await cache.refresh(ids, input: { lookup[$0] }, embed: embed, concurrency: 3,
                            progress: { done, total in
                                #expect(total == 9)
                                reports.withLock { $0.append(done) }
                            })
        #expect(await gauge.calls == 9)
        #expect(await gauge.most <= 3, "bounded")
        #expect(await gauge.most > 1, "concurrent")
        #expect(reports.withLock { $0 } == Array(1...9))
        for id in ids { #expect(await cache.print(for: id) != nil) }

        // A second pass reuses every print and still reports progress.
        reports.withLock { $0 = [] }
        await cache.refresh(ids, input: { lookup[$0] }, embed: embed, concurrency: 3,
                            progress: { done, _ in reports.withLock { $0.append(done) } })
        #expect(await gauge.calls == 9)
        #expect(reports.withLock { $0 } == Array(1...9))
    }

    /// The review of photo 1 asks for its print while the batch is still making it: one print, not two.
    @Test func aPrintBeingMadeIsWaitedForNotMadeAgain() async throws {
        let dir = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var urls: [String: URL] = [:]
        for index in 0..<4 {
            let url = dir.appendingPathComponent("\(index).jpg")
            try TestSupport.imageData(seed: index).write(to: url)
            urls["p\(index)"] = url
        }
        let lookup = urls
        let gauge = Gauge()
        let cache = FeaturePrintCache(fileURL: dir.appendingPathComponent("prints.bin"), analyzer: "test", revision: 1)
        let embed: @Sendable (Data) async throws -> FeaturePrint = { data in
            await gauge.enter()
            try await Task.sleep(for: .milliseconds(80))
            await gauge.leave()
            return FeaturePrint(analyzer: "test", revision: 1, vector: [Float(data.count), 1])
        }
        let ids = (0..<4).map { "p\($0)" }
        let batch = Task { await cache.refresh(ids, input: { lookup[$0] }, embed: embed, concurrency: 2) }
        try await Task.sleep(for: .milliseconds(20))
        let reported = Mutex<[Int]>([])
        await cache.refresh(["p0"], input: { lookup[$0] }, embed: embed, progress: { done, _ in reported.withLock { $0.append(done) } })
        #expect(await cache.print(for: "p0") != nil, "the review sees the batch's print as soon as it is made")
        #expect(reported.withLock { $0 } == [1])
        await batch.value
        #expect(await gauge.calls == 4)
    }

    @Test func aCancelledBatchStopsMakingPrintsAndKeepsTheOnesMade() async throws {
        let dir = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var urls: [String: URL] = [:]
        for index in 0..<20 {
            let url = dir.appendingPathComponent("\(index).jpg")
            try TestSupport.imageData(seed: index).write(to: url)
            urls["p\(index)"] = url
        }
        let lookup = urls
        let gauge = Gauge()
        let fileURL = dir.appendingPathComponent("prints.bin")
        let cache = FeaturePrintCache(fileURL: fileURL, analyzer: "test", revision: 1)
        let ids = (0..<20).map { "p\($0)" }
        let task = Task {
            await cache.refresh(ids, input: { lookup[$0] }, embed: { data in
                await gauge.enter()
                defer { Task { await gauge.leave() } }
                try await Task.sleep(for: .milliseconds(30))
                return FeaturePrint(analyzer: "test", revision: 1, vector: [Float(data.count), 1])
            }, concurrency: 2)
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await task.value
        let calls = await gauge.calls
        #expect(calls < 20, "stopped early")
        let kept = await cache.count
        #expect(kept > 0 && kept < 20)
        #expect(FileManager.default.fileExists(atPath: fileURL.path), "what was made is saved")
    }
}
