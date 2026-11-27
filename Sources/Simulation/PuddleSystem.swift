import simd

final class PuddleSystem {
    private var puddles: [UInt32: EdgePuddle] = [:]
    private var random = FastRandom()
    private(set) var emittedDrops: [FallingDrop] = []
    private var arrivedVolumes: [Float] = []
    private let maximumReleasedDrops = 220

    var count: Int { puddles.count }

    var faceFlow: Float {
        puddles.values.reduce(0) { total, puddle in total + puddle.faceStreams.reduce(0) { $0 + $1.flow } }
    }

    var deepestPuddle: Float {
        puddles.values.reduce(0) { max($0, $1.maximumDepth) }
    }

    func clearEmitted() {
        emittedDrops.removeAll(keepingCapacity: true)
    }

    func synchronize(with scene: SurfaceScene) {
        releaseVanishedPuddles(in: scene)
        for surface in scene.surfaces {
            if surface.isSubmerged {
                submerge(surface)
                continue
            }
            guard let puddle = puddles[surface.id] else {
                puddles[surface.id] = EdgePuddle(surface: surface, phase: random.value(in: 0...6.28))
                continue
            }
            if puddle.hasDrifted(from: surface) {
                release(puddle, layerOrder: surface.order)
                puddle.reanchor(to: surface)
            } else {
                puddle.follow(surface)
            }
        }
    }

    func deposit(windowID: UInt32, atX x: Float, volume: Float) {
        puddles[windowID]?.deposit(atX: x, volume: volume)
    }

    func step(dt: Float, scene: SurfaceScene, floorHeight: (Float) -> Float) {
        for surface in scene.surfaces {
            guard let puddle = puddles[surface.id] else { continue }
            let outflow = puddle.step(dt: dt)
            puddle.left.receive(volume: outflow.left, dt: dt)
            puddle.right.receive(volume: outflow.right, dt: dt)
            advance(&puddle.left, of: surface, scene: scene, dt: dt, floorHeight: floorHeight)
            advance(&puddle.right, of: surface, scene: scene, dt: dt, floorHeight: floorHeight)
            for site in puddle.faceStreams.indices {
                advanceFace(&puddle.faceStreams[site], atX: puddle.siteX(at: site), of: surface, dt: dt, floorHeight: floorHeight)
            }
        }
    }

    func renderWater(into writer: inout WaterStripWriter, scene: SurfaceScene) {
        for span in scene.spans {
            guard let puddle = puddles[span.windowID] else { continue }
            renderSpan(span, of: puddle, surface: scene.surfaces[span.surfaceIndex], into: &writer)
        }
    }

    func renderStreams(into segments: inout SegmentWriter, scene: SurfaceScene, time: Float) {
        for surface in scene.surfaces {
            guard let puddle = puddles[surface.id] else { continue }
            renderStream(puddle.left, scene: scene, time: time, into: &segments)
            renderStream(puddle.right, scene: scene, time: time, into: &segments)
            for stream in puddle.faceStreams {
                renderStream(stream, scene: scene, time: time, into: &segments)
            }
        }
    }

    private func submerge(_ surface: WindowSurface) {
        guard let puddle = puddles[surface.id] else { return }
        release(puddle, layerOrder: surface.order)
        puddles[surface.id] = nil
    }

    private func releaseVanishedPuddles(in scene: SurfaceScene) {
        for (id, puddle) in puddles where scene.surface(withID: id) == nil {
            release(puddle)
            puddles[id] = nil
        }
    }

    private func release(_ puddle: EdgePuddle, layerOrder: Int = .max) {
        let windowID = puddle.windowID
        puddle.drain { position, volume in
            guard emittedDrops.count < maximumReleasedDrops else { return }
            emittedDrops.append(makeDrip(at: position, volume: volume, ignoring: windowID, layerOrder: layerOrder, initialSpeed: random.value(in: 20...80)))
        }
    }

