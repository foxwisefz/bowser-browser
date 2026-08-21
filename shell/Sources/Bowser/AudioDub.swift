import AVFoundation
import CoreGraphics
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
    private let screenQueue = DispatchQueue(label: "bowser.audiodub.screen")
    @MainActor private lazy var player = AudioDubPlayer()

    // 16kHz mono, 6-second chunks. Whisper's floor is ~0.1s; 6s balances
    // latency against per-request overhead.
    nonisolated static let outRate = 16_000
    private static let chunkSamples = outRate * 6

    var isCapturing: Bool { sampleQueue.sync { stream != nil } }

    private func report(_ msg: String) {
        Task { @MainActor in
            BrainBridge.shared.send(["op": "event", "event": "dub_capture_status", "message": msg])
        }
    }

    func start() {
        // Explicit permission first: CGRequestScreenCaptureAccess reliably
        // raises the macOS prompt and registers this binary in the Screen
        // Recording list — SCShareableContent's implicit prompt does not
        // fire for a terminal-launched, unbundled binary (bowser-browser-gj9).
        let granted = CGPreflightScreenCaptureAccess()
        report("screen-recording permission: \(granted ? "granted" : "NOT granted — requesting…")")
        if !granted {
            let now = CGRequestScreenCaptureAccess()
            report(now
                ? "permission just granted — press :dub again"
                : "permission DENIED — enable Bowser (or iTerm) in System Settings › Privacy › Screen Recording, then restart")
            if !now { return }
        }

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
        config.sampleRate = 48_000
        config.channelCount = 2
        // A real (small) frame: a 2x2 stream silently never delivers audio.
        config.width = 128
        config.height = 72
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)

        // Dump every capturable app so we can find where the video audio
        // lives (WebKit renders it in a helper process). Show non-Apple + any
        // WebKit/media apps to keep it short.
        let apps = content.applications
        let interesting = apps
            .map { "\($0.bundleIdentifier.isEmpty ? "<pid \($0.processID)>" : $0.bundleIdentifier)" }
            .filter { id in
                let l = id.lowercased()
                return l.contains("webkit") || l.contains("media") || l.contains("gpu")
                    || l.contains("pid") || !id.hasPrefix("com.apple.")
            }
        report("apps: " + interesting.prefix(12).joined(separator: " "))

        // Capture the whole display's audio (all apps): the video plays
        // SOMEWHERE in the process tree and this is guaranteed to include it.
        // Feedback from our own TTS is muzzled brain-side.
        let filter = SCContentFilter(display: display, excludingWindows: [])
        report("capturing full display audio")
        let s = SCStream(filter: filter, configuration: config, delegate: nil)
        // A screen output is added alongside audio: some macOS versions
        // won't start delivering audio on an audio-only stream.
        try s.addStreamOutput(ScreenSink.shared, type: .screen, sampleHandlerQueue: screenQueue)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await s.startCapture()
        stream = s
        report("capture started — waiting for the first 6s chunk")
        NSLog("Bowser: dub capture started")
    }

    // MARK: SCStreamOutput (runs on sampleQueue)

    private var cbCount = 0
    private var reportedFormat = false

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        cbCount += 1
        if !reportedFormat {
            reportedFormat = true
            if let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription {
                report("audio cb firing: \(Int(asbd.mSampleRate))Hz \(asbd.mChannelsPerFrame)ch flags=\(asbd.mFormatFlags) bits=\(asbd.mBitsPerChannel)")
            } else {
                report("audio cb firing but NO format description")
            }
        }
        guard self.stream != nil,
              let samples = AudioDub.monoDownsampled(sampleBuffer)
        else {
            if cbCount <= 3 { report("cb \(cbCount): monoDownsampled returned nil") }
            return
        }
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

    /// 48kHz Float32 sample buffer → 16kHz mono Int16. Handles both
    /// interleaved and NON-INTERLEAVED (planar) layouts — SCStream delivers
    /// planar (flags include kAudioFormatFlagIsNonInterleaved), which needs
    /// an AudioBufferList sized for every channel (the old single-buffer
    /// list silently failed — bowser-browser-gj9).
    static func monoDownsampled(_ sampleBuffer: CMSampleBuffer) -> [Int16]? {
        guard let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return nil }
        let channels = Int(asbd.mChannelsPerFrame)
        guard channels > 0 else { return nil }
        let decim = max(1, Int(asbd.mSampleRate.rounded()) / outRate)

        var blockBuffer: CMBlockBuffer?
        let ablSize = MemoryLayout<AudioBufferList>.size
            + (channels - 1) * MemoryLayout<AudioBuffer>.size
        let ablRaw = UnsafeMutableRawPointer.allocate(
            byteCount: ablSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ablRaw.deallocate() }
        let abl = ablRaw.assumingMemoryBound(to: AudioBufferList.self)

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: abl,
            bufferListSize: ablSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        let nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        if nonInterleaved {
            // One buffer per channel; each holds `frames` Float32.
            let channelPtrs: [UnsafePointer<Float32>] = buffers.compactMap {
                $0.mData.map { UnsafePointer($0.assumingMemoryBound(to: Float32.self)) }
            }
            guard !channelPtrs.isEmpty else { return nil }
            let frames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float32>.size
            return downmixPlanar(channelPtrs, frames: frames, decimate: decim)
        } else {
            guard let data = buffers[0].mData else { return nil }
            let floats = data.assumingMemoryBound(to: Float32.self)
            let frames = Int(buffers[0].mDataByteSize) / (MemoryLayout<Float32>.size * channels)
            return downmix(floats, frames: frames, channels: channels, decimate: decim)
        }
    }

    /// Planar Float32 (one pointer per channel) → mono Int16 with decimation.
    static func downmixPlanar(
        _ channels: [UnsafePointer<Float32>], frames: Int, decimate: Int
    ) -> [Int16] {
        guard !channels.isEmpty, decimate > 0 else { return [] }
        let n = Float32(channels.count)
        var out: [Int16] = []
        out.reserveCapacity(frames / decimate + 1)
        var frame = 0
        while frame < frames {
            var mixed: Float32 = 0
            for ch in channels { mixed += ch[frame] }
            mixed /= n
            out.append(Int16(max(-1, min(1, mixed)) * 32767))
            frame += decimate
        }
        return out
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

/// Drops screen frames — present only so SCStream reliably starts its audio
/// delivery (audio-only streams don't on some macOS versions).
@available(macOS 13.0, *)
final class ScreenSink: NSObject, SCStreamOutput, @unchecked Sendable {
    static let shared = ScreenSink()
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
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
