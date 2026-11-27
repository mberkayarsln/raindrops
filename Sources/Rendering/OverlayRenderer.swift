import MetalKit

final class OverlayRenderer: NSObject, MTKViewDelegate {
    static let segmentCapacity = 32_000
    static let waterVertexCapacity = 24_000
    private static let framesInFlight = 3

    private let context: MetalContext
    private let simulation: RainSimulation
    private let inFlightSemaphore = DispatchSemaphore(value: OverlayRenderer.framesInFlight)
    private let segmentBuffers: [MTLBuffer]
    private let waterBuffers: [MTLBuffer]
    private var bufferIndex = 0
    var elapsedTime: Float = 0

    init?(context: MetalContext, simulation: RainSimulation) {
        let segmentLength = MemoryLayout<SegmentInstance>.stride * Self.segmentCapacity
        let waterLength = MemoryLayout<WaterVertex>.stride * Self.waterVertexCapacity
        let segmentBuffers = (0..<Self.framesInFlight).compactMap { _ in
            context.device.makeBuffer(length: segmentLength, options: .storageModeShared)
        }
        let waterBuffers = (0..<Self.framesInFlight).compactMap { _ in
            context.device.makeBuffer(length: waterLength, options: .storageModeShared)
        }
        guard segmentBuffers.count == Self.framesInFlight, waterBuffers.count == Self.framesInFlight else {
            return nil
        }
        self.context = context
        self.simulation = simulation
        self.segmentBuffers = segmentBuffers
        self.waterBuffers = waterBuffers
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        inFlightSemaphore.wait()
        guard
            let pass = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let commandBuffer = context.commandQueue.makeCommandBuffer()
        else {
            inFlightSemaphore.signal()
            return
        }
        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }
        encodeFrame(into: commandBuffer, pass: pass, viewSize: view.bounds.size, pixelScale: pixelScale(of: view))
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func encodeFrame(into commandBuffer: MTLCommandBuffer, pass: MTLRenderPassDescriptor, viewSize: CGSize, pixelScale: Float) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let segmentBuffer = segmentBuffers[bufferIndex]
        let waterBuffer = waterBuffers[bufferIndex]
        bufferIndex = (bufferIndex + 1) % Self.framesInFlight

        var segments = SegmentWriter(buffer: segmentBuffer)
        var water = WaterStripWriter(buffer: waterBuffer)
        simulation.render(segments: &segments, water: &water)

        var uniforms = FrameUniforms(
            viewSize: SIMD2(Float(viewSize.width), Float(viewSize.height)),
            time: elapsedTime,
            pixelScale: pixelScale
        )
        encodeWater(water, buffer: waterBuffer, uniforms: &uniforms, encoder: encoder)
        encodeSegments(segments, buffer: segmentBuffer, uniforms: &uniforms, encoder: encoder)
        encoder.endEncoding()
    }

    func writeInstancesOnly(into commandBuffer: MTLCommandBuffer, pass: MTLRenderPassDescriptor) {
        var segments = SegmentWriter(buffer: segmentBuffers[bufferIndex])
        var water = WaterStripWriter(buffer: waterBuffers[bufferIndex])
        bufferIndex = (bufferIndex + 1) % Self.framesInFlight
        simulation.render(segments: &segments, water: &water)
    }

    private func pixelScale(of view: MTKView) -> Float {
        let width = view.bounds.width
        return width > 0 ? Float(view.drawableSize.width / width) : 2
    }

    private func encodeWater(
        _ writer: WaterStripWriter,
        buffer: MTLBuffer,
        uniforms: inout FrameUniforms,
        encoder: MTLRenderCommandEncoder
    ) {
        guard writer.count >= 3 else { return }
        encoder.setRenderPipelineState(context.waterPipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: writer.count)
    }

    private func encodeSegments(
        _ writer: SegmentWriter,
        buffer: MTLBuffer,
        uniforms: inout FrameUniforms,
        encoder: MTLRenderCommandEncoder
    ) {
        guard writer.count > 0 else { return }
        encoder.setRenderPipelineState(context.segmentPipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        encoder.drawPrimitives(
            type: .triangleStrip,
            vertexStart: 0,
            vertexCount: 4,
            instanceCount: writer.count
        )
    }
}