    private func advance(
        _ stream: inout EdgeStream,
        of surface: WindowSurface,
        scene: SurfaceScene,
        dt: Float,
        floorHeight: (Float) -> Float
    ) {
        let axisX = EdgeStream.axisX(for: stream.side, surface: surface)
        let bottomY = streamBottom(atX: axisX, surface: surface, scene: scene, floorHeight: floorHeight)
        flow(&stream, axisX: axisX, bottomY: bottomY, of: surface, corner: surface, dt: dt)
    }

    private func advanceFace(_ stream: inout EdgeStream, atX x: Float, of surface: WindowSurface, dt: Float, floorHeight: (Float) -> Float) {
        let bottomY = max(surface.minY, floorHeight(x))
        flow(&stream, axisX: x, bottomY: bottomY, of: surface, corner: nil, dt: dt)
    }

    private func flow(_ stream: inout EdgeStream, axisX: Float, bottomY: Float, of surface: WindowSurface, corner: WindowSurface?, dt: Float) {
        stream.route(axisX: axisX, topY: surface.topHeight(atX: axisX.clamped(to: surface.minX...surface.maxX)), bottomY: bottomY, surfaceOrder: surface.order, corner: corner)
        let end = stream.point(atDistance: stream.length)
        arrivedVolumes.removeAll(keepingCapacity: true)
        stream.advance(dt: dt, random: &random) { arrivedVolumes.append($0) }
        for volume in arrivedVolumes {
            let position = end + SIMD2(0, 0.5)
            emittedDrops.append(makeDrip(at: position, volume: volume, ignoring: surface.id, layerOrder: surface.order, initialSpeed: 90))
        }
    }

    private func streamBottom(atX x: Float, surface: WindowSurface, scene: SurfaceScene, floorHeight: (Float) -> Float) -> Float {
        var bottom = surface.minY + surface.radius * 0.4
        if let edge = scene.highestEdge(atX: x, below: surface.maxY - surface.radius, above: surface.minY, excluding: surface.id) {
            bottom = edge
        }
        return max(bottom, floorHeight(x))
    }

    private func makeDrip(at position: SIMD2<Float>, volume: Float, ignoring windowID: UInt32, layerOrder: Int, initialSpeed: Float) -> FallingDrop {
        let size = (volume / EdgeStream.dripVolume).squareRoot().clamped(to: 0.6...1.6)
        return FallingDrop(
            position: position,
            velocity: SIMD2(random.signedUnit() * 6, -initialSpeed),
            terminalSpeed: 1300,
            gravity: 1900,
            width: 2.1 * size,
            streak: 0.014,
            alpha: 0.62,
            volume: volume,
            ignoredWindowID: windowID,
            layerOrder: layerOrder,
            isRain: false
        )
    }

    private func renderSpan(_ span: EdgeSpan, of puddle: EdgePuddle, surface: WindowSurface, into writer: inout WaterStripWriter) {
        let cellWidth = EdgePuddle.cellWidth
        let first = max(Int(((span.minX - puddle.minX) / cellWidth).rounded(.down)), 0)
        let last = min(Int(((span.maxX - puddle.minX) / cellWidth).rounded(.up)), puddle.cells.count)
        guard last > first else { return }
        var deepest: Float = 0
        for index in first..<last { deepest = max(deepest, puddle.visualDepth(at: index)) }
        guard deepest > 0.12 else { return }
        writer.beginStrip()
        for boundary in first...last {
            let x = (puddle.minX + Float(boundary) * cellWidth).clamped(to: span.minX...span.maxX)
            let depth = boundaryDepth(boundary, of: puddle, first: first, last: last) * surface.cornerTaper(atX: x)
            let base = surface.topHeight(atX: x)
            writer.appendColumn(x: x, bottom: base, top: base + depth, opacity: 0.9)
        }
    }

