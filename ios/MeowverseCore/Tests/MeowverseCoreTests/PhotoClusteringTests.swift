import CoreGraphics
import Foundation
import Testing
@testable import MeowverseCore

@Suite struct PhotoClusteringTests {
    private func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1e-9 && abs(a.minY - b.minY) < 1e-9 && abs(a.width - b.width) < 1e-9 && abs(a.height - b.height) < 1e-9
    }

    /// Three tight groups far apart, in the order a a a b b b c c c.
    private let blobs: [[Float]] = [
        [0, 0], [0.2, 0.1], [0.1, 0.3],
        [10, 0], [10.2, 0.1], [9.9, 0.2],
        [0, 10], [0.1, 10.2], [0.3, 9.9],
    ]

    @Test func distanceMatrixIsSquaredEuclideanAndSymmetric() {
        let m = DistanceMatrix(vectors: [[0, 0], [3, 4], [0, 1]])
        #expect(m[0, 1] == 25)
        #expect(m[1, 0] == 25)
        #expect(m[0, 2] == 1)
        #expect(m[2, 2] == 0)
    }

    @Test func bothLinkagesRecoverWellSeparatedGroups() {
        let m = DistanceMatrix(vectors: blobs)
        for linkage in PhotoClustering.Linkage.allCases {
            #expect(PhotoClustering.agglomerative(m, linkage: linkage, threshold: 1) == [0, 0, 0, 1, 1, 1, 2, 2, 2])
            #expect(PhotoClustering.agglomerative(m, linkage: linkage, threshold: 0) == Array(0..<9))
            #expect(PhotoClustering.agglomerative(m, linkage: linkage, threshold: 1000) == Array(repeating: 0, count: 9))
        }
    }

    @Test func averageAndCompleteLinkageDifferOnAChain() {
        // 0 — 1 — 2 on a line: neighbours at squared distance 1, the ends at 4.
        let m = DistanceMatrix(vectors: [[0], [1], [2]])
        let average = PhotoClustering.dendrogram(m, linkage: .average)
        let complete = PhotoClustering.dendrogram(m, linkage: .complete)
        #expect(average.map(\.height) == [1, 2.5])   // (4 + 1) / 2
        #expect(complete.map(\.height) == [1, 4])    // max(4, 1)
        #expect(average.first == PhotoClustering.Merge(a: 0, b: 1, height: 1))  // tie goes to the smallest indices
        #expect(PhotoClustering.agglomerative(m, linkage: .average, threshold: 3) == [0, 0, 0])
        #expect(PhotoClustering.agglomerative(m, linkage: .complete, threshold: 3) == [0, 0, 1])
        #expect(PhotoClustering.agglomerative(m, linkage: .average, threshold: 2) == [0, 0, 1])
    }

    @Test func leaderClusteringFollowsTheOrderGiven() {
        // Squared distances 0.64 between neighbours, 2.56 between the ends.
        let m = DistanceMatrix(vectors: [[0], [0.8], [1.6]])
        #expect(PhotoClustering.leader(m, order: [0, 1, 2], threshold: 1) == [0, 0, 1])
        #expect(PhotoClustering.leader(m, order: [2, 1, 0], threshold: 1) == [0, 1, 1])
        #expect(PhotoClustering.leader(DistanceMatrix(vectors: blobs), order: Array(0..<9), threshold: 1) == [0, 0, 0, 1, 1, 1, 2, 2, 2])
    }

    @Test func sessionsSplitOnLongGapsAndUndatedPhotosStandAlone() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let times: [Date?] = [t, t + 60, t + 4000, nil, t + 4030]
        #expect(PhotoClustering.sessions(times: times, gap: 600) == [0, 0, 1, 2, 1])
        #expect(PhotoClustering.sessions(times: times, gap: 10) == [0, 1, 2, 3, 4])
    }

    @Test func sessionAdjustedDistancesMergeSessionsAndKeepFarPlacesApart() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        // Photos 0 and 1 look nothing alike but were taken a minute apart; 2 and 3 likewise, but
        // their GPS places are about 111 km apart.
        let m = DistanceMatrix(vectors: [[0], [3], [10], [13]])
        let home = PhotoPlace(latitude: 40, longitude: -75), away = PhotoPlace(latitude: 41, longitude: -75)
        let adjusted = PhotoClustering.sessionAdjusted(m, times: [t, t + 60, t + 9000, t + 9060],
                                                       places: [nil, nil, home, away], gap: 600)
        #expect(adjusted[0, 1] == 0)
        #expect(adjusted[2, 3] == 4)
        #expect(adjusted[0, 2] == m[0, 2])
        #expect(PhotoClustering.agglomerative(adjusted, linkage: .complete, threshold: 1) == [0, 0, 1, 2])
        #expect(abs(home.metres(to: away) - 111_195) < 100)
    }

    @Test func placesJoinChainsWithinTheRadiusAndLeaveNoGPSOut() {
        // About 0.8 km steps north: 0–1 and 1–2 within 1 km, 0–2 not; 3 is about 111 km away.
        let step = 0.8 / 111.195
        let places: [PhotoPlace?] = [
            PhotoPlace(latitude: 40, longitude: -75), nil,
            PhotoPlace(latitude: 40 + step, longitude: -75), PhotoPlace(latitude: 41, longitude: -75),
            PhotoPlace(latitude: 40 + 2 * step, longitude: -75),
        ]
        #expect(PhotoClustering.places(places, within: 1000) == [0, nil, 0, 1, 0])
        #expect(PhotoClustering.places(places, within: 500) == [0, nil, 1, 2, 3])
    }

    @Test func neighbourhoodGrowsTheCatBoxAboutItsCentreInsideThePicture() {
        let box = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.1)
        let grown = PhotoClustering.neighbourhood(of: [box], factor: 2.5)!
        #expect(abs(grown.minX - 0.25) < 1e-9 && abs(grown.width - 0.5) < 1e-9)
        #expect(abs(grown.minY - 0.325) < 1e-9 && abs(grown.height - 0.25) < 1e-9)
        // Near the edge the grown box is cut at the picture's border.
        let corner = PhotoClustering.neighbourhood(of: [CGRect(x: 0, y: 0, width: 0.2, height: 0.2)], factor: 2)!
        #expect(near(corner, CGRect(x: 0, y: 0, width: 0.3, height: 0.3)))
        // Two cats: the box around both.
        let both = PhotoClustering.neighbourhood(of: [CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1),
                                                      CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1)], factor: 1)!
        #expect(near(both, CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)))
        #expect(PhotoClustering.neighbourhood(of: [], factor: 2) == nil)
    }

    @Test func pairPercentilesUseNearestRank() {
        // Five points 0…4 on a line: pair distances 1 ×4, 4 ×3, 9 ×2, 16 ×1.
        let m = DistanceMatrix(vectors: [[0], [1], [2], [3], [4]])
        #expect(PhotoClustering.pairPercentiles(m, percents: [1, 10, 50, 75, 100]) == [1, 1, 4, 9, 16])
        #expect(PhotoClustering.pairPercentiles(m, percents: [41]) == [4])   // 41% of 10 pairs → 5th smallest
        #expect(PhotoClustering.pairPercentiles(DistanceMatrix(vectors: [[0]]), percents: [5]).isEmpty)
    }

    @Test func closerShareIsTheProbabilityThatASameLabelPairIsCloser() {
        #expect(PhotoClustering.closerShare(same: [1, 2], other: [3, 4]) == 1)
        #expect(PhotoClustering.closerShare(same: [5], other: [1, 6]) == 0.5)
        #expect(PhotoClustering.closerShare(same: [3], other: [3]) == 0.5)
        #expect(PhotoClustering.closerShare(same: [], other: [1]) == nil)
    }

    @Test func adjustedRandIndexMatchesKnownValues() {
        #expect(abs(ClusterScore.adjustedRandIndex([0, 0, 1, 1], [0, 0, 1, 2]) - 4.0 / 7) < 1e-12)
        #expect(ClusterScore.adjustedRandIndex([0, 0, 1, 1], ["x", "x", "y", "y"]) == 1)   // names do not matter
        #expect(ClusterScore.adjustedRandIndex([0, 0, 0, 0], [0, 1, 2, 3]) == 0)
        #expect(ClusterScore.adjustedRandIndex([0], ["a"]) == 1)
    }

    @Test func scoreCountsPurityCleanGroupsAndUserActions() {
        let mixed = ClusterScore(groups: [0, 0, 0, 1, 1, 2], truth: ["a", "a", "b", "c", "c", "a"])
        #expect(mixed.clusters == 3)
        #expect(mixed.singletons == 1)
        #expect(mixed.purity == 5.0 / 6)
        #expect(mixed.cleanLargeShare == 0)   // the only group of 3 is 2/3 one piece
        #expect(mixed.actions == 4)           // three names and one fix
        let clean = ClusterScore(groups: [0, 0, 0, 1], truth: ["a", "a", "a", "b"])
        #expect(clean.cleanLargeShare == 0.75)
        #expect(clean.actions == 2)
        let perPhoto = ClusterScore(groups: [0, 1, 2], truth: ["a", "a", "b"])
        #expect(perPhoto.actions == 3)
    }

    private func print(_ values: [Float], analyzer: String = "a") -> FeaturePrint {
        FeaturePrint(analyzer: analyzer, revision: 2, vector: values)
    }

    @Test func ruleNeedsTheClosestPhotosToAgreeCloseByAndEnoughOfThem() {
        let refs = [
            FurniturePhotoPrint(instanceId: "sofa", photoId: "p1", print: print([0.1, 0])),
            FurniturePhotoPrint(instanceId: "sofa", photoId: "p2", print: print([0.2, 0])),
            FurniturePhotoPrint(instanceId: "sofa", photoId: "p3", print: print([0.3, 0])),
            FurniturePhotoPrint(instanceId: "bed", photoId: "p4", print: print([0.5, 0])),
            FurniturePhotoPrint(instanceId: "bed", photoId: "x", print: print([0, 0], analyzer: "other")),
        ]
        let query = print([0, 0])
        let match = AutoFileRule(neighbours: 3, maximumDistance: 0.05, minimumPhotos: 1).piece(for: query, among: refs)
        #expect(match?.instanceId == "sofa")
        #expect(match?.photoId == "p1")
        #expect(abs((match?.distance ?? 0) - 0.01) < 1e-6)
        #expect(AutoFileRule(neighbours: 4, maximumDistance: 0.05, minimumPhotos: 1).piece(for: query, among: refs) == nil)
        #expect(AutoFileRule(neighbours: 3, maximumDistance: 0.005, minimumPhotos: 1).piece(for: query, among: refs) == nil)
        #expect(AutoFileRule(neighbours: 3, maximumDistance: 0.05, minimumPhotos: 4).piece(for: query, among: refs) == nil)
        #expect(AutoFileRule(neighbours: 3, maximumDistance: 0.05, minimumPhotos: 3).piece(for: query, among: refs) != nil)
        // Fewer comparable photos than voters: no offer.
        #expect(AutoFileRule(neighbours: 3, maximumDistance: 1, minimumPhotos: 1).piece(for: query, among: Array(refs.prefix(2))) == nil)
        // A voter that is in two pieces breaks the agreement.
        let shared = refs + [FurniturePhotoPrint(instanceId: "bed", photoId: "p2", print: print([0.2, 0]))]
        #expect(AutoFileRule(neighbours: 3, maximumDistance: 0.05, minimumPhotos: 1).piece(for: query, among: shared) == nil)
    }

    @Test func marginNeedsEveryOtherLabelFartherThanTheLastVoter() {
        // Squared distances from the query: sofa 1 and 4, bed exactly 5 (no rounding anywhere).
        let refs = [
            FurniturePhotoPrint(instanceId: "sofa", photoId: "p1", print: print([1, 0])),
            FurniturePhotoPrint(instanceId: "sofa", photoId: "p2", print: print([2, 0])),
            FurniturePhotoPrint(instanceId: "bed", photoId: "p3", print: print([2, 1])),
        ]
        let query = print([0, 0])
        func offer(_ margin: Float, _ among: [FurniturePhotoPrint] = refs, notOffered: Set<String> = []) -> String? {
            AutoFileRule(neighbours: 2, maximumDistance: 2, margin: margin).piece(for: query, among: among, notOffered: notOffered)?.instanceId
        }
        #expect(offer(1) == "sofa")
        #expect(offer(1.25) == "sofa")   // 5 is exactly 1.25 × 4: equal passes
        #expect(offer(1.5) == nil)        // 6 > 5
        // No other label filed yet: the margin passes whatever it is.
        #expect(offer(100, Array(refs.prefix(2))) == "sofa")
        // A photo on the wall is another label for the margin…
        let wall = Array(refs.prefix(2)) + [FurniturePhotoPrint(instanceId: "wall", photoId: "w1", print: print([2, 1]))]
        #expect(offer(1.5, wall, notOffered: ["wall"]) == nil)
        // …breaks the agreement when it is among the voters, and is never offered itself.
        let walls = [FurniturePhotoPrint(instanceId: "wall", photoId: "w1", print: print([1, 0])),
                     FurniturePhotoPrint(instanceId: "wall", photoId: "w2", print: print([2, 0]))]
        #expect(offer(1, walls, notOffered: ["wall"]) == nil)
        #expect(offer(1, walls + Array(refs.prefix(1)), notOffered: ["wall"]) == nil)
    }

    @Test func marginTiesFollowTheOrderOfPhotoIds() {
        // Two photos at the same distance: the smaller id votes, the other is the nearest other label.
        let refs = [FurniturePhotoPrint(instanceId: "bed", photoId: "b", print: print([0, 1])),
                    FurniturePhotoPrint(instanceId: "sofa", photoId: "a", print: print([1, 0]))]
        let query = print([0, 0])
        #expect(AutoFileRule(neighbours: 1, maximumDistance: 2, margin: 1).piece(for: query, among: refs)?.instanceId == "sofa")
        #expect(AutoFileRule(neighbours: 1, maximumDistance: 2, margin: 1.1).piece(for: query, among: refs) == nil)
    }

    @Test func streamWithTheWallAndAcceptedOffers() {
        // a1 at 0 (A), n at 0.3 (no furniture), a2 at 0.1 (A), y at 0.35 (no furniture).
        let m = DistanceMatrix(vectors: [[0], [0.3], [0.1], [0.35]])
        let truth: [String?] = ["A", nil, "A", nil]
        let order = [0, 1, 2, 3]
        let strict = AutoFileRule(neighbours: 1, maximumDistance: 0.5, margin: 5)
        // n goes to the wall; for a2 the wall photo (0.04) is nearer than 5 × 0.01, so no offer.
        let withWall = AutoFiling.stream(order: order, truth: truth, distances: m, rule: strict, wall: "wall")
        #expect(withWall.map(\.item) == [1])
        #expect(withWall.first?.filed == "A")
        #expect(withWall.first?.filedBefore == 0)
        #expect(withWall.first?.pieceWasNew == false)   // no furniture is not a new piece
        // Without the wall as a reference there is no other label, so a2 is offered too (and y).
        let noWall = AutoFiling.stream(order: order, truth: truth, distances: m, rule: strict)
        #expect(noWall.map(\.item) == [1, 2, 3])
        #expect(noWall[1].filedBefore == 1)
        // y's nearest is n: on the wall it is no offer; offered and accepted as A it votes for A.
        let plain = AutoFileRule(neighbours: 1, maximumDistance: 0.5)
        #expect(AutoFiling.stream(order: order, truth: truth, distances: m, rule: plain, wall: "wall").map(\.item) == [1, 2])
        #expect(AutoFiling.stream(order: order, truth: truth, distances: m, rule: plain, wall: "wall", acceptOffers: true).map(\.item) == [1, 2, 3])
    }

    // a1 a2 a3 near the origin (piece A), b1 b2 far away (piece B), n near A with no furniture.
    private let line: [[Float]] = [[0], [0.1], [0.2], [5], [5.1], [0.3]]
    private let truth: [String?] = ["A", "A", "A", "B", "B", nil]

    @Test func streamJudgesEachPhotoAgainstEarlierOnesFiledCorrectly() {
        let m = DistanceMatrix(vectors: line + [[0.05]])
        let rule = AutoFileRule(neighbours: 1, maximumDistance: 0.5, minimumPhotos: 1)
        // Order a1 a2 n b1 b2 c (c: a piece not in the room yet, close to A).
        let offers = AutoFiling.stream(order: [0, 1, 5, 3, 4, 6], truth: truth + ["C"], distances: m, rule: rule)
        #expect(offers.map(\.item) == [1, 5, 4, 6])
        #expect(offers.map(\.filed) == ["A", "A", "B", "A"])
        #expect(offers.map(\.isRight) == [true, false, true, false])
        #expect(offers.map(\.pieceWasNew) == [false, false, false, true])
        // Two voters needed: the first A photo alone is not enough for a2.
        let two = AutoFiling.stream(order: [0, 1, 2, 3, 4], truth: truth, distances: m, rule: AutoFileRule(neighbours: 2, maximumDistance: 0.5, minimumPhotos: 1))
        #expect(two.map(\.item) == [2])
    }

    @Test func batchOffersAfterEachManualDecisionAndCountsWhatIsLeft() {
        let m = DistanceMatrix(vectors: line)
        let rule = AutoFileRule(neighbours: 1, maximumDistance: 0.5, minimumPhotos: 1)
        let order = [0, 3, 1, 2, 4, 5]   // a1 b1 a2 a3 b2 n
        let accepted = AutoFiling.batch(order: order, truth: truth, distances: m, rule: rule, page: .acceptedAsShown)
        // a1 by hand → a2, a3, n offered as A; b1 by hand → b2 offered as B.
        #expect(accepted.manual == 2)
        #expect(accepted.offers.map(\.item) == [1, 2, 5, 4])
        #expect(accepted.offers.filter(\.isRight).count == 3)
        #expect(accepted.rejected == 0)
        let rejecting = AutoFiling.batch(order: order, truth: truth, distances: m, rule: rule, page: .wrongOnesRejected)
        // n is unticked, stays open and is decided by hand at the end.
        #expect(rejecting.manual == 3)
        #expect(rejecting.offers.map(\.item) == [1, 2, 5, 4])
        #expect(rejecting.rejected == 1)
    }

    @Test func aWrongOfferAcceptedAsShownVotesOnTheNextPage() {
        // a1 at 0 (A), b1 far (B), n at 0.3 (no furniture), x at 0.9 (piece C, new).
        let m = DistanceMatrix(vectors: [[0], [5], [0.3], [0.9]])
        let truth: [String?] = ["A", "B", nil, "C"]
        let rule = AutoFileRule(neighbours: 1, maximumDistance: 0.5, minimumPhotos: 1)
        let accepted = AutoFiling.batch(order: [0, 1, 2, 3], truth: truth, distances: m, rule: rule, page: .acceptedAsShown)
        // Page 1 (after a1): n → A. Page 2 (after b1): x is closest to n, now in A → A.
        #expect(accepted.offers.map(\.item) == [2, 3])
        #expect(accepted.offers.allSatisfy { !$0.isRight })
        #expect(accepted.offers.last?.pieceWasNew == true)
        #expect(accepted.manual == 2)
        let rejecting = AutoFiling.batch(order: [0, 1, 2, 3], truth: truth, distances: m, rule: rule, page: .wrongOnesRejected)
        #expect(rejecting.offers.map(\.item) == [2])
        #expect(rejecting.manual == 4)
    }
}
