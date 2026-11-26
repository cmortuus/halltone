#if os(macOS)
import Foundation
import AVFoundation
import HalltoneCore
import HalltoneSenderCore

/// Converts a tap's native format (usually 44.1 kHz or 96 kHz interleaved Float32) to the 48 kHz
/// stereo the wire carries.
final class AVAudioConverterResampler: AudioResampler {
    private let converter: AVAudioConverter
    private let inBuf: AVAudioPCMBuffer
    private let outBuf: AVAudioPCMBuffer

    init?(from native: AVAudioFormat) {
        guard let fmt48 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Constants.sampleRate,
                                        channels: 2, interleaved: true),
              let converter = AVAudioConverter(from: native, to: fmt48),
              let inBuf = AVAudioPCMBuffer(pcmFormat: native, frameCapacity: 1024),
              let outBuf = AVAudioPCMBuffer(pcmFormat: fmt48, frameCapacity: 2048) else { return nil }
        self.converter = converter
        self.inBuf = inBuf
        self.outBuf = outBuf
    }

    func process(from input: RingBuffer, into output: RingBuffer) {
        let ch = Constants.channels
        let avail = input.availableToRead / ch
        guard avail >= 256 else { return }
        let n = min(avail, 1024)
        let got = inBuf.floatChannelData!.pointee.withMemoryRebound(to: Float.self, capacity: n * ch) {
            input.read(into: $0, count: n * ch)
        }
        inBuf.frameLength = AVAudioFrameCount(got / ch)
        var fed = false
        var err: NSError?
        outBuf.frameLength = 0
        let status = converter.convert(to: outBuf, error: &err) { [inBuf] _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true; outStatus.pointee = .haveData; return inBuf
        }
        if status != .error, outBuf.frameLength > 0 {
            output.write(outBuf.floatChannelData!.pointee, count: Int(outBuf.frameLength) * ch)
        }
    }
}
#endif