    private func boundaryDepth(_ boundary: Int, of puddle: EdgePuddle, first: Int, last: Int) -> Float {
        let leftDepth = boundary > first ? puddle.visualDepth(at: boundary - 1) : puddle.visualDepth(at: boundary) * 0.6
        let rightDepth = boundary < last ? puddle.visualDepth(at: boundary) : puddle.visualDepth(at: boundary - 1) * 0.6
        return (leftDepth + rightDepth) * 0.5
    }

    private func renderStream(_ stream: EdgeStream, scene: SurfaceScene, time: Float, into segments: inout SegmentWriter) {
        renderPendant(of: stream, scene: scene, into: &segments)
        guard stream.isActive else { return }
        renderTrail(of: stream, scene: scene, into: &segments)
        for slug in stream.slugs {
            renderSlug(slug, of: stream, scene: scene, into: &segments)
        }
    }

    private func renderPendant(of stream: EdgeStream, scene: SurfaceScene, into segments: inout SegmentWriter) {
        let fraction = stream.pendantFraction
        guard stream.side == .face, fraction > 0.12 else { return }
        let radius = 0.7 + 1.3 * fraction
        let center = SIMD2(stream.axisX, stream.topY - radius * 0.9)
        guard !scene.isOccluded(center, inFrontOf: stream.surfaceOrder) else { return }
        let sag = SIMD2<Float>(0, -radius * 0.5 * fraction)
        segments.append(from: center, to: center + sag, width: radius * 2, color: Palette.tinted(Palette.stream, alpha: 0.32 + 0.25 * fraction), softness: 0.45)
        segments.append(from: center + SIMD2(-radius * 0.3, radius * 0.1), to: center + SIMD2(-radius * 0.3, radius * 0.1), width: radius * 0.7, color: Palette.tinted(Palette.streamHighlight, alpha: 0.45 * fraction), softness: 0.5)
    }

    private func renderTrail(of stream: EdgeStream, scene: SurfaceScene, into segments: inout SegmentWriter) {
        let opacity = stream.trailOpacity
        guard opacity > 0.01, stream.wetLength > 1 else { return }
        let color = Palette.tinted(Palette.stream, alpha: opacity)
        var distance: Float = 0
        var previous = stream.point(atDistance: 0)
        while distance < stream.wetLength {
            let step: Float = distance < stream.arcLength ? 3 : 12
            distance = min(distance + step, stream.wetLength)
            let current = stream.point(atDistance: distance)
            if !scene.isOccluded((previous + current) * 0.5, inFrontOf: stream.surfaceOrder) {
                segments.append(from: previous, to: current, width: stream.trailWidth, color: color, softness: 0.6, capStyle: .butt)
            }
            previous = current
        }
    }

    private func renderSlug(_ slug: RivuletSlug, of stream: EdgeStream, scene: SurfaceScene, into segments: inout SegmentWriter) {
        let head = stream.point(atDistance: slug.distance)
        guard !scene.isOccluded(head, inFrontOf: stream.surfaceOrder) else { return }
        if slug.isResidue {
            let alpha = 0.4 * min(slug.volume / EdgeStream.residueVolume, 1)
            segments.append(from: head, to: head, width: 1.3, color: Palette.tinted(Palette.stream, alpha: alpha), softness: 0.5)
            return
        }
        let tail = stream.point(atDistance: max(slug.distance - slug.length, 0))
        let width = 1.7 * slug.sizeFactor
        segments.append(from: tail, to: head, width: width, color: Palette.tinted(Palette.stream, alpha: 0.5), softness: 0.45, tailFade: 0.9)
        let glintStart = stream.point(atDistance: max(slug.distance - 2.5, 0)) + SIMD2(-width * 0.18, 0)
        segments.append(from: glintStart, to: head + SIMD2(-width * 0.18, -0.4), width: width * 0.4, color: Palette.tinted(Palette.streamHighlight, alpha: 0.55), softness: 0.5)
    }
}
