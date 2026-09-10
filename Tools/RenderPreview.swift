import AppKit
import Metal
import MetalKit
import simd

// Offline harness for the fold: renders Bend.metal against a mock desktop at a
// range of hinge angles and writes PNGs. Lets the geometry be judged without
// Screen Recording permission or a moving lid.

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

let width = 1440, height = 900
let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!

// MARK: - Mock desktop

func makeDesktop() -> MTLTexture {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)!

    // Wallpaper
    let wallpaper = CGGradient(colorsSpace: colorSpace, colors: [
        CGColor(red: 0.15, green: 0.22, blue: 0.42, alpha: 1),
        CGColor(red: 0.52, green: 0.28, blue: 0.45, alpha: 1),
        CGColor(red: 0.92, green: 0.55, blue: 0.36, alpha: 1),
    ] as CFArray, locations: [0, 0.55, 1])!
    context.drawLinearGradient(wallpaper, start: CGPoint(x: 0, y: height),
                               end: CGPoint(x: width, y: 0), options: [])

    // Menu bar
    context.setFillColor(CGColor(gray: 0.1, alpha: 0.55))
    context.fill(CGRect(x: 0, y: height - 32, width: width, height: 32))

    // Two windows, so the fold has straight edges to distort
    func window(_ rect: CGRect, title: CGColor) {
        context.setFillColor(CGColor(gray: 0.13, alpha: 0.97))
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil))
        context.fillPath()
        context.setFillColor(title)
        context.addPath(CGPath(roundedRect: CGRect(x: rect.minX, y: rect.maxY - 34, width: rect.width, height: 34),
                               cornerWidth: 12, cornerHeight: 12, transform: nil))
        context.fillPath()
        // Text lines
        context.setFillColor(CGColor(gray: 0.75, alpha: 0.7))
        for row in 0..<Int((rect.height - 70) / 26) {
            let y = rect.maxY - 66 - CGFloat(row) * 26
            let w = rect.width * (row % 3 == 0 ? 0.75 : 0.5)
            context.fill(CGRect(x: rect.minX + 24, y: y, width: w, height: 8))
        }
    }
    window(CGRect(x: 90, y: 150, width: 620, height: 540), title: CGColor(gray: 0.22, alpha: 1))
    window(CGRect(x: 640, y: 90, width: 700, height: 620), title: CGColor(red: 0.2, green: 0.24, blue: 0.3, alpha: 1))

    // Dock
    context.setFillColor(CGColor(gray: 0.9, alpha: 0.22))
    context.addPath(CGPath(roundedRect: CGRect(x: width / 2 - 260, y: 14, width: 520, height: 64),
                           cornerWidth: 18, cornerHeight: 18, transform: nil))
    context.fillPath()

    let image = context.makeImage()!
    let loader = MTKTextureLoader(device: device)
    return try! loader.newTexture(cgImage: image, options: [.SRGB: false])
}

// MARK: - Pipelines

let source = try! String(contentsOfFile: "Sources/Softclose/Shaders/Bend.metal", encoding: .utf8)
let library = try! device.makeLibrary(source: source, options: nil)

func pipeline(_ vertex: String, _ fragment: String) -> MTLRenderPipelineState {
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: vertex)
    descriptor.fragmentFunction = library.makeFunction(name: fragment)
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    return try! device.makeRenderPipelineState(descriptor: descriptor)
}
let bendPipeline = pipeline("bend_vertex", "bend_fragment")
let backgroundPipeline = pipeline("fullscreen_vertex", "background_fragment")
let blurPipeline = pipeline("fullscreen_vertex", "blur_fragment")
let copyPipeline = pipeline("fullscreen_vertex", "copy_fragment")

// MARK: - Grid

let resolution = 64
var gridVertices: [SIMD2<Float>] = []
for row in 0...resolution {
    for column in 0...resolution {
        gridVertices.append(SIMD2(Float(column) / Float(resolution), Float(row) / Float(resolution)))
    }
}
var gridIndices: [UInt32] = []
let stride32 = UInt32(resolution + 1)
for row in 0..<UInt32(resolution) {
    for column in 0..<UInt32(resolution) {
        let topLeft = row * stride32 + column
        gridIndices += [topLeft, topLeft + stride32, topLeft + 1,
                        topLeft + 1, topLeft + stride32, topLeft + stride32 + 1]
    }
}
let vertexBuffer = device.makeBuffer(bytes: gridVertices, length: gridVertices.count * MemoryLayout<SIMD2<Float>>.stride)!
let indexBuffer = device.makeBuffer(bytes: gridIndices, length: gridIndices.count * MemoryLayout<UInt32>.stride)!

