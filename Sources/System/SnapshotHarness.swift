import AppKit
import Metal
import QuartzCore

struct SnapshotRequest {
    let outputPath: String
    let frames: Int
    let size: CGSize
    let scale: Int
    let isLowPowerModeEnabled: Bool
    let intensity: RainIntensity?
    let usesLiveWindows: Bool

    init?(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return nil }
        outputPath = arguments[index + 1]
        frames = Self.integer(after: "--frames", in: arguments) ?? 600
        size = CGSize(width: 1470, height: 956)
        isLowPowerModeEnabled = arguments.contains("--low-power")
        usesLiveWindows = arguments.contains("--live-windows")
        intensity = arguments.firstIndex(of: "--intensity").flatMap { index in
            index + 1 < arguments.count ? RainIntensity(rawValue: arguments[index + 1]) : nil
        }
        scale = 2
    }

    private static func integer(after flag: String, in arguments: [String]) -> Int? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return Int(arguments[index + 1])
    }
}

final class SnapshotHarness {
    private let request: SnapshotRequest
    private let context: MetalContext
    private let settings: AppSettings

    init(request: SnapshotRequest, context: MetalContext, settings: AppSettings) {
        self.request = request
        self.context = context
        self.settings = settings
    }

    func run() -> Bool {
        let size = SIMD2(Float(request.size.width), Float(request.size.height))
        var configuration = SimulationConfiguration(settings: settings, isLowPowerModeEnabled: request.isLowPowerModeEnabled)
        configuration.intensity = request.intensity ?? configuration.intensity
        configuration.maximumDropCount = 2000
        configuration.isPoolEnabled = true
        let simulation = RainSimulation(size: size, configuration: configuration)
        let cost = advance(simulation)
        print("snapshot frames=\(request.frames) meanStepMs=\(String(format: "%.3f", cost * 1000)) \(simulation.diagnosticSummary)")
        guard let texture = render(simulation) else { return false }
        measureEncoding(simulation)
        return writeImage(from: texture)
    }

    private lazy var scenarioWindows: [WindowRecord] = request.usesLiveWindows ? WindowGeometryProvider.currentWindows() : syntheticWindows

    private var syntheticWindows: [WindowRecord] {
        [
            WindowRecord(id: 101, frame: CGRect(x: 560, y: 330, width: 520, height: 300), order: 0),
            WindowRecord(id: 102, frame: CGRect(x: 180, y: 260, width: 640, height: 460), order: 1),
            WindowRecord(id: 103, frame: CGRect(x: 980, y: 140, width: 380, height: 380), order: 2),
            WindowRecord(id: 104, frame: CGRect(x: 120, y: 90, width: 1180, height: 120), order: 3)
        ]
    }

    private func scriptedCursor(frame: Int) -> CursorSample? {
        let remaining = request.frames - frame
        guard remaining < 90 else { return nil }
        let progress = Float(90 - remaining) / 90
        let position = SIMD2<Float>(300 + progress * 500, 420 - progress * 410)
        return CursorSample(position: position, velocity: SIMD2(500 * 60 / 90, -410 * 60 / 90))
    }

    private func advance(_ simulation: RainSimulation) -> CFTimeInterval {
        var total: CFTimeInterval = 0
        for frameIndex in 0..<request.frames {
            let start = CACurrentMediaTime()
            simulation.step(dt: 1.0 / 60.0, windows: scenarioWindows, screenOrigin: .zero, cursor: scriptedCursor(frame: frameIndex))
            total += CACurrentMediaTime() - start
        }
        return total / Double(max(request.frames, 1))
    }

    private func measureEncoding(_ simulation: RainSimulation) {
        guard let renderer = OverlayRenderer(context: context, simulation: simulation) else { return }
        let iterations = 120
        let start = CACurrentMediaTime()
        for _ in 0..<iterations {
            guard let buffer = context.commandQueue.makeCommandBuffer() else { return }
            let pass = MTLRenderPassDescriptor()
            renderer.writeInstancesOnly(into: buffer, pass: pass)
            buffer.commit()
        }
        let elapsed = (CACurrentMediaTime() - start) / Double(iterations)
        print("instance write meanMs=\(String(format: "%.3f", elapsed * 1000))")
    }

    private func render(_ simulation: RainSimulation) -> MTLTexture? {
        let pixelWidth = Int(request.size.width) * request.scale
        let pixelHeight = Int(request.size.height) * request.scale
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: context.pixelFormat, width: pixelWidth, height: pixelHeight, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard
            let texture = context.device.makeTexture(descriptor: descriptor),
            let renderer = OverlayRenderer(context: context, simulation: simulation),
            let commandBuffer = context.commandQueue.makeCommandBuffer()
        else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        renderer.encodeFrame(into: commandBuffer, pass: pass, viewSize: request.size, pixelScale: Float(request.scale))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return texture
    }

    private func writeImage(from texture: MTLTexture) -> Bool {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        texture.getBytes(&bytes, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let overlayInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard
            let provider = CGDataProvider(data: Data(bytes) as CFData),
            let overlay = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: overlayInfo), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
            let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        drawBackdrop(in: canvas, width: width, height: height)
        canvas.draw(overlay, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let composed = canvas.makeImage() else { return false }
        let representation = NSBitmapImageRep(cgImage: composed)
        guard let data = representation.representation(using: .png, properties: [:]) else { return false }
        return FileManager.default.createFile(atPath: request.outputPath, contents: data)
    }

    private func drawBackdrop(in canvas: CGContext, width: Int, height: Int) {
        canvas.setFillColor(CGColor(red: 0.10, green: 0.11, blue: 0.14, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let scale = CGFloat(request.scale)
        for record in scenarioWindows.reversed() {
            let rect = CGRect(x: record.frame.minX * scale, y: record.frame.minY * scale, width: record.frame.width * scale, height: record.frame.height * scale)
            let shade = 0.22 + CGFloat(record.order) * 0.05
            let cornerRadius = CGFloat(WindowSurface.cornerRadius) * scale
            let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            canvas.setFillColor(CGColor(red: shade, green: shade + 0.01, blue: shade + 0.03, alpha: 1))
            canvas.addPath(path)
            canvas.fillPath()
            canvas.setStrokeColor(CGColor(gray: 0.45, alpha: 1))
            canvas.setLineWidth(2)
            canvas.addPath(path)
            canvas.strokePath()
        }
    }
}
