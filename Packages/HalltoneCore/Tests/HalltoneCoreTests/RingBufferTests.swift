import Testing
@testable import HalltoneCore

@Suite struct RingBufferTests {
    @Test func roundTripAndWrap() {
        let ring = RingBuffer(capacity: 16)
        #expect(ring.capacity == 16)
        var src: [Float] = (0..<10).map(Float.init)
        #expect(src.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 10) } == 10)
        var dst = [Float](repeating: 0, count: 10)
        #expect(dst.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 6) } == 6)
        #expect(Array(dst[0..<6]) == [0, 1, 2, 3, 4, 5])
        src = (100..<110).map(Float.init)
        #expect(src.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 10) } == 10)
        #expect(ring.availableToRead == 14)
        var out = [Float](repeating: 0, count: 14)
        #expect(out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 14) } == 14)
        #expect(out == [6, 7, 8, 9] + (100..<110).map(Float.init))
    }

    @Test func fullAndEmpty() {
        let ring = RingBuffer(capacity: 4)
        let src: [Float] = [1, 2, 3, 4, 5]
        #expect(src.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 5) } == 4)
        #expect(ring.availableToWrite == 0)
        var dst = [Float](repeating: 0, count: 8)
        #expect(dst.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 8) } == 4)
        #expect(dst.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 8) } == 0)
    }
}
