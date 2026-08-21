import AVFoundation
import Foundation
import ScreenCaptureKit

/// OS-level audio dubbing capture (bowser-browser-gj9): the browser plays
/// the video; we capture its own audio OUTPUT with ScreenCaptureKit and ship
/// 6-second 16kHz-mono WAV chunks to the brain. This defeats every stream
/// protection (SABR/nsig/DRM) because we never touch the stream — we hear
/// what the user hears. Translated speech is played back through this same
/// process (AVAudioPlayer) and excluded from capture, so it never loops.
///
/// Not an actor: SCStream/SCContentFilter aren't Sendable, so this class
/// confines all of ScreenCaptureKit to itself and only hops to the main
/// actor to emit finished WAV chunks.
@available(macOS 13.0, *)
final class AudioDub: NSObject, SCStreamOutput, @unchecked Sendable {
    @MainActor static let shared = AudioDub()

    private var stream: SCStream?
    private var accum: [Int16] = []
    private var seq = 0
    private let sampleQueue = DispatchQueue(label: "bowser.audiodub.samples")
    @MainActor private lazy var player = AudioDubPlayer()

    // 16kHz mono, 6-second chunks. Whisper's floor is ~0.1s; 6s balances
    // latency against per-request overhead.
    nonisolated static let outRate = 16_000
    private static let chunkSamples = outRate * 6

    var isCapturing: Bool { sampleQueue.sync { stream != nil } }

    func start() {
        sampleQueue.async { [weak self] in
            guard let self, self.stream == nil else { return }
            Task { [weak self] in
                do {
                    try await self?.beginCapture()
                } catch {
                    NSLog("Bowser: dub capture failed — \(error.localizedDescription)")
                    await MainActor.run {
                        BrainBridge.shared.send([
                            "op": "event", "event": "dub_capture_error",
                            "message": error.localizedDescription,
                        ])
                    }
                }
            }
        }
    }

    func stop() {
        sampleQueue.async { [weak self] in
            guard let self, let s = self.stream else { return }
            self.stream = nil
            self.accum = []
            Task { try? await s.stopCapture() }
        }
    }

    /// Play one translated mp3 segment (base64). Ordered queue on main.
    func play(base64 mp3: String) {
        guard let data = Data(base64Encoded: mp3) else { return }
        Task { @MainActor in player.enqueue(data) }
    }

    private func beginCapture() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            NSLog("Bowser: dub capture — no display")
            return
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        // Our TTS plays in THIS process (AudioDubPlayer) — excluding it is
        // what stops the dub from being re-captured and re-translated.
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // Minimal video: SCStream requires a display filter, but we only
        // want audio — keep the frame tiny and slow.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let s = SCStream(filter: filter, configuration: config, delegate: nil)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await s.startCapture()
        stream = s
        NSLog("Bowser: dub capture started")
    }

    // MARK: SCStreamOutput (runs on sampleQueue)

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType
    ) {
        guard type == .audio, self.stream != nil,
              let samples = AudioDub.monoDownsampled(sampleBuffer)
        else { return }
        accum.append(contentsOf: samples)
        while accum.count >= Self.chunkSamples {
            let chunk = Array(accum.prefix(Self.chunkSamples))
            accum.removeFirst(Self.chunkSamples)
            let wav = AudioDub.wav(chunk, rate: Self.outRate)
            let mySeq = seq
            seq += 1
            Task { @MainActor in
                BrainBridge.shared.send([
                    "op": "event", "event": "dub_audio_chunk", "seq": mySeq,
                    "data": wav.base64EncodedString(),
                ])
            }
        }
    }

    // MARK: - Pure DSP (testable)

    /// 48kHz stereo Float32 sample buffer → 16kHz mono Int16 (average the
    /// channels, decimate by 3). Nil if the buffer isn't the expected shape.
    static func monoDownsampled(_ sampleBuffer: CMSampleBuffer) -> [Int16]? {
        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = formatDesc.audioStreamBasicDescription
        else { return nil }

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let buffer = audioBufferList.mBuffers.mData else { return nil }

        let channels = Int(asbd.mChannelsPerFrame)
        let frames = Int(audioBufferList.mBuffers.mDataByteSize) / (MemoryLayout<Float32>.size * max(channels, 1))
        let floats = buffer.assumingMemoryBound(to: Float32.self)
        let decim = max(1, Int(asbd.mSampleRate.rounded()) / outRate)
        return downmix(floats, frames: frames, channels: channels, decimate: decim)
    }

    /// Interleaved Float32 → mono Int16 with decimation. Pure over a raw
    /// pointer so tests can drive it with a synthetic buffer.
    static func downmix(
        _ floats: UnsafePointer<Float32>, frames: Int, channels: Int, decimate: Int
    ) -> [Int16] {
        guard channels > 0, decimate > 0 else { return [] }
        var out: [Int16] = []
        out.reserveCapacity(frames / decimate + 1)
        var frame = 0
        while frame < frames {
            var mixed: Float32 = 0
            for c in 0..<channels { mixed += floats[frame * channels + c] }
            mixed /= Float32(channels)
            let clamped = max(-1, min(1, mixed))
            out.append(Int16(clamped * 32767))
            frame += decimate
        }
        return out
    }

    /// Wrap Int16 PCM samples in a 44-byte canonical WAV header.
    static func wav(_ samples: [Int16], rate: Int) -> Data {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample
        var d = Data(capacity: 44 + dataSize)
        func str(_ s: String) { d.append(contentsOf: s.utf8) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }

        str("RIFF"); u32(UInt32(36 + dataSize)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(1)                       // PCM, mono
        u32(UInt32(rate)); u32(UInt32(rate * bytesPerSample))      // byte rate
        u16(UInt16(bytesPerSample)); u16(16)                       // block align, bits
        str("data"); u32(UInt32(dataSize))
        for s in samples { u16(UInt16(bitPattern: s)) }
        return d
    }
}

/// Ordered mp3 playback in this process, so ScreenCaptureKit's
/// excludesCurrentProcessAudio keeps the dub out of the capture.
@available(macOS 13.0, *)
@MainActor
final class AudioDubPlayer: NSObject, AVAudioPlayerDelegate {
    private var queue: [Data] = []
    private var current: AVAudioPlayer?

    func enqueue(_ mp3: Data) {
        queue.append(mp3)
        if current == nil { playNext() }
    }

    private func playNext() {
        guard !queue.isEmpty else { current = nil; return }
        let data = queue.removeFirst()
        do {
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            p.play()
            current = p
        } catch {
            playNext()
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playNext() }
    }
}
