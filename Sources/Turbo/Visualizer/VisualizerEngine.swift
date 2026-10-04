import TurboCore
import SwiftUI

/// Draws the iTunes-style visualizer into a SwiftUI `Canvas`. Agent activity drives it: every
/// tool call is a beat, a new prompt is a drop, and a finished turn is the finale. With "Move
/// With Your Music" on, whatever's playing sets the energy and its beats kick too.
///
/// State lives in this reference type and is advanced from inside the Canvas renderer, so the
/// SwiftUI view tree never re-renders per frame.
final class VisualizerEngine {
    var preset: VisualizerPreset = .magnetosphere
    /// The look being faded out after a switch.
    private var previousPreset: VisualizerPreset?
    private var transitionStart: Double = 0
    private static let transitionDuration = 0.9
    /// Hues of the agents that are cooking right now. Empty means idle drift.
    var palette: [Double] = []
    var isCooking = false
    /// What's playing on the Mac, when the visualizer listens to music.
    var music: (() -> MusicLevels)?
    private var lastBeatSeen = 0
    /// This frame's music, when listening: the spectrum folded into one level per color bucket.
    private var musicFrame: MusicLevels?
    private var bucketLevels = [Double](repeating: 0, count: VisualizerEngine.buckets)

    /// How loud this color's slice of the spectrum is (0 when there's no music).
    private func band(_ bucket: Int) -> Double { bucketLevels[bucket % Self.buckets] }

    private struct Particle {
        var p: CGPoint
        var v: CGVector
        var bucket: Int
        var attractor: Int
    }

    private struct Star {
        var x: Double
        var y: Double
        var z: Double
        var bucket: Int
    }

    private struct Burst {
        var birth: Double
        var hue: Double
        var strength: Double
        var center: CGPoint
    }

    private struct Ribbon {
        var a: Double
        var b: Double
        var c: Double
        var phase: Double
        var bucket: Int
    }

    private static let buckets = 6
    /// Hue offsets from the base hue for each color bucket: a tight analogous spread plus one accent.
    private static let bucketHueOffsets: [Double] = [-0.06, -0.025, 0, 0.03, 0.07, 0.5]

    private var energy: Double = 0.3
    private var now: Double = 0
    private var lastTime: Double?
    /// Animation time; runs faster when energy is high.
    private var clock: Double = 0
    private var hue: Double = 0.05
    private var particles: [Particle] = []
    private var stars: [Star] = []
    private var ribbons: [Ribbon] = []
    private var bursts: [Burst] = []

    init() {
        particles = (0..<520).map { _ in
            Particle(
                p: CGPoint(x: .random(in: -1.5...1.5), y: .random(in: -1...1)),
                v: CGVector(dx: .random(in: -0.3...0.3), dy: .random(in: -0.3...0.3)),
                bucket: Self.randomBucket(),
                attractor: .random(in: 0..<3)
            )
        }
        stars = (0..<420).map { _ in
            Star(x: .random(in: -1.6...1.6), y: .random(in: -1...1), z: .random(in: 0.05...1), bucket: Self.randomBucket())
        }
        ribbons = (0..<5).map { i in
            Ribbon(a: .random(in: 0.6...1.6), b: .random(in: 0.7...1.9), c: .random(in: 0.3...1.1), phase: Double(i) * 1.3, bucket: i % (Self.buckets - 1))
        }
    }

    /// The accent bucket shows up rarely so it reads as a highlight, not a second palette.
    private static func randomBucket() -> Int {
        Double.random(in: 0...1) < 0.07 ? buckets - 1 : .random(in: 0..<(buckets - 1))
    }

    // MARK: Input

    /// Switches looks with a crossfade.
    func transition(to newPreset: VisualizerPreset) {
        guard newPreset != preset else { return }
        previousPreset = preset
        transitionStart = now
        preset = newPreset
    }

    private var transitionProgress: Double {
        guard previousPreset != nil else { return 1 }
        let t = min(1, max(0, (now - transitionStart) / Self.transitionDuration))
        return t * t * (3 - 2 * t)
    }

    private func isShowing(_ candidate: VisualizerPreset) -> Bool {
        candidate == preset || (candidate == previousPreset && transitionProgress < 1)
    }