// MARK: - Render

func texture(_ w: Int, _ h: Int, shared: Bool = false, mipmapped: Bool = false) -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: mipmapped)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = shared ? .shared : .private
    return device.makeTexture(descriptor: descriptor)!
}

let desktop = makeDesktop()
let half = texture(width / 2, height / 2, mipmapped: true)
let blurA = texture(width / 2, height / 2, mipmapped: true)
let blurB = texture(width / 2, height / 2)
let output = texture(width, height, shared: true)

func render(progress: Float, perspective: Float, blur: Float, shadow: Float, to path: String) {
    var uniforms = BendUniforms()
    uniforms.progress = progress
    uniforms.tilt = perspective * (62 * .pi / 180) * progress
    uniforms.aspect = Float(width) / Float(height)
    uniforms.cameraDist = 3.0
    let blurStrength = blur * pow(progress, 1.3)
    uniforms.sigma = max(blurStrength * 18, 0.5)
    uniforms.blurMix = min(uniforms.sigma / 4, 1)
    uniforms.shadow = shadow * progress
    uniforms.texelSize = SIMD2(2.0 / Float(width), 2.0 / Float(height))

    let commandBuffer = queue.makeCommandBuffer()!

    func pass(_ state: MTLRenderPipelineState, from input: MTLTexture, to target: MTLTexture, direction: SIMD2<Float>?) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)!
        encoder.setRenderPipelineState(state)
        encoder.setFragmentTexture(input, index: 0)
        var local = uniforms
        encoder.setFragmentBytes(&local, length: MemoryLayout<BendUniforms>.stride, index: 1)
        if var direction { encoder.setFragmentBytes(&direction, length: MemoryLayout<SIMD2<Float>>.stride, index: 2) }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    func mips(_ texture: MTLTexture) {
        let blit = commandBuffer.makeBlitCommandEncoder()!
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
    }

    pass(copyPipeline, from: desktop, to: half, direction: nil)
    mips(half)
    pass(blurPipeline, from: half, to: blurA, direction: SIMD2(1, 0))
    mips(blurA)
    pass(blurPipeline, from: blurA, to: blurB, direction: SIMD2(0, 1))

    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = output
    descriptor.colorAttachments[0].loadAction = .clear
    descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    descriptor.colorAttachments[0].storeAction = .store
    let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)!
    encoder.setRenderPipelineState(backgroundPipeline)
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BendUniforms>.stride, index: 1)
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

    encoder.setRenderPipelineState(bendPipeline)
    encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
    encoder.setVertexBytes(&uniforms, length: MemoryLayout<BendUniforms>.stride, index: 1)
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BendUniforms>.stride, index: 1)
    encoder.setFragmentTexture(desktop, index: 0)
    encoder.setFragmentTexture(uniforms.blurMix > 0.001 ? blurB : desktop, index: 1)
    encoder.drawIndexedPrimitives(type: .triangle, indexCount: gridIndices.count,
                                  indexType: .uint32, indexBuffer: indexBuffer, indexBufferOffset: 0)
    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    // Read back
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    output.getBytes(&bytes, bytesPerRow: width * 4,
                    from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                 | CGBitmapInfo.byteOrder32Little.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/preview"
try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

// Silk at a range of hinge positions.
for progress in [0.0, 0.2, 0.45, 0.7, 1.0] as [Float] {
    render(progress: progress, perspective: 1.0, blur: 0.35, shadow: 0.30,
           to: "\(outputDirectory)/silk-\(Int(progress * 100)).png")
}
// The other two styles, halfway down.
render(progress: 0.6, perspective: 0.70, blur: 0.40, shadow: 1.00, to: "\(outputDirectory)/shade-60.png")
render(progress: 0.6, perspective: 0.55, blur: 1.00, shadow: 0.50, to: "\(outputDirectory)/frost-60.png")
