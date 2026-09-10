import AVFoundation

/// The soft click when the desktop clears.
///
/// Synthesised rather than shipped as an audio file: it is two decaying
/// sines and a scrap of noise, which is cheaper to write than to store.
final class Click {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?
    private var isPrepared = false

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        buffer = Self.render(format: format)
    }

    private static func render(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let duration = 0.055
        let frames = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames

        guard let channels = buffer.floatChannelData else { return nil }
        for frame in 0..<Int(frames) {
            let t = Double(frame) / sampleRate
            // Tick: high, very short.
            let tick = sin(2 * .pi * 2_050 * t) * exp(-t * 190)
            // Body: the low knock of a hinge seating.
            let body = sin(2 * .pi * 205 * t) * exp(-t * 62)
            // A little air on the attack.
            let air = (Double.random(in: -1...1)) * exp(-t * 620) * 0.5
            let sample = Float((tick * 0.30 + body * 0.55 + air * 0.15) * 0.22)
            for channel in 0..<Int(format.channelCount) {
                channels[channel][frame] = sample
            }
        }
        return buffer
    }

    func play() {
        guard let buffer else { return }
        do {
            if !isPrepared {
                try engine.start()
                player.play()
                isPrepared = true
            }
            player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        } catch {
            Log.warn("click: \(error.localizedDescription)")
        }
    }
}
