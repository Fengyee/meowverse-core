import Foundation
import MeowverseCore
import RealityKit

/// Samples the cat's skeleton: gaits by distance travelled, and, for a cat-rig v2 pack, every resting
/// action by time. The room owns the world position, the rig owns the feet. A change of clip blends from
/// what was on screen over `blendTime`, so sitting down after a walk or getting up to leave never pops.
@MainActor
final class GroundGaitPlayer {
    private typealias Rig = CatGaitRig
    private typealias Clip = CatGaitRig.Clip

    let entity: ModelEntity
    private let clips: [GroundGait: Clip]
    /// Every clip in the pack by name.
    private let named: [String: Clip]
    /// Sitting, lying, sleeping and the furniture actions play here instead of on baked poses.
    let playsActions: Bool
    private let rest: [Transform]
    private let awakeMaterials: [PhysicallyBasedMaterial]
    private let sleepMaterials: [PhysicallyBasedMaterial]?
    private var shown: [Transform] = []
    private var shownKey: String?
    private var blend: (from: [Transform], elapsed: TimeInterval)?
    static let blendTime: TimeInterval = 0.25

    private init(entity: ModelEntity, clips: [GroundGait: Clip], named: [String: Clip], playsActions: Bool,
                 rest: [Transform], awakeMaterials: [PhysicallyBasedMaterial], sleepMaterials: [PhysicallyBasedMaterial]?) {
        self.entity = entity
        self.clips = clips
        self.named = named
        self.playsActions = playsActions
        self.rest = rest
        self.awakeMaterials = awakeMaterials
        self.sleepMaterials = sleepMaterials
    }

    /// The pack's skinned mesh, gaits and (v2) actions. The rig is validated against docs/CAT_PACK.md
    /// (34 joints, or a cat-rig v2 skeleton; all four gaits) before any RealityKit resource is made.
    static func load(from art: CatArt) async throws -> GroundGaitPlayer {
        let rig = try await art.rig()
        try Task.checkCancellation()
        let joints = try rig.joints.enumerated().map { index, joint in
            guard joint.inverseBind.count == 16, joint.parent.map({ $0 >= 0 && $0 < index }) ?? true else {
                throw ArtLibrary.ArtError.missing("Bella gait bind pose")
            }
            let raw = joint.inverseBind
            func column(_ i: Int) -> SIMD4<Float> { [raw[i], raw[i+1], raw[i+2], raw[i+3]] }
            return MeshResource.Skeleton.Joint(name: joint.name, parentIndex: joint.parent,
                inverseBindPoseMatrix: simd_float4x4(columns: (column(0), column(4), column(8), column(12))),
                restPoseTransform: Transform(scale: .one, rotation: simd_quatf(vector: joint.rotation), translation: joint.translation))
        }
        var contents = MeshResource.Contents()
        contents.skeletons = [.init(id: "Bella", joints: joints)]
        let parts = try rig.parts.enumerated().map { try makePart($0.element, index: $0.offset, jointCount: joints.count) }
        contents.models = [.init(id: "Bella", parts: parts)]
        contents.instances = [.init(id: "Bella", model: "Bella")]
        var materials: [PhysicallyBasedMaterial] = []
        var sleeping: [PhysicallyBasedMaterial] = []
        var hasSleepOverride = false
        for part in rig.parts {
            let awake = try await art.bellaMaterial(part.material, sleeping: false)
            materials.append(awake)
            let spec = art.variant.material(part.material)
            if rig.playsActions, spec?.sleepBaseColor != nil || spec?.sleepRoughness != nil {
                sleeping.append(try await art.bellaMaterial(part.material, sleeping: true))
                hasSleepOverride = true
            } else {
                sleeping.append(awake)
            }
        }
        let resource = try await MeshResource(from: contents)
        try Task.checkCancellation()
        let entity = ModelEntity(mesh: resource, materials: materials)
        entity.name = entityName
        entity.scale = SIMD3(repeating: rig.scale)
        guard entity.jointNames == joints.map(\.name) else { throw ArtLibrary.ArtError.missing("Bella gait skeleton order") }
        var clips: [GroundGait: Clip] = [:]
        for gait in GroundGait.allCases {
            guard let clip = rig.clips[gait.rawValue], clip.duration > 0, clip.stride > 0,
                  !clip.tracks.isEmpty, clip.tracks.allSatisfy({ track in
                      let width = track.path == .rotation ? 4 : 3
                      return joints.indices.contains(track.joint) && track.values.count >= width && track.values.count.isMultiple(of: width)
                  }) else { throw ArtLibrary.ArtError.missing(gait.rawValue) }
            clips[gait] = clip
        }
        let named = rig.clips.filter { _, clip in
            clip.duration > 0 && !clip.tracks.isEmpty && clip.tracks.allSatisfy { track in
                let width = track.path == .rotation ? 4 : 3
                return joints.indices.contains(track.joint) && track.values.count >= width && track.values.count.isMultiple(of: width)
            }
        }
        let actions = rig.playsActions && CatGaitRig.actionClips.allSatisfy { named[$0] != nil }
        return GroundGaitPlayer(entity: entity, clips: clips, named: named, playsActions: actions,
                                rest: joints.map(\.restPoseTransform), awakeMaterials: materials,
                                sleepMaterials: hasSleepOverride ? sleeping : nil)
    }