    func handle(_ pulse: Pulse) {
        switch pulse.kind {
        case .start: kick(0.9, hue: pulse.agent.hue)
        case .beat:
            // Match the step: commands hit hard, edits shift the color, reading is a light tick.
            switch pulse.tool.map(stepLabel) {
            case "Command": kick(0.7, hue: pulse.agent.hue)
            case "Edit":
                kick(0.45, hue: pulse.agent.hue + 0.1)
                hue += 0.04
            case "Read": kick(0.18, hue: pulse.agent.hue - 0.04)
            case "Web": kick(0.4, hue: 0.55)
            case "Helper": kick(0.55, hue: pulse.agent.hue + 0.2)
            default: kick(0.32, hue: pulse.agent.hue)
            }
        case .needsInput: kick(0.5, hue: 0.14)
        case .finish: celebrate(hue: pulse.agent.hue)
        }
    }

    func kick(_ amount: Double, hue: Double) {
        energy = min(energy + amount, 3)
        bursts.append(Burst(birth: now, hue: hue, strength: amount, center: CGPoint(x: .random(in: -0.2...0.2), y: .random(in: -0.2...0.2))))
        for i in particles.indices where Double.random(in: 0...1) < amount * 0.3 {
            particles[i].v.dx += CGFloat.random(in: -1...1) * amount
            particles[i].v.dy += CGFloat.random(in: -1...1) * amount
        }
    }

    func celebrate(hue: Double) {
        energy = 2.8
        for i in 0..<6 {
            bursts.append(Burst(birth: now + Double(i) * 0.16, hue: hue + Double(i) * 0.04, strength: 1.2, center: .zero))
        }
        // Fireworks: fling every particle outward from the center.
        for i in particles.indices {
            let p = particles[i].p
            let d = max(0.05, hypot(p.x, p.y))
            let push = Double.random(in: 1.5...3.2)
            particles[i].v = CGVector(dx: p.x / d * push, dy: p.y / d * push)
        }
    }

    // MARK: Frame

    func render(_ ctx: inout GraphicsContext, size: CGSize, time: Double) {
        let dt = min(max(time - (lastTime ?? time), 0), 1.0 / 15)
        lastTime = time
        now = time
        step(dt, aspect: size.width / max(size.height, 1))

        let frame = Frame(size: size)
        drawBackground(&ctx, frame)
        ctx.blendMode = .plusLighter
        let progress = transitionProgress
        if let previous = previousPreset {
            if progress < 1 {
                var fading = ctx
                fading.opacity = 1 - progress
                draw(previous, &fading, frame)
            } else {
                previousPreset = nil
            }
        }
        ctx.opacity = previousPreset == nil ? 1 : progress
        draw(preset, &ctx, frame)
        ctx.opacity = 1
        if let levels = musicFrame { drawSpectrum(&ctx, frame, levels) }
        drawBursts(&ctx, frame)
    }

    private func draw(_ which: VisualizerPreset, _ ctx: inout GraphicsContext, _ frame: Frame) {
        switch which {
        case .magnetosphere: drawMagnetosphere(&ctx, frame)
        case .ribbons: drawRibbons(&ctx, frame)
        case .warp: drawWarp(&ctx, frame)
        }
    }

    private struct Frame {
        let size: CGSize
        let center: CGPoint
        /// Points per simulation unit: the shorter side spans 2 units.
        let unit: CGFloat
        let aspect: CGFloat

