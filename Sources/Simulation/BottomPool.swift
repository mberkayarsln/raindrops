import simd

final class BottomPool {
    static let columnWidth: Float = 4
    private static let tick: Float = 1.0 / 120.0
    private static let waveStiffness: Float = 1225
    private static let restoringForce: Float = 9
    private static let damping: Float = 0.994
    private static let evaporationRate: Float = 0.12
    private static let maximumOffset: Float = 28
    private static let maximumTicksPerStep = 4

    private(set) var width: Float
    private(set) var level: Float = 0
    var maximumLevel: Float
    var isEnabled = true {
        didSet { if !isEnabled { reset() } }
    }
    private var offsets: [Float]
    private var velocities: [Float]
    private var accumulator: Float = 0

    init(width: Float, maximumLevel: Float) {
        self.width = width
        self.maximumLevel = maximumLevel
        let count = Self.pointCount(for: width)
        offsets = Array(repeating: 0, count: count)
        velocities = offsets
    }

    var isVisible: Bool {
        isEnabled && level > 0.3
    }

    func resize(to newWidth: Float) {
        guard newWidth != width else { return }
        width = newWidth
        offsets = Array(repeating: 0, count: Self.pointCount(for: newWidth))
        velocities = offsets
    }

    func surfaceHeight(atX x: Float) -> Float {
        guard isEnabled, level > 0 else { return 0 }
        let position = (x / Self.columnWidth).clamped(to: 0...Float(offsets.count - 1))
        let lower = min(Int(position), offsets.count - 2)
        let fraction = position - Float(lower)
        let offset = offsets[lower] + (offsets[lower + 1] - offsets[lower]) * fraction
        return max(level + offset * waveScale, 0)
    }

    func prefill(level newLevel: Float) {
        level = min(max(newLevel, 0), maximumLevel)
    }

    func receive(volume: Float, atX x: Float, impulse: Float, radius: Float) {
        guard isEnabled else { return }
        level = min(level + volume / max(width, 1), maximumLevel)
        disturb(atX: x, strength: impulse, radius: radius)
    }

    func disturb(atX x: Float, strength: Float, radius: Float) {
        guard isEnabled else { return }
        let reach = radius * 3
        let first = max(Int(((x - reach) / Self.columnWidth).rounded(.down)), 0)
        let last = min(Int(((x + reach) / Self.columnWidth).rounded(.up)), offsets.count - 1)
        guard first <= last else { return }
        let scale = 1 / max(radius, 1)
        for index in first...last {
            let normalized = (Float(index) * Self.columnWidth - x) * scale
            let squared = normalized * normalized
            velocities[index] -= strength * (1 - 2 * squared) * exp(-squared)
        }
    }

    func step(dt: Float) {
        guard isEnabled else { return }
        updateLevel(dt: dt)
        accumulator = min(accumulator + dt, Self.tick * Float(Self.maximumTicksPerStep))
        while accumulator >= Self.tick {
            integrateWaves()
            accumulator -= Self.tick
        }
    }

    func render(into writer: inout WaterStripWriter) {
        guard isVisible else { return }
        writer.beginStrip()
        for index in offsets.indices {
            let x = min(Float(index) * Self.columnWidth, width)
            writer.appendColumn(x: x, bottom: -2, top: surfaceHeight(atX: x), opacity: 1)
        }
    }

    private var waveScale: Float {
        min(level / 6, 1)
    }

    private func updateLevel(dt: Float) {
        level = max(level - Self.evaporationRate * dt, 0)
        if level > maximumLevel {
            level = max(level - max(level - maximumLevel, 0) * min(dt * 2, 1) - dt, maximumLevel)
        }
    }

    private func integrateWaves() {
        let count = offsets.count
        let tick = Self.tick
        for index in 0..<count {
            let left = offsets[max(index - 1, 0)]
            let right = offsets[min(index + 1, count - 1)]
            let center = offsets[index]
            let acceleration = Self.waveStiffness * (left + right - 2 * center) - Self.restoringForce * center
            velocities[index] = (velocities[index] + acceleration * tick) * Self.damping
        }
        var total: Float = 0
        for index in 0..<count {
            offsets[index] = (offsets[index] + velocities[index] * tick).clamped(to: -Self.maximumOffset...Self.maximumOffset)
            total += offsets[index]
        }
        let mean = total / Float(count)
        for index in 0..<count {
            offsets[index] -= mean
        }
    }

    private func reset() {
        level = 0
        for index in offsets.indices {
            offsets[index] = 0
            velocities[index] = 0
        }
    }

    private static func pointCount(for width: Float) -> Int {
        max(Int((width / columnWidth).rounded(.up)) + 1, 3)
    }
}
