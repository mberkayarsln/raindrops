import CoreGraphics
import simd

struct WindowSurface {
    static let cornerRadius: Float = 16

    let id: UInt32
    let order: Int
    let minX: Float
    let maxX: Float
    let minY: Float
    let maxY: Float

    var width: Float { maxX - minX }

    var radius: Float {
        min(Self.cornerRadius, width * 0.5, (maxY - minY) * 0.5)
    }

    func contains(_ point: SIMD2<Float>) -> Bool {
        guard point.x > minX, point.x < maxX, point.y > minY, point.y < maxY else { return false }
        let inset = radius
        let nearest = SIMD2(point.x.clamped(to: (minX + inset)...(maxX - inset)), point.y.clamped(to: (minY + inset)...(maxY - inset)))
        return simd_length_squared(point - nearest) <= inset * inset
    }

    func topHeight(atX x: Float) -> Float {
        let inset = radius
        let cornerDistance = max(minX + inset - x, x - (maxX - inset), 0)
        guard cornerDistance > 0 else { return maxY }
        let clamped = min(cornerDistance, inset)
        return maxY - inset + (inset * inset - clamped * clamped).squareRoot()
    }

    func cornerTaper(atX x: Float) -> Float {
        let edgeDistance = min(x - minX, maxX - x)
        return ((edgeDistance - radius * 0.35) / (radius * 0.65)).clamped(to: 0...1)
    }

    func coversEdge(atY y: Float) -> Bool {
        y >= minY && y <= maxY + 0.5
    }
}

struct EdgeSpan {
    let y: Float
    let minX: Float
    let maxX: Float
    let windowID: UInt32
    let surfaceIndex: Int
}

struct EdgeHit {
    let point: SIMD2<Float>
    let windowID: UInt32
}

struct SurfaceScene {
    private(set) var surfaces: [WindowSurface] = []
    private(set) var spans: [EdgeSpan] = []
    private var indexByID: [UInt32: Int] = [:]
    private var intervals: [SIMD2<Float>] = []
    private var remainder: [SIMD2<Float>] = []

    mutating func rebuild(from records: [WindowRecord], screenOrigin: SIMD2<Float>, screenSize: SIMD2<Float>) {
        surfaces.removeAll(keepingCapacity: true)
        spans.removeAll(keepingCapacity: true)
        indexByID.removeAll(keepingCapacity: true)
        for (index, record) in records.enumerated() {
            guard !Self.isBackingWindow(record, behind: records[..<index]) else { continue }
            guard let surface = Self.localSurface(for: record, origin: screenOrigin, size: screenSize) else { continue }
            indexByID[surface.id] = surfaces.count
            surfaces.append(surface)
        }
        for index in surfaces.indices {
            appendVisibleSpans(ofSurfaceAt: index)
        }
    }

    func surface(withID id: UInt32) -> WindowSurface? {
        indexByID[id].map { surfaces[$0] }
    }

    func firstCrossing(from start: SIMD2<Float>, to end: SIMD2<Float>, ignoring ignoredID: UInt32) -> EdgeHit? {
        var best: EdgeHit?
        var bestY = -Float.greatestFiniteMagnitude
        for span in spans where span.windowID != ignoredID {
            guard end.x >= span.minX, end.x <= span.maxX, start.y >= span.y - surfaces[span.surfaceIndex].radius else { continue }
            let surfaceY = surfaces[span.surfaceIndex].topHeight(atX: end.x)
            guard start.y >= surfaceY, end.y < surfaceY, surfaceY > bestY else { continue }
            best = EdgeHit(point: SIMD2(end.x, surfaceY), windowID: span.windowID)
            bestY = surfaceY
        }
        return best
    }

    func containsPoint(_ point: SIMD2<Float>, ignoring ignoredID: UInt32, inFrontOf layerOrder: Int) -> Bool {
        for surface in surfaces {
            guard surface.order < layerOrder else { break }
            if surface.id != ignoredID && surface.contains(point) { return true }
        }
        return false
    }

    func isOccluded(_ point: SIMD2<Float>, inFrontOf order: Int) -> Bool {
        for surface in surfaces {
            guard surface.order < order else { break }
            if surface.contains(point) { return true }
        }
        return false
    }

    func isEdgeVisible(of windowID: UInt32, atX x: Float) -> Bool {
        for span in spans where span.windowID == windowID && x >= span.minX && x <= span.maxX {
            return true
        }
        return false
    }

    func highestEdge(atX x: Float, below upper: Float, above lower: Float, excluding windowID: UInt32) -> Float? {
        var best: Float?
        for span in spans where span.windowID != windowID && x >= span.minX && x <= span.maxX {
            let surfaceY = surfaces[span.surfaceIndex].topHeight(atX: x)
            guard surfaceY < upper, surfaceY > lower, surfaceY > (best ?? -Float.greatestFiniteMagnitude) else { continue }
            best = surfaceY
        }
        return best
    }

    private static func isBackingWindow(_ record: WindowRecord, behind front: ArraySlice<WindowRecord>) -> Bool {
        let tolerance: CGFloat = 4
        return front.contains { $0.frame.insetBy(dx: -tolerance, dy: -tolerance).contains(record.frame) }
    }

    private static func localSurface(for record: WindowRecord, origin: SIMD2<Float>, size: SIMD2<Float>) -> WindowSurface? {
        let minX = Float(record.frame.minX) - origin.x
        let maxX = Float(record.frame.maxX) - origin.x
        let minY = Float(record.frame.minY) - origin.y
        let maxY = Float(record.frame.maxY) - origin.y
        guard maxX > 0, minX < size.x, maxY > 0, minY < size.y + 4 else { return nil }
        return WindowSurface(id: record.id, order: record.order, minX: minX, maxX: maxX, minY: minY, maxY: maxY)
    }

    private mutating func appendVisibleSpans(ofSurfaceAt index: Int) {
        let surface = surfaces[index]
        intervals.removeAll(keepingCapacity: true)
        intervals.append(SIMD2(surface.minX, surface.maxX))
        for front in surfaces[..<index] where front.coversEdge(atY: surface.maxY) {
            subtract(front.minX, front.maxX)
            if intervals.isEmpty { return }
        }
        for interval in intervals where interval.y - interval.x > 1 {
            spans.append(EdgeSpan(y: surface.maxY, minX: interval.x, maxX: interval.y, windowID: surface.id, surfaceIndex: index))
        }
    }

    private mutating func subtract(_ lower: Float, _ upper: Float) {
        remainder.removeAll(keepingCapacity: true)
        for interval in intervals {
            if upper <= interval.x || lower >= interval.y {
                remainder.append(interval)
                continue
            }
            if lower > interval.x { remainder.append(SIMD2(interval.x, lower)) }
            if upper < interval.y { remainder.append(SIMD2(upper, interval.y)) }
        }
        swap(&intervals, &remainder)
    }
}
