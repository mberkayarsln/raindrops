import simd

struct PuddleOutflow {
    var left: Float = 0
    var right: Float = 0
}

private enum DrainTarget {
    case leftCorner
    case rightCorner
    case site(Int)
}

final class EdgePuddle {
    static let cellWidth: Float = 4
    static let filmDepth: Float = 0.2
    static let drainSpeed: Float = 50
    static let diffusionRate: Float = 3
    static let evaporationRate: Float = 0.03
    static let driftTolerance: Float = 1.5
    static let maximumVisualDepth: Float = 4.5
    static let cornerMargin: ClosedRange<Float> = 20...55
    static let siteSpacing: ClosedRange<Float> = 60...120

    let windowID: UInt32
    private(set) var minX: Float
    private(set) var topY: Float
    private(set) var cells: [Float]
    private var scratch: [Float]
    private var anchor: SIMD2<Float>
    private var siteOffsets: [Float] = []
    private var drainTargets: [DrainTarget] = []
    private var drainDirections: [Int] = []
    private var faceInflow: [Float] = []
    private let basePhase: Float
    var left: EdgeStream
    var right: EdgeStream
    var faceStreams: [EdgeStream] = []

    init(surface: WindowSurface, phase: Float) {
        windowID = surface.id
        minX = surface.minX
        topY = surface.maxY
        anchor = SIMD2(surface.minX, surface.maxY)
        basePhase = phase
        cells = Array(repeating: 0, count: Self.cellCount(for: surface.width))
        scratch = cells
        left = EdgeStream(side: .left, phase: phase)
        right = EdgeStream(side: .right, phase: phase + 1.7)
        rebuildDrainage()
    }

    var maximumDepth: Float {
        cells.max() ?? 0
    }

    var width: Float {
        Float(cells.count) * Self.cellWidth
    }

    func siteX(at index: Int) -> Float {
        minX + siteOffsets[index]
    }

    func hasDrifted(from surface: WindowSurface) -> Bool {
        abs(surface.minX - anchor.x) > Self.driftTolerance || abs(surface.maxY - anchor.y) > Self.driftTolerance
    }

    func follow(_ surface: WindowSurface) {
        minX = surface.minX
        topY = surface.maxY
        resize(to: Self.cellCount(for: surface.width))
    }

    func reanchor(to surface: WindowSurface) {
        anchor = SIMD2(surface.minX, surface.maxY)
        follow(surface)
    }

    func deposit(atX x: Float, volume: Float) {
        guard !cells.isEmpty else { return }
        let index = Int((x - minX) / Self.cellWidth).clamped(to: 0...(cells.count - 1))
        cells[index] += volume / Self.cellWidth
    }

    func visualDepth(at index: Int) -> Float {
        guard index >= 0, index < cells.count else { return 0 }
        return min(cells[index], Self.maximumVisualDepth) * 0.85
    }

    func drain(_ emit: (SIMD2<Float>, Float) -> Void) {
        let group = 3
        var start = 0
        while start < cells.count {
            let end = min(start + group, cells.count)
            let volume = cells[start..<end].reduce(0, +) * Self.cellWidth
            if volume > 0.4 {
                let centerX = minX + Float(start + end) * 0.5 * Self.cellWidth
                emit(SIMD2(centerX, topY + 1), volume)
            }
            start = end
        }
        for index in cells.indices { cells[index] = 0 }
        left.reset()
        right.reset()
        for site in faceStreams.indices { faceStreams[site].reset() }
    }

    func step(dt: Float) -> PuddleOutflow {
        var outflow = PuddleOutflow()
        for site in faceInflow.indices { faceInflow[site] = 0 }
        guard !cells.isEmpty else { return outflow }
        let transfer = min(Self.drainSpeed * dt / Self.cellWidth, 0.5)
        for index in cells.indices { scratch[index] = cells[index] }
        for index in cells.indices {
            let moving = max(cells[index] - Self.filmDepth, 0) * transfer
            guard moving > 0 else { continue }
            scratch[index] -= moving
            let direction = drainDirections[index]
            if direction == 0 {
                deliver(moving * Self.cellWidth, to: drainTargets[index], outflow: &outflow)
            } else {
                scratch[index + direction] += moving
            }
        }
        smooth(dt: dt)
        let evaporation = Self.evaporationRate * dt
        for index in cells.indices { cells[index] = max(scratch[index] - evaporation, 0) }
        for site in faceStreams.indices { faceStreams[site].receive(volume: faceInflow[site], dt: dt) }
        return outflow
    }

    private func deliver(_ volume: Float, to target: DrainTarget, outflow: inout PuddleOutflow) {
        switch target {
        case .leftCorner: outflow.left += volume
        case .rightCorner: outflow.right += volume
        case .site(let site): faceInflow[site] += volume
        }
    }

    private func smooth(dt: Float) {
        let diffusion = min(Self.diffusionRate * dt, 0.2)
        for index in 0..<(cells.count - 1) {
            let exchange = (cells[index] - cells[index + 1]) * diffusion
            scratch[index] -= exchange
            scratch[index + 1] += exchange
        }
    }

    private func resize(to count: Int) {
        guard count != cells.count else { return }
        if count < cells.count {
            cells.removeLast(cells.count - count)
        } else {
            cells.append(contentsOf: repeatElement(0, count: count - cells.count))
        }
        scratch = cells
        rebuildDrainage()
    }

    private func rebuildDrainage() {
        siteOffsets = Self.siteOffsets(width: width, windowID: windowID)
        while faceStreams.count < siteOffsets.count {
            faceStreams.append(EdgeStream(side: .face, phase: basePhase + 3.1 + Float(faceStreams.count) * 2.3))
        }
        if faceStreams.count > siteOffsets.count {
            faceStreams.removeLast(faceStreams.count - siteOffsets.count)
        }
        faceInflow = Array(repeating: 0, count: siteOffsets.count)
        assignDrains()
    }

    private func assignDrains() {
        let lastCell = cells.count - 1
        drainTargets = []
        drainDirections = []
        drainTargets.reserveCapacity(cells.count)
        drainDirections.reserveCapacity(cells.count)
        for index in cells.indices {
            let center = (Float(index) + 0.5) * Self.cellWidth
            var target = DrainTarget.leftCorner
            var targetCell = 0
            var bestDistance = center
            if width - center < bestDistance {
                target = .rightCorner
                targetCell = lastCell
                bestDistance = width - center
            }
            for (site, offset) in siteOffsets.enumerated() where abs(offset - center) < bestDistance {
                target = .site(site)
                targetCell = Int(offset / Self.cellWidth).clamped(to: 0...lastCell)
                bestDistance = abs(offset - center)
            }
            drainTargets.append(target)
            drainDirections.append(targetCell == index ? 0 : (targetCell < index ? -1 : 1))
        }
    }

    private static func siteOffsets(width: Float, windowID: UInt32) -> [Float] {
        var random = FastRandom(seed: UInt64(windowID) &* 0x9E37_79B9 &+ 1)
        var offsets: [Float] = []
        var position = random.value(in: cornerMargin)
        while position < width - cornerMargin.lowerBound {
            offsets.append(position)
            position += random.value(in: siteSpacing)
        }
        return offsets
    }

    private static func cellCount(for width: Float) -> Int {
        max(2, Int((width / cellWidth).rounded(.up)))
    }
}