        init(size: CGSize) {
            self.size = size
            center = CGPoint(x: size.width / 2, y: size.height / 2)
            unit = max(1, min(size.width, size.height) / 2)
            aspect = size.width / max(size.height, 1)
        }

        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: center.x + CGFloat(x) * unit, y: center.y + CGFloat(y) * unit)
        }
    }

    private func color(bucket: Int, saturation: Double = 0.85, brightness: Double = 1, opacity: Double = 1) -> Color {
        color(hue: hue + Self.bucketHueOffsets[bucket], saturation: saturation, brightness: brightness, opacity: opacity)
    }

    private func color(hue: Double, saturation: Double = 0.85, brightness: Double = 1, opacity: Double = 1) -> Color {
        Color(hue: hue - floor(hue), saturation: saturation, brightness: brightness).opacity(opacity)
    }

    private func step(_ dt: Double, aspect: CGFloat) {
        var base = isCooking ? 0.6 : 0.2
        musicFrame = music?()
        if let levels = musicFrame, levels.level > 0.005 {
            // Each color bucket follows its own stretch of the spectrum, bass to treble.
            let per = MusicLevels.bandCount / Self.buckets
            for b in 0..<Self.buckets {
                let slice = levels.bands[(b * per)..<min((b + 1) * per, levels.bands.count)]
                bucketLevels[b] = slice.reduce(0, +) / Double(max(slice.count, 1))
            }
        } else {
            musicFrame = nil
            for b in bucketLevels.indices { bucketLevels[b] *= 0.9 }
        }
        if let levels = musicFrame {
            // The music sets the floor; agent steps still kick on top of it.
            base += levels.level * 1.4 + levels.bass * 0.8
            if levels.beats != lastBeatSeen {
                lastBeatSeen = levels.beats
                kick(0.25 + levels.bass * 0.6, hue: hue + .random(in: -0.06...0.06))
            }
        }
        energy += (base - energy) * (1 - exp(-dt * 0.8))
        clock += dt * (0.35 + energy * 0.85)

        // Glide toward the cooking agent's color (cycle if several), or drift when idle.
        let target = palette.isEmpty ? hue + 0.02 : palette[Int(clock / 8) % palette.count]
        var delta = target - hue
        delta -= delta.rounded()
        hue += delta * (1 - exp(-dt * 1.2))

        bursts.removeAll { now - $0.birth > 2.6 }

        if isShowing(.magnetosphere) { stepParticles(dt, aspect: Double(aspect)) }
        if isShowing(.warp) { stepStars(dt) }
    }

    // MARK: Background

    private func drawBackground(_ ctx: inout GraphicsContext, _ f: Frame) {
        let rect = CGRect(origin: .zero, size: f.size)
        ctx.fill(Path(rect), with: .color(.black))
        let radius = max(f.size.width, f.size.height) * 0.75
        ctx.fill(Path(rect), with: .radialGradient(
            Gradient(colors: [color(hue: hue, saturation: 0.9, brightness: 0.18 + 0.08 * min(energy, 2)), .black]),
            center: f.center, startRadius: 0, endRadius: radius
        ))
        // Two slow nebula blobs.
        for i in 0..<2 {
            let t = clock * (0.11 + Double(i) * 0.05) + Double(i) * 2.4
            let c = f.point(sin(t) * Double(f.aspect) * 0.7, cos(t * 1.3) * 0.6)
            let r = f.unit * (0.9 + 0.2 * CGFloat(sin(t * 2)))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .radialGradient(
                Gradient(colors: [color(hue: hue + (i == 0 ? 0.08 : -0.1), saturation: 0.8, brightness: 0.5, opacity: 0.16), .clear]),
                center: c, startRadius: 0, endRadius: r
            ))
        }
    }

    // MARK: Magnetosphere: particles swarming around drifting attractors

    private func attractors() -> [CGPoint] {
        let c = clock
        return [
            CGPoint(x: 0.95 * sin(c * 0.53), y: 0.6 * sin(c * 0.71 + 1)),
            CGPoint(x: 0.8 * sin(c * 0.37 + 2), y: 0.7 * sin(c * 0.61 + 0.5)),
            CGPoint(x: 0.6 * sin(c * 0.83 + 4), y: 0.5 * cos(c * 0.47)),
        ]
    }

    private func stepParticles(_ dt: Double, aspect: Double) {
        let targets = attractors()
        let pull = 0.9 + energy * 1.3
        let damping = pow(0.45, dt)
        for i in particles.indices {
            var particle = particles[i]
            let a = targets[particle.attractor]
            let dx = a.x - particle.p.x
            let dy = a.y - particle.p.y
            let dist = hypot(dx, dy) + 0.06
            // Pull toward the attractor plus a perpendicular swirl, which makes the orbits.
            // With music on, each color swirls as hard as its part of the song.
            let drive = 1 + band(particle.bucket) * 2.6
            let ax = (dx / dist) * pull * drive - (dy / dist) * 0.9 * drive
            let ay = (dy / dist) * pull * drive + (dx / dist) * 0.9 * drive
            particle.v.dx = (particle.v.dx + ax * dt) * damping
            particle.v.dy = (particle.v.dy + ay * dt) * damping
            let speed = hypot(particle.v.dx, particle.v.dy)
            if speed > 3.5 {
                particle.v.dx *= 3.5 / speed
                particle.v.dy *= 3.5 / speed
            }
            particle.p.x += particle.v.dx * dt
            particle.p.y += particle.v.dy * dt
            if Double.random(in: 0...1) < dt * 0.08 { particle.attractor = .random(in: 0..<targets.count) }
            if abs(particle.p.x) > aspect * 1.4 || abs(particle.p.y) > 1.4 {
                particle.p = CGPoint(x: a.x + .random(in: -0.1...0.1), y: a.y + .random(in: -0.1...0.1))
                particle.v = CGVector(dx: .random(in: -0.5...0.5), dy: .random(in: -0.5...0.5))
            }
            particles[i] = particle
        }
    }

    private func drawMagnetosphere(_ ctx: inout GraphicsContext, _ f: Frame) {
        var paths = Array(repeating: Path(), count: Self.buckets)
        let trail = 0.05 + 0.03 * min(energy, 2)
        for particle in particles {
            let head = f.point(particle.p.x, particle.p.y)
            let tail = f.point(particle.p.x - particle.v.dx * trail, particle.p.y - particle.v.dy * trail)
            paths[particle.bucket].move(to: tail)
            paths[particle.bucket].addLine(to: head)
        }
        let glow = 0.25 + 0.12 * min(energy, 2.5)
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 7))
            for (i, path) in paths.enumerated() {
                layer.stroke(path, with: .color(color(bucket: i, opacity: glow)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            }
        }
        for (i, path) in paths.enumerated() {
            ctx.stroke(path, with: .color(color(bucket: i, saturation: 0.55, opacity: 0.6 + 0.4 * max(band(i), musicFrame == nil ? 0.75 : 0))), style: StrokeStyle(lineWidth: 1.6 + 2.2 * band(i), lineCap: .round))
        }
        for (i, a) in attractors().enumerated() {
            let c = f.point(a.x, a.y)
            let r = f.unit * CGFloat(0.12 + 0.05 * min(energy, 2) + 0.22 * band(i))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .radialGradient(
                Gradient(colors: [color(bucket: i + 1, saturation: 0.4, opacity: 0.8), .clear]),
                center: c, startRadius: 0, endRadius: r
            ))
        }
    }

    // MARK: Ribbons: mirrored Lissajous light trails

    private func drawRibbons(_ ctx: inout GraphicsContext, _ f: Frame) {
        let amplitude = 0.65 + 0.22 * min(energy, 2)
        let width = 1.5 + 1.8 * min(energy, 2)
        var glowPaths: [(Path, Color)] = []
        var corePaths: [(Path, Color)] = []
        for ribbon in ribbons {
            let level = band(ribbon.bucket)
            let reach = amplitude * (1 + level * 0.45)
            for echo in 0..<3 {
                var path = Path()
                var mirrored = Path()
                for k in 0..<150 {
                    let s = clock * 0.9 - Double(k) * 0.016 - Double(echo) * 0.07
                    let x = sin(ribbon.a * s + ribbon.phase) * Double(f.aspect) * 0.8 * reach
                    let y = sin(ribbon.b * s) * cos(ribbon.c * s * 0.5 + ribbon.phase) * 0.85 * reach
                    let p = f.point(x, y)
                    let m = f.point(-x, y)
                    if k == 0 {
                        path.move(to: p)
                        mirrored.move(to: m)
                    } else {
                        path.addLine(to: p)
                        mirrored.addLine(to: m)
                    }
                }
                let fade = 1.0 / Double(echo + 1)
                path.addPath(mirrored)
                glowPaths.append((path, color(bucket: ribbon.bucket, opacity: (0.35 + 0.4 * level) * fade)))
                corePaths.append((path, color(bucket: ribbon.bucket, saturation: 0.5, opacity: min(1, 0.85 + 0.3 * level) * fade)))
            }
        }
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 9))
            for (path, c) in glowPaths {
                layer.stroke(path, with: .color(c), style: StrokeStyle(lineWidth: width * 4, lineCap: .round, lineJoin: .round))
            }
        }
        for (path, c) in corePaths {
            ctx.stroke(path, with: .color(c), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
    }

    // MARK: Warp: a starfield that speeds up with the work

    private var warpSpeed: Double { 0.16 + 0.55 * min(energy, 3) }

    private func stepStars(_ dt: Double) {
        let speed = warpSpeed
        for i in stars.indices {
            stars[i].z -= speed * (1 + band(stars[i].bucket) * 1.8) * dt
            if stars[i].z < 0.03 {
                stars[i] = Star(x: .random(in: -1.6...1.6), y: .random(in: -1...1), z: 1, bucket: stars[i].bucket)
            }
        }
    }

    private func drawWarp(_ ctx: inout GraphicsContext, _ f: Frame) {
        var paths = Array(repeating: Path(), count: Self.buckets)
        let streak = 0.04 + warpSpeed * 0.06
        for star in stars {
            let head = f.point(star.x / star.z * 0.5, star.y / star.z * 0.5)
            let z2 = min(1, star.z + streak)
            let tail = f.point(star.x / z2 * 0.5, star.y / z2 * 0.5)
            paths[star.bucket].move(to: tail)
            paths[star.bucket].addLine(to: head)
        }
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 5))
            for (i, path) in paths.enumerated() {
                layer.stroke(path, with: .color(color(bucket: i, opacity: 0.5)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
        }
        for (i, path) in paths.enumerated() {
            ctx.stroke(path, with: .color(color(bucket: i, saturation: 0.35, opacity: 0.95)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        }
        // Tunnel rings rushing outward.
        for k in 0..<6 {
            let phase = (clock * 0.6 + Double(k) / 6).truncatingRemainder(dividingBy: 1)
            let r = f.unit * CGFloat(pow(phase, 2.2) * 2.4)
            let rect = CGRect(x: f.center.x - r * f.aspect * 0.8, y: f.center.y - r, width: 2 * r * f.aspect * 0.8, height: 2 * r)
            ctx.stroke(Path(ellipseIn: rect), with: .color(color(bucket: k % 5, opacity: (0.18 + 0.5 * band(0)) * phase)), lineWidth: 2 + 4 * band(0))
        }
    }

    // MARK: Spectrum: the song itself, as a ring of light around the center

    /// The spectrum mirrored around a circle, bass at the bottom. Sits under the bursts and
    /// over the preset, so the look you picked still leads.
    private func drawSpectrum(_ ctx: inout GraphicsContext, _ f: Frame, _ levels: MusicLevels) {
        let count = levels.bands.count
        let inner = f.unit * CGFloat(0.34 + 0.06 * levels.bass)
        var paths = Array(repeating: Path(), count: Self.buckets)
        for side in [-1.0, 1.0] {
            for i in 0..<count {
                let angle = .pi / 2 + side * (Double(i) + 0.5) / Double(count) * .pi
                let length = f.unit * CGFloat(0.02 + 0.32 * levels.bands[i])
                let dir = CGPoint(x: cos(angle), y: sin(angle))
                let a = CGPoint(x: f.center.x + dir.x * inner, y: f.center.y + dir.y * inner)
                let b = CGPoint(x: f.center.x + dir.x * (inner + length), y: f.center.y + dir.y * (inner + length))
                let bucket = min(Self.buckets - 2, i * (Self.buckets - 1) / count)
                paths[bucket].move(to: a)
                paths[bucket].addLine(to: b)
            }
        }
        let width = max(2, f.unit * 0.012)
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 8))
            for (i, path) in paths.enumerated() {
                layer.stroke(path, with: .color(color(bucket: i, opacity: 0.55)), style: StrokeStyle(lineWidth: width * 2.5, lineCap: .round))
            }
        }
        for (i, path) in paths.enumerated() {
            ctx.stroke(path, with: .color(color(bucket: i, saturation: 0.45, opacity: 0.95)), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
    }

    // MARK: Bursts

    private func drawBursts(_ ctx: inout GraphicsContext, _ f: Frame) {
        for burst in bursts where now >= burst.birth {
            let age = now - burst.birth
            let life = max(0, 1 - age / 2.6)
            let r = f.unit * CGFloat(age * (0.7 + burst.strength * 0.6))
            let c = f.point(burst.center.x, burst.center.y)
            let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
            let tint = color(hue: burst.hue, saturation: 0.7, opacity: life * life * min(1, burst.strength))
            ctx.stroke(Path(ellipseIn: rect), with: .color(tint), lineWidth: CGFloat(2 + burst.strength * 5 * life))
        }
    }
}
