import AVFoundation
import AppKit

/// Synthesises all sounds in-process — no bundled audio files needed.
@MainActor
final class SoundManager {
    static let shared = SoundManager()

    var isMuted: Bool = false {
        didSet { if isMuted { stopAll() } }
    }
    var isRainMuted: Bool = false

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var knockTimer: Timer?
    private let sampleRate: Double = 44100
    private lazy var fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

    private init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
        engine.mainMixerNode.outputVolume = 0.85
        try? engine.start()
    }

    // MARK: Public

    func play(for state: ClaudeState) {
        guard !isMuted else { return }
        stopAll()
        switch state {
        case .running: startRain()
        case .done:    playWhistle()
        case .waiting: startKnock()
        case .idle:    break
        }
    }

    func stopAll() {
        knockTimer?.invalidate()
        knockTimer = nil
        player.stop()
    }

    // MARK: Rain — very quiet ambient hiss (thinking)

    private func startRain() {
        guard !isRainMuted else { return }
        guard let buf = makeBuffer(duration: 2.0, gen: { _, _ in
            Float.random(in: -1...1)
        }) else { return }

        let s = buf.floatChannelData![0]
        var z: Float = 0
        for i in 0..<Int(buf.frameLength) {
            // Light low-pass keeps the natural "hiss" character of rain
            z = 0.18 * s[i] + 0.82 * z
            s[i] = z * 0.10    // very quiet — background ambience only
        }

        ensureRunning()
        player.scheduleBuffer(buf, at: nil, options: .loops)
        player.play()
    }

    // MARK: Whistle — single ascending-then-descending tone (done)

    private func playWhistle() {
        let dur = 0.75
        guard let buf = makeBuffer(duration: dur, gen: { t, _ in
            let phase = t / dur
            let freq  = 600 + 500 * sin(.pi * phase)   // 600 → 1100 → 600 Hz
            let amp   = Float(sin(.pi * phase) * 0.38)  // fade in + fade out
            return amp * Float(sin(2 * .pi * freq * t))
        }) else { return }

        ensureRunning()
        player.scheduleBuffer(buf, at: nil, options: [])
        player.play()
    }

    // MARK: Door knock — classic "knock knock", repeating (waiting)

    private func startKnock() {
        playKnockPattern()
        knockTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.playKnockPattern() }
        }
    }

    private func playKnockPattern() {
        // Three quick knocks — "knock knock knock"
        let patternDur = 0.80
        guard let buf = makeBuffer(duration: patternDur, gen: { t, _ in
            func singleKnock(at offset: Double) -> Float {
                let dt = t - offset
                guard dt >= 0 && dt < 0.22 else { return 0 }

                // Knuckle impact: ultra-brief broadband burst (pure percussive click)
                let knuckle = Float.random(in: -1...1) * Float(exp(-dt / 0.003)) * 0.90

                // Wood body: 65 Hz, fixed frequency (no sweep — avoids "boing"), 65ms decay
                let body = Float(sin(2 * .pi * 65.0 * dt)) * Float(exp(-dt / 0.065)) * 0.70

                // Second partial at 130 Hz: faster decay, adds woody presence without buzziness
                let partial = Float(sin(2 * .pi * 130.0 * dt)) * Float(exp(-dt / 0.018)) * 0.18

                return (knuckle + body + partial) * 0.68
            }
            return singleKnock(at: 0.0) + singleKnock(at: 0.21) + singleKnock(at: 0.42)
        }) else { return }

        ensureRunning()
        player.scheduleBuffer(buf, at: nil, options: [])
        if !player.isPlaying { player.play() }
    }

    // MARK: Helpers

    private func ensureRunning() {
        if !engine.isRunning { try? engine.start() }
    }

    private func makeBuffer(duration: Double,
                            gen: (Double, Int) -> Float) -> AVAudioPCMBuffer? {
        let count = AVAudioFrameCount(sampleRate * duration)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: count) else { return nil }
        buf.frameLength = count
        let ptr = buf.floatChannelData![0]
        for i in 0..<Int(count) {
            ptr[i] = gen(Double(i) / sampleRate, i)
        }
        return buf
    }
}
