import Metal
import simd

struct SegmentInstance {
    var start: SIMD2<Float>
    var end: SIMD2<Float>
    var color: SIMD4<Float>
    var width: Float
    var softness: Float
    var tailFade: Float
    var capRoundness: Float
}

enum SegmentCapStyle {
    case round
    case butt
}

struct WaterVertex {
    var position: SIMD2<Float>
    var depth: Float
    var opacity: Float
}

struct FrameUniforms {
    var viewSize: SIMD2<Float>
    var time: Float
    var pixelScale: Float
}

struct SegmentWriter {
    private let base: UnsafeMutablePointer<SegmentInstance>
    let capacity: Int
    private(set) var count = 0

    init(buffer: MTLBuffer) {
        capacity = buffer.length / MemoryLayout<SegmentInstance>.stride
        base = buffer.contents().bindMemory(to: SegmentInstance.self, capacity: capacity)
    }

    var isFull: Bool {
        count >= capacity
    }

    mutating func append(
        from start: SIMD2<Float>,
        to end: SIMD2<Float>,
        width: Float,
        color: SIMD4<Float>,
        softness: Float = 0.3,
        tailFade: Float = 0,
        capStyle: SegmentCapStyle = .round
    ) {
        guard count < capacity else { return }
        base[count] = SegmentInstance(
            start: start,
            end: end,
            color: color,
            width: width,
            softness: softness,
            tailFade: tailFade,
            capRoundness: capStyle == .round ? 1 : 0
        )
        count += 1
    }
}

struct WaterStripWriter {
    private let base: UnsafeMutablePointer<WaterVertex>
    let capacity: Int
    private(set) var count = 0
    private var needsBridge = false

    init(buffer: MTLBuffer) {
        capacity = buffer.length / MemoryLayout<WaterVertex>.stride
        base = buffer.contents().bindMemory(to: WaterVertex.self, capacity: capacity)
    }

    mutating func beginStrip() {
        needsBridge = count > 0
    }

    mutating func appendColumn(x: Float, bottom: Float, top: Float, opacity: Float) {
        guard count + 4 <= capacity else { return }
        let upper = WaterVertex(position: SIMD2(x, top), depth: 0, opacity: opacity)
        let lower = WaterVertex(position: SIMD2(x, bottom), depth: max(top - bottom, 0), opacity: opacity)
        if needsBridge {
            push(base[count - 1])
            push(upper)
            needsBridge = false
        }
        push(upper)
        push(lower)
    }

    private mutating func push(_ vertex: WaterVertex) {
        base[count] = vertex
        count += 1
    }
}
