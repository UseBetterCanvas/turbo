import Accelerate
import AppKit
import CoreMedia
import ScreenCaptureKit

/// How loud the music is right now, and whether a beat just landed.
struct MusicLevels: Equatable {
    static let bandCount = 48

    var level: Double = 0
    var bass: Double = 0
    /// The spectrum, low to high, on a log scale like the ear hears it. Each 0...1.
    var bands = [Double](repeating: 0, count: MusicLevels.bandCount)
    /// Counts up on every beat, so a reader can tell a new one from the last.
    var beats = 0
}

/// Listens to what your Mac is playing (Spotify first, if it's open) so the visualizer can move
/// with it. Audio is tapped before it reaches the output, so speakers and AirPods both work.
/// Uses ScreenCaptureKit with a tiny, ignored video stream: macOS asks for Screen Recording
/// permission once, but only the sound is read, and nothing is saved.
final class MusicListener: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum State: Equatable {
        case off
        case starting
        /// Listening to one app ("Spotify") or everything (nil).
        case listening(app: String?)
        case needsPermission
        case failed(String)
    }

    static let preferredApps = ["com.spotify.client", "com.apple.Music"]

    /// Called on the main actor whenever the state changes.
    var onState: (@MainActor (State) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "turbo.music")
    private let lock = NSLock()
    private var levels = MusicLevels()
    private var average: Float = 0
    private var lastBeat = Date.distantPast
    private var lowPass: Float = 0
    /// FFT state, used only on the audio queue.
    private let fftSize = 1024
    private lazy var fftSetup = vDSP_create_fftsetup(vDSP_Length(log2(Float(fftSize))), FFTRadix(kFFTRadix2))
    private lazy var window: [Float] = {
        var w = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&w, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        return w
    }()
    private var ring = [Float]()
    private var bandPeak: Float = 1e-3
    /// Which FFT bins feed each band: log-spaced from about 40 Hz to 16 kHz at 48 kHz.
    private lazy var bandEdges: [Int] = {
        let bins = fftSize / 2
        let lo = log(40.0 / 48_000 * Double(fftSize)), hi = log(16_000.0 / 48_000 * Double(fftSize))
        return (0...MusicLevels.bandCount).map { i in
            min(bins - 1, max(1, Int(exp(lo + (hi - lo) * Double(i) / Double(MusicLevels.bandCount)).rounded())))
        }
    }()

    /// The latest levels. Safe from any thread (the visualizer reads it every frame).
    func snapshot() -> MusicLevels {
        lock.lock(); defer { lock.unlock() }
        return levels
    }

    func start() {
        guard stream == nil else { return }
        publish(.starting)
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else { throw ListenError.noDisplay }
                let app = Self.preferredApps.lazy.compactMap { id in content.applications.first { $0.bundleIdentifier == id } }.first
                let filter = app.map { SCContentFilter(display: display, including: [$0], exceptingWindows: []) }
                    ?? SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48_000
                config.channelCount = 1
                // Video can't be turned off, so ask for as little as possible.
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
                try await stream.startCapture()
                self.stream = stream
                publish(.listening(app: app?.applicationName))
            } catch {
                let denied = (error as NSError).code == -3801   // SCStreamError.userDeclined
                publish(denied ? .needsPermission : .failed(error.localizedDescription))
            }
        }
    }

    func stop() {
        let stream = self.stream
        self.stream = nil
        Task { try? await stream?.stopCapture() }
        lock.lock(); levels = MusicLevels(); lock.unlock()
        publish(.off)
    }

    private func publish(_ state: State) {
        guard let onState else { return }
        Task { @MainActor in onState(state) }
    }

    enum ListenError: LocalizedError {
        case noDisplay
        var errorDescription: String? { "No display to listen through." }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        try? sampleBuffer.withAudioBufferList { buffers, _ in
            guard let buffer = buffers.first, let data = buffer.mData else { return }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard count > 0 else { return }
            let samples = data.bindMemory(to: Float.self, capacity: count)
            analyze(UnsafeBufferPointer(start: samples, count: count))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        publish(.failed(error.localizedDescription))
    }

    /// Loudness (RMS), a rough bass level (a one-pole low-pass), and a beat when the bass jumps
    /// well above its recent average.
    private func analyze(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress else { return }
        var rms: Float = 0
        vDSP_rmsqv(base, 1, &rms, vDSP_Length(samples.count))
        var bassEnergy: Float = 0
        var y = lowPass
        for s in samples {
            y += 0.02 * (s - y)
            bassEnergy += y * y
        }
        lowPass = y
        let bass = sqrt(bassEnergy / Float(samples.count))
        average = average * 0.96 + bass * 0.04
        let now = Date()
        let isBeat = bass > max(average * 1.45, 0.01) && now.timeIntervalSince(lastBeat) > 0.22
        if isBeat { lastBeat = now }
        let spectrum = spectrumBands(samples)

        lock.lock()
        // Ease toward the new reading so the picture doesn't jitter.
        levels.level += (Double(min(rms * 4, 1)) - levels.level) * 0.5
        levels.bass += (Double(min(bass * 6, 1)) - levels.bass) * 0.5
        if isBeat { levels.beats &+= 1 }
        if let spectrum {
            // Rise fast, fall slowly, like a real level meter.
            for i in 0..<MusicLevels.bandCount {
                let target = spectrum[i]
                let current = levels.bands[i]
                levels.bands[i] = target > current ? current + (target - current) * 0.6 : current * 0.86 + target * 0.14
            }
        }
        lock.unlock()
    }

    /// Windowed FFT of the newest 1,024 samples, folded into log-spaced bands and normalized
    /// against a slowly falling peak so quiet and loud songs both fill the picture.
    private func spectrumBands(_ samples: UnsafeBufferPointer<Float>) -> [Double]? {
        ring.append(contentsOf: samples)
        if ring.count > fftSize { ring.removeFirst(ring.count - fftSize) }
        guard ring.count == fftSize, let setup = fftSetup else { return nil }

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(ring, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
        let half = fftSize / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2(Float(fftSize))), FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        var bands = [Float](repeating: 0, count: MusicLevels.bandCount)
        for i in 0..<MusicLevels.bandCount {
            let start = bandEdges[i], end = max(bandEdges[i + 1], start + 1)
            var sum: Float = 0
            for bin in start..<min(end, half) { sum += magnitudes[bin] }
            // Higher bands hold less energy; tilt them up so the whole range moves.
            bands[i] = sum / Float(end - start) * (1 + Float(i) / Float(MusicLevels.bandCount) * 3)
        }
        let loudest = bands.max() ?? 0
        bandPeak = max(loudest, bandPeak * 0.995, 1e-3)
        return bands.map { Double(sqrt(min($0 / bandPeak, 1))) }
    }
}