    private static func makePart(_ p: Rig.Part, index: Int, jointCount: Int) throws -> MeshResource.Part {
        let count = p.positions.count / 3
        guard count > 0, p.positions.count == count * 3, p.normals.count == p.positions.count,
              p.uvs.count == count*2, p.weights.count == count*4, p.jointIndices.count == p.weights.count,
              p.indices.allSatisfy({ $0 < count }), p.jointIndices.allSatisfy({ (0..<jointCount).contains($0) })
        else { throw ArtLibrary.ArtError.missing("Bella gait mesh \(p.material)") }
        func xyz(_ data: [Float]) -> [SIMD3<Float>] {
            (0..<count).map { i in [data[i*3], data[i*3+1], data[i*3+2]] }
        }
        var part = MeshResource.Part(id: "part-\(index)", materialIndex: index)
        part.positions = .init(xyz(p.positions))
        part.normals = .init(xyz(p.normals))
        part.textureCoordinates = .init((0..<count).map { i in SIMD2<Float>(p.uvs[i*2], 1 - p.uvs[i*2+1]) })
        part.triangleIndices = .init(p.indices)
        part.skeletonID = "Bella"
        let influences = zip(p.jointIndices, p.weights).map { MeshJointInfluence(jointIndex: $0, weight: $1) }
        part.jointInfluences = .init(influences: .init(influences), influencesPerVertex: 4)
        return part
    }

    /// The skinned entity's name, so a copy of the cat (the postcard) can find it.
    static let entityName = "cat-skin"

    /// The mesh and materials as shown now (sleeping or awake), for dressing a copy of another
    /// tier's entity on the same skeleton: every tier shares the joints, so the pose carries over.
    func dress(_ copy: ModelEntity, like live: GroundGaitPlayer) {
        guard var model = entity.model, copy.jointNames == entity.jointNames else { return }
        model.materials = live.shownKey == "sleep" ? sleepMaterials ?? awakeMaterials : awakeMaterials
        let pose = copy.jointTransforms
        copy.model = model
        copy.jointTransforms = pose
    }

    // All enum cases are required at load time.
    func duration(_ gait: GroundGait) -> Double { clips[gait]!.duration }
    func stride(_ gait: GroundGait) -> Double { clips[gait]!.stride }

    func show(_ gait: GroundGait, distance: Double, delta: TimeInterval = 1.0 / 60) {
        let clip = clips[gait]!
        let phase = Clip.phase(distance, period: clip.stride, looping: true)
        present(sample(clip, phase: phase), key: gait.rawValue, delta: delta)
    }

    func has(_ name: String) -> Bool { named[name] != nil }

    /// The author marks the instant of contact (the still frame) on the play clip.
    var toyStrike: (period: Double, contact: Double)? {
        guard playsActions, let clip = named["bat_high"] else { return nil }
        return (clip.duration, clip.still * clip.duration)
    }

    /// A clip by time since it started: looping clips wrap, the others hold their last frame.
    func show(clip name: String, time: TimeInterval, delta: TimeInterval) {
        guard let clip = named[name] else { return }
        let phase = Clip.phase(time, period: clip.duration, looping: clip.loop)
        present(sample(clip, phase: phase), key: name, delta: delta)
    }

    /// The clip's still frame, for Reduce Motion.
    func showStill(clip name: String) {
        guard let clip = named[name] else { return }
        blend = nil
        present(sample(clip, phase: clip.still), key: name, delta: Self.blendTime)
    }

    private func sample(_ clip: Clip, phase: Double) -> [Transform] {
        var pose = rest
        for track in clip.tracks { track.apply(phase: phase, to: &pose[track.joint]) }
        return pose
    }

    private func present(_ pose: [Transform], key: String, delta: TimeInterval) {
        if key != shownKey {
            if let sleepMaterials, (key == "sleep") != (shownKey == "sleep") {
                entity.model?.materials = key == "sleep" ? sleepMaterials : awakeMaterials
            }
            if shown.count == pose.count { blend = (from: shown, elapsed: 0) }
            shownKey = key
        }
        var out = pose
        if let current = blend {
            let elapsed = current.elapsed + max(delta, 0)
            let u = Float(min(elapsed / Self.blendTime, 1))
            let w = u * u * (3 - 2 * u)
            for i in out.indices {
                out[i].rotation = simd_slerp(current.from[i].rotation, pose[i].rotation, w)
                out[i].translation = simd_mix(current.from[i].translation, pose[i].translation, SIMD3<Float>(repeating: w))
            }
            blend = u < 1 ? (from: current.from, elapsed: elapsed) : nil
        }
        shown = out
        entity.jointTransforms = out
    }
}

private extension CatGaitRig.Clip.Track {
    func apply(phase: Double, to pose: inout Transform) {
        guard phase.isFinite, (0...1).contains(phase) else { return }
        let last = values.count / width - 1
        let frame = min(phase * Double(last), Double(last))
        let i = Int(frame) * width, j = min(i + width, last * width)
        let t = Float(frame - Double(Int(frame)))
        if path == .rotation {
            func q(_ i: Int) -> simd_quatf {
                simd_quatf(ix: values[i], iy: values[i+1], iz: values[i+2], r: values[i+3])
            }
            pose.rotation = simd_slerp(q(i), q(j), t)
        } else {
            func p(_ i: Int) -> SIMD3<Float> { [values[i], values[i+1], values[i+2]] }
            pose.translation = simd_mix(p(i), p(j), SIMD3(repeating: t))
        }
    }
}
