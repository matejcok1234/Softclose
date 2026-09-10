import Foundation
import MetalKit
import simd

struct BendUniforms {
    var progress: Float = 0
    var tilt: Float = 0
    var aspect: Float = 1
    var cameraDist: Float = 3.0
    var blurMix: Float = 0
    var shadow: Float = 0
    var texelSize: SIMD2<Float> = .zero
    var sigma: Float = 1
}

/// Draws the captured desktop as a sheet bending on its hinge.
///
/// The renderer owns no state about the lid — it is handed a progress value
/// every frame and eases toward it, which is where the "settles" comes from:
/// the sensor jumps in whole degrees, the spring makes it fluid.
final class BendRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    /// Where each frame's source image comes from. The overlay hands over the
    /// live capture; the settings preview hands over a still. Everything past
    /// this point is identical, so the preview shows the real effect rather
    /// than an approximation of it.
    private let textureProvider: () -> MTLTexture?
    private let settings: Settings

    private var bendPipeline: MTLRenderPipelineState!
    private var backgroundPipeline: MTLRenderPipelineState!
    private var blurPipeline: MTLRenderPipelineState!
    private var copyPipeline: MTLRenderPipelineState!

    private var gridVertices: MTLBuffer!
    private var gridIndices: MTLBuffer!
    private var gridIndexCount = 0

    private var halfTexture: MTLTexture?
    private var blurTextureA: MTLTexture?
    private var blurTextureB: MTLTexture?
    private var scratchSize: CGSize = .zero

    /// Where the lid actually is, 0...1. Set from the controller.
    var targetProgress: Float = 0
    /// Asked for a fresh target at the top of every frame.
    ///
    /// The sensor reports far less often than the display refreshes, so waiting
    /// to be told the angle changed means the fold only moves on report
    /// boundaries. Pulling it each frame lets the extrapolated angle advance
    /// smoothly in between.
    var progressProvider: (() -> Float)?
    /// Eased value the frame is drawn from.
    private(set) var smoothedProgress: Float = 0
    private var velocity: Float = 0
    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()

    /// Fires with the eased progress after every frame, so the controller can
    /// fade the window and decide when the effect has fully cleared.
    var onFrame: ((Float) -> Void)?

    init(device: MTLDevice,
         textureProvider: @escaping () -> MTLTexture?,
         settings: Settings) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw RendererError.noQueue }
        self.queue = queue
        self.textureProvider = textureProvider
        self.settings = settings
        super.init()
        try buildPipelines()
        buildGrid(resolution: 64)
    }

    private func buildPipelines() throws {
        let library = try Self.loadLibrary(device: device)

        func pipeline(vertex: String, fragment: String) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        bendPipeline = try pipeline(vertex: "bend_vertex", fragment: "bend_fragment")
        backgroundPipeline = try pipeline(vertex: "fullscreen_vertex", fragment: "background_fragment")
        blurPipeline = try pipeline(vertex: "fullscreen_vertex", fragment: "blur_fragment")
        copyPipeline = try pipeline(vertex: "fullscreen_vertex", fragment: "copy_fragment")
    }

    /// Prefers the metallib built into the bundle; falls back to compiling the
    /// shader source at launch so a plain `swift run` still works.
    private static func loadLibrary(device: MTLDevice) throws -> MTLLibrary {
        if let library = try? device.makeDefaultLibrary(bundle: .main) {
            return library
        }
        let candidates = [
            Bundle.main.url(forResource: "Bend", withExtension: "metal"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Shaders/Bend.metal"),
        ].compactMap { $0 }
        for url in candidates {
            if let source = try? String(contentsOf: url, encoding: .utf8) {
                Log.info("compiling shaders from \(url.lastPathComponent)")
                return try device.makeLibrary(source: source, options: nil)
            }
        }
        throw RendererError.noShaders
    }

    /// A grid, not a single quad: the fold is a curve, so the geometry has to
    /// have enough rows to follow it.
    private func buildGrid(resolution: Int) {
        var vertices: [SIMD2<Float>] = []
        vertices.reserveCapacity((resolution + 1) * (resolution + 1))
        for row in 0...resolution {
            for column in 0...resolution {
                vertices.append(SIMD2(Float(column) / Float(resolution),
                                      Float(row) / Float(resolution)))
            }
        }

        var indices: [UInt32] = []
        indices.reserveCapacity(resolution * resolution * 6)
        let stride = UInt32(resolution + 1)
        for row in 0..<UInt32(resolution) {
            for column in 0..<UInt32(resolution) {
                let topLeft = row * stride + column
                let topRight = topLeft + 1
                let bottomLeft = topLeft + stride
                let bottomRight = bottomLeft + 1
                indices += [topLeft, bottomLeft, topRight, topRight, bottomLeft, bottomRight]
            }
        }

        gridVertices = device.makeBuffer(bytes: vertices,
                                         length: vertices.count * MemoryLayout<SIMD2<Float>>.stride,
                                         options: .storageModeShared)
        gridIndices = device.makeBuffer(bytes: indices,
                                        length: indices.count * MemoryLayout<UInt32>.stride,
                                        options: .storageModeShared)
        gridIndexCount = indices.count
    }

    private func ensureScratchTextures(width: Int, height: Int) {
        let halfWidth = max(width / 2, 1)
        let halfHeight = max(height / 2, 1)
        if halfTexture?.width == halfWidth, halfTexture?.height == halfHeight { return }

        // Mipmapped: the blur samples down the chain as its radius grows, so
        // the taps always average whole texels instead of skipping between them.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: halfWidth, height: halfHeight, mipmapped: true)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private

        halfTexture = device.makeTexture(descriptor: descriptor)
        blurTextureA = device.makeTexture(descriptor: descriptor)
        blurTextureB = device.makeTexture(descriptor: descriptor)
        scratchSize = CGSize(width: halfWidth, height: halfHeight)
        Log.info("scratch textures \(halfWidth)x\(halfHeight)")
    }

    // MARK: - Frame

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastFrameTime, 1.0 / 240), 1.0 / 20))
        lastFrameTime = now
        if let progressProvider { targetProgress = progressProvider() }
        advanceSpring(dt: dt)

        defer { onFrame?(smoothedProgress) }

        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = queue.makeCommandBuffer()
        else { return }

        let desktop = textureProvider()
        // Points per pixel, so the blur can be specified in points and look the
        // same on any display rather than growing with resolution.
        let pixelScale = view.bounds.height > 0
            ? Float(view.drawableSize.height / view.bounds.height)
            : 2
        var uniforms = makeUniforms(viewSize: view.drawableSize, pixelScale: pixelScale)

        if let desktop {
            ensureScratchTextures(width: desktop.width, height: desktop.height)
            uniforms.texelSize = SIMD2(Float(1.0 / scratchSize.width), Float(1.0 / scratchSize.height))
            if uniforms.blurMix > 0.001 {
                runBlurPasses(commandBuffer: commandBuffer, source: desktop, uniforms: uniforms)
            }
        }

        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
            encoder.setRenderPipelineState(backgroundPipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BendUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

            if let desktop, let blurred = blurTextureB {
                encoder.setRenderPipelineState(bendPipeline)
                encoder.setVertexBuffer(gridVertices, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<BendUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BendUniforms>.stride, index: 1)
                encoder.setFragmentTexture(desktop, index: 0)
                encoder.setFragmentTexture(uniforms.blurMix > 0.001 ? blurred : desktop, index: 1)
                encoder.drawIndexedPrimitives(type: .triangle,
                                              indexCount: gridIndexCount,
                                              indexType: .uint32,
                                              indexBuffer: gridIndices,
                                              indexBufferOffset: 0)
            }
            encoder.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func runBlurPasses(commandBuffer: MTLCommandBuffer, source: MTLTexture, uniforms: BendUniforms) {
        guard let half = halfTexture, let blurA = blurTextureA, let blurB = blurTextureB else { return }

        func pass(_ pipeline: MTLRenderPipelineState,
                  from input: MTLTexture,
                  to output: MTLTexture,
                  direction: SIMD2<Float>?) {
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = output
            descriptor.colorAttachments[0].loadAction = .dontCare
            descriptor.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(input, index: 0)
            var local = uniforms
            encoder.setFragmentBytes(&local, length: MemoryLayout<BendUniforms>.stride, index: 1)
            if var direction {
                encoder.setFragmentBytes(&direction, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
            }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }

        func generateMipmaps(for texture: MTLTexture) {
            guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
        }

        pass(copyPipeline, from: source, to: half, direction: nil)
        generateMipmaps(for: half)
        pass(blurPipeline, from: half, to: blurA, direction: SIMD2(1, 0))
        generateMipmaps(for: blurA)
        pass(blurPipeline, from: blurA, to: blurB, direction: SIMD2(0, 1))
    }

    private func makeUniforms(viewSize: CGSize, pixelScale: Float) -> BendUniforms {
        let progress = smoothedProgress
        var uniforms = BendUniforms()
        uniforms.progress = progress
        let maxTilt = Float(settings.maxFoldDegrees) * .pi / 180
        uniforms.tilt = Float(settings.perspective) * maxTilt * progress
        uniforms.aspect = viewSize.height > 0 ? Float(viewSize.width / viewSize.height) : 1
        uniforms.cameraDist = Float(settings.cameraDistance)

        // Blur lags the fold slightly — it reads better if the sheet starts
        // moving before it starts softening.
        let blurStrength = Float(settings.blur) * pow(progress, 1.3)
        // The blur runs on a half-resolution copy, so a radius given in points
        // is scale/2 texels there: unchanged at 2x, correctly halved at 1x.
        // Specifying it in raw texels instead would make the same setting blur
        // twice as hard on a Retina display as on a standard one.
        let texelsPerPoint = pixelScale / 2
        uniforms.sigma = max(blurStrength * Float(settings.maxBlurRadius) * texelsPerPoint, 0.5)
        // Cross-fade to the blurred copy quickly and then stay there: a lasting
        // half-and-half mix keeps sharp edges visible through the blur, which
        // reads as a double image rather than as frost. Once sigma is wide
        // enough for the two to differ, the blurred one has to win outright.
        uniforms.blurMix = min(uniforms.sigma / 4, 1)
        uniforms.shadow = Float(settings.shadow) * progress
        return uniforms
    }

    /// Spring easing toward the hinge. Snappy enough to track a fast close,
    /// soft enough that a degree of sensor jitter doesn't show.
    ///
    /// Damping is a ratio of critical: at 1.0 it slides to a stop without ever
    /// passing the target, and a little under that it drifts fractionally past
    /// and comes back — which is what reads as settling rather than stopping.
    ///
    /// Integrated in small fixed substeps. A stiff spring stepped once with a
    /// long frame's dt overshoots on its own, so a dropped frame would show up
    /// as a kick in the animation rather than just a late one.
    private func advanceSpring(dt: Float) {
        let stiffness = Float(settings.springStiffness)
        let damping = 2 * sqrt(stiffness) * Float(settings.dampingRatio)

        var remaining = dt
        let maxStep: Float = 1.0 / 240
        while remaining > 0 {
            let step = min(remaining, maxStep)
            remaining -= step
            let displacement = smoothedProgress - targetProgress
            let acceleration = -stiffness * displacement - damping * velocity
            velocity += acceleration * step
            smoothedProgress += velocity * step
        }

        if abs(smoothedProgress - targetProgress) < 0.0002, abs(velocity) < 0.0005 {
            smoothedProgress = targetProgress
            velocity = 0
        }
        smoothedProgress = min(max(smoothedProgress, 0), 1.2)
    }

    enum RendererError: LocalizedError {
        case noQueue, noShaders

        var errorDescription: String? {
            switch self {
            case .noQueue: return "Couldn't create a Metal command queue."
            case .noShaders: return "Couldn't load Softclose's shaders."
            }
        }
    }
}
