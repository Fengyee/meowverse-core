import CoreGraphics
import Metal
import MeowverseCore
import OSLog
import RealityKit
import UIKit

/// The room's studio look (owner, 2026-11-21): a soft environment in place of most of the sun, and
/// a tone curve. ARView hands a post effect 8-bit sRGB whether or not HDR is on, so the scene is
/// lit `headroom` darker and the curve brings it back; highlights then roll off instead of clipping.
///
/// Not in AR: the effect would grade the camera's picture too.
nonisolated struct RoomLook: Sendable {
    /// Image-based light, in stops.
    var environment: Float = 1.1
    /// What is left of the sun and the fill.
    var direct: Float = 0.45
    var headroom: Float = 0.6
    /// The curve's gain: lifts the middle tones.
    var gain: Float = 3.2
    /// Keeps the cat's dark fur dark under the lift.
    var contrast: Float = 1.15
    /// Pulls colours a little towards their own lightness.
    var crosstalk: Float = 0.02

    static let current: RoomLook? = {
        var look = RoomLook()
        #if DEBUG || DRILLS
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-MeowverseClassicLight") { return nil }
        if let at = args.firstIndex(of: "-MeowverseRoomLook"), args.indices.contains(at + 1) {
            let v = args[at + 1].split(separator: ",").compactMap { Float($0) }
            if v.count == 6 {
                look = RoomLook(environment: v[0], direct: v[1], headroom: v[2], gain: v[3], contrast: v[4], crosstalk: v[5])
            }
        }
        #endif
        return look
    }()
}

extension RoomLook {
    @MainActor
    func light(_ view: ARView, sun: DirectionalLight, fill: DirectionalLight, phase: RoomLightPhase) {
        sun.light.intensity *= direct * headroom
        fill.light.intensity *= direct * headroom
        // The environment has no colour of its own per phase, so it dims with the evening.
        let dimmer: Float = switch phase {
        case .daylight: 0
        case .dawn: -0.15
        case .dusk: -0.4
        case .night: -1
        }
        view.environment.lighting.intensityExponent = environment + dimmer + log2(headroom)
    }

    @MainActor
    func install(on view: ARView, hdrEnvironment: Bool) {
        setEnvironment(on: view, hdr: hdrEnvironment)
        let effect = RoomToneEffect(look: self)
        view.renderCallbacks.prepareWithDevice = { @Sendable device in effect.prepare(device) }
        view.renderCallbacks.postProcess = { @Sendable context in effect.encode(context) }
    }

    @discardableResult
    @MainActor
    func setEnvironment(on view: ARView, hdr: Bool) -> Bool {
        if hdr, let studio = RoomStudioLighting.environment() {
            view.environment.lighting.resource = studio
            return true
        }
        view.environment.lighting.resource = Self.studio
        return false
    }

    /// Drawn here, so no image ships: pale above, warm below, three soft boxes.
    @MainActor private static let studio: EnvironmentResource? = {
        guard let image = studioImage() else { return nil }
        do {
            return try EnvironmentResource(equirectangular: image, withName: "room-studio")
        } catch {
            Logger(subsystem: "Meowverse", category: "look").error("No studio environment: \(error.localizedDescription)")
            return nil
        }
    }()

    private static func studioImage() -> CGImage? {
        let width = 256, height = 128
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        func colour(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
        let sky = [colour(0.42, 0.36, 0.30), colour(0.65, 0.62, 0.58), colour(0.88, 0.88, 0.86), colour(0.95, 0.95, 0.94)]
        guard let gradient = CGGradient(colorsSpace: space, colors: sky as CFArray, locations: [0, 0.45, 0.62, 1]) else { return nil }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])
        let boxes: [(centre: CGPoint, radius: CGFloat, colour: CGColor)] = [
            (CGPoint(x: 155, y: 98), 39, colour(1, 0.96, 0.88)),
            (CGPoint(x: 55, y: 90), 30, colour(1, 0.98, 0.94)),
            (CGPoint(x: 225, y: 85), 23, colour(1, 0.97, 0.92)),
        ]
        for box in boxes {
            guard let edge = box.colour.copy(alpha: 0),
                  let soft = CGGradient(colorsSpace: space, colors: [box.colour, box.colour, edge] as CFArray, locations: [0, 0.55, 1])
            else { continue }
            context.drawRadialGradient(soft, startCenter: box.centre, startRadius: 0, endCenter: box.centre, endRadius: box.radius, options: [])
        }
        return context.makeImage()
    }
}

/// Runs on RealityKit's render thread. The source is a constant compiled on the device: no
/// offline Metal toolchain is needed to build the app.
nonisolated private final class RoomToneEffect: @unchecked Sendable {
    private struct Uniforms {
        var headroom: Float, gain: Float, contrast: Float, crosstalk: Float
    }

    // Both textures are sRGB, so `read` gives linear light and `write` encodes. Premultiplied alpha:
    // the room page paints the theme's backdrop behind this view.
    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct Uniforms { float headroom, gain, contrast, crosstalk; };
    static float3 curve(float3 x, constant Uniforms &u) {
        float3 t = pow(max(x / u.headroom, 0.0), u.contrast) * u.gain;
        float white = u.gain * pow(1.0 / u.headroom, u.contrast);
        return t * (1.0 + t / (white * white)) / (1.0 + t);
    }
    kernel void roomTone(texture2d<float, access::read> src [[texture(0)]],
                         texture2d<float, access::write> dst [[texture(1)]],
                         constant Uniforms &u [[buffer(0)]],
                         uint2 at [[thread_position_in_grid]]) {
        float4 c = src.read(at);
        if (c.a > 0.0) {
            float3 x = c.rgb / c.a;
            x = mix(x, float3(dot(x, float3(0.2126, 0.7152, 0.0722))), u.crosstalk);
            float peak = max(max(x.r, x.g), max(x.b, 1e-5));
            // Mostly on the brightest channel, so cream stays cream; a little per channel, so
            // the brightest highlights still go to white.
            float3 kept = x * (curve(float3(peak), u).r / peak);
            c.rgb = saturate(mix(kept, curve(x, u), 0.2)) * c.a;
        }
        dst.write(c, at);
    }
    """

    private let uniforms: Uniforms
    private var pipeline: (any MTLComputePipelineState)?

    init(look: RoomLook) {
        uniforms = Uniforms(headroom: look.headroom, gain: look.gain, contrast: look.contrast, crosstalk: look.crosstalk)
    }

    func prepare(_ device: any MTLDevice) {
        do {
            let library = try device.makeLibrary(source: Self.source, options: nil)
            guard let function = library.makeFunction(name: "roomTone") else { return }
            pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            Logger(subsystem: "Meowverse", category: "look").error("No tone curve: \(error.localizedDescription)")
        }
    }

    func encode(_ context: ARView.PostProcessContext) {
        let source = context.sourceColorTexture, target = context.targetColorTexture
        guard let pipeline, let encoder = context.commandBuffer.makeComputeCommandEncoder() else {
            // With a callback set the target starts empty: copy, or the room would vanish.
            let blit = context.commandBuffer.makeBlitCommandEncoder()
            blit?.copy(from: source, to: target)
            blit?.endEncoding()
            return
        }
        var values = uniforms
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(target, index: 1)
        encoder.setBytes(&values, length: MemoryLayout<Uniforms>.stride, index: 0)
        let across = pipeline.threadExecutionWidth
        encoder.dispatchThreads(MTLSize(width: target.width, height: target.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: across, height: pipeline.maxTotalThreadsPerThreadgroup / across, depth: 1))
        encoder.endEncoding()
    }
}
