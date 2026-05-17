// XenonAudio.swift
// Xenon360 — Xbox 360 Audio Subsystem
//
// Xbox 360 audio pipeline:
//   Game → XAudio2 API → DSP (custom chip) → XMA2 codec → DAC
//
// XMA2 is a Microsoft proprietary codec based on WMA Pro.
// This stub sets up AVAudioEngine and provides HLE XAudio2 hooks.

import Foundation
import AVFoundation

// MARK: - XMA2 Frame Header

struct XMA2FrameHeader {
    let frameLength: Int     // in bits
    let skipBits: Int
    let channelCount: Int
    let sampleRate: Int
}

// MARK: - Audio Voice (HLE)

class XAudioSourceVoice {
    var sampleRate:   Int    = 48000
    var channelCount: Int    = 2
    var isPlaying:    Bool   = false
    var volume:       Float  = 1.0
    var pan:          Float  = 0.0
    var bufferQueue:  [Data] = []

    var playerNode: AVAudioPlayerNode?
    var format: AVAudioFormat?
}

// MARK: - Audio Engine

public class XenonAudio {
    private let engine      = AVAudioEngine()
    private let mixer       = AVAudioMixerNode()
    private var voices: [Int: XAudioSourceVoice] = [:]
    private var nextVoiceID = 0

    public private(set) var isRunning = false

    public init() {
        setupEngine()
    }

    private func setupEngine() {
        engine.attach(mixer)
        engine.connect(mixer, to: engine.mainMixerNode,
                       format: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
    }

    public func start() {
        guard !isRunning else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            isRunning = true
        } catch {
            print("XenonAudio: Failed to start — \(error)")
        }
    }

    public func stop() {
        engine.stop()
        isRunning = false
    }

    // MARK: - HLE XAudio2 API

    /// HLE: XAudioCreateSourceVoice
    public func createSourceVoice(sampleRate: Int, channels: Int) -> Int {
        let voice = XAudioSourceVoice()
        voice.sampleRate   = sampleRate
        voice.channelCount = channels

        let node = AVAudioPlayerNode()
        engine.attach(node)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate),
                                channels: AVAudioChannelCount(channels))
        engine.connect(node, to: mixer, format: fmt)

        voice.playerNode = node
        voice.format     = fmt

        let id = nextVoiceID
        nextVoiceID += 1
        voices[id] = voice
        return id
    }

    /// HLE: IXAudio2SourceVoice::SubmitSourceBuffer
    public func submitBuffer(voiceID: Int, pcmData: Data) {
        guard let voice = voices[voiceID],
              let node  = voice.playerNode,
              let fmt   = voice.format else { return }

        let frameCount = pcmData.count / (voice.channelCount * 2)  // 16-bit
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                         frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buf.frameLength = buf.frameCapacity

        pcmData.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for ch in 0..<voice.channelCount {
                let dst = buf.int16ChannelData![ch]
                for i in 0..<frameCount {
                    dst[i] = src[i * voice.channelCount + ch]
                }
            }
        }

        node.scheduleBuffer(buf, completionHandler: nil)
        if !node.isPlaying { node.play() }
    }

    /// HLE: IXAudio2SourceVoice::SetVolume
    public func setVolume(voiceID: Int, volume: Float) {
        voices[voiceID]?.playerNode?.volume = volume
    }

    /// HLE: IXAudio2SourceVoice::Stop
    public func stopVoice(voiceID: Int) {
        voices[voiceID]?.playerNode?.stop()
    }

    /// HLE: IXAudio2SourceVoice::DestroyVoice
    public func destroyVoice(voiceID: Int) {
        if let voice = voices.removeValue(forKey: voiceID) {
            voice.playerNode?.stop()
            if let node = voice.playerNode {
                engine.detach(node)
            }
        }
    }

    // MARK: - XMA2 Decoder (stub)
    // Real XMA2 decoding requires the proprietary codec.
    // Open-source approximation: ffmpeg's wmapro decoder.

    public func decodeXMA2Frame(_ data: Data) -> Data? {
        // TODO: implement XMA2 → PCM16 decoder
        // For now return silence
        let frameSize = 512 * 2 * 2  // 512 samples, stereo, 16-bit
        return Data(count: frameSize)
    }
}
