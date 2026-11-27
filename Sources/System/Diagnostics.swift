import Foundation
import QuartzCore

final class FrameDiagnostics {
    static let isEnabled = ProcessInfo.processInfo.environment["RAINDROPS_DIAGNOSTICS"] == "1"

    private let label: String
    private var windowStart: CFTimeInterval = 0
    private var frames = 0
    private var simulationSeconds: CFTimeInterval = 0

    init(label: String) {
        self.label = label
    }

    func record(at timestamp: CFTimeInterval, simulationCost: CFTimeInterval, details: () -> String) {
        guard Self.isEnabled else { return }
        if windowStart == 0 { windowStart = timestamp }
        frames += 1
        simulationSeconds += simulationCost
        let elapsed = timestamp - windowStart
        guard elapsed >= 2 else { return }
        let fps = Double(frames) / elapsed
        let costMilliseconds = simulationSeconds / Double(frames) * 1000
        FileHandle.standardError.write(Data("[\(label)] fps=\(Int(fps.rounded())) cpuFrameMs=\(String(format: "%.2f", costMilliseconds)) \(details())\n".utf8))
        windowStart = timestamp
        frames = 0
        simulationSeconds = 0
    }

    static func log(_ message: String) {
        guard isEnabled else { return }
        FileHandle.standardError.write(Data("[Raindrops] \(message)\n".utf8))
    }
}
