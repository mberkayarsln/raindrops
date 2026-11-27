import Metal

enum MetalSetupError: Error {
    case deviceUnavailable
    case functionMissing(String)
}

final class MetalContext {
    static let shared: MetalContext? = try? MetalContext()

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let segmentPipeline: MTLRenderPipelineState
    let waterPipeline: MTLRenderPipelineState
    let pixelFormat: MTLPixelFormat = .bgra8Unorm

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw MetalSetupError.deviceUnavailable
        }
        let options = MTLCompileOptions()
        options.fastMathEnabled = true
        let library = try device.makeLibrary(source: ShaderSource.metal, options: options)
        self.device = device
        self.commandQueue = queue
        self.segmentPipeline = try Self.makePipeline(
            device: device,
            library: library,
            vertexName: "segmentVertex",
            fragmentName: "segmentFragment",
            pixelFormat: pixelFormat
        )
        self.waterPipeline = try Self.makePipeline(
            device: device,
            library: library,
            vertexName: "waterVertex",
            fragmentName: "waterFragment",
            pixelFormat: pixelFormat
        )
    }

    private static func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertexName: String,
        fragmentName: String,
        pixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        guard let vertexFunction = library.makeFunction(name: vertexName) else {
            throw MetalSetupError.functionMissing(vertexName)
        }
        guard let fragmentFunction = library.makeFunction(name: fragmentName) else {
            throw MetalSetupError.functionMissing(fragmentName)
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        configurePremultipliedBlending(descriptor.colorAttachments[0], pixelFormat: pixelFormat)
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func configurePremultipliedBlending(
        _ attachment: MTLRenderPipelineColorAttachmentDescriptor,
        pixelFormat: MTLPixelFormat
    ) {
        attachment.pixelFormat = pixelFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }
}
