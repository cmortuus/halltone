import Testing
import Foundation
@testable import HalltoneLinuxKit

/// The helper itself: streaming spawns (parec, avahi-publish-service) must not leak either.
@Suite(.serialized, .timeLimit(.minutes(2))) struct SpawnFDTests {
    @Test func streamingSpawnsCloseTheirReadEnds() throws {
        guard openFDs() != nil else { return }
        _ = try Spawn.start("/bin/echo", ["warm"], captureStdout: true, captureStderr: true).stdout.map { Spawn.drain($0) }
        let before = try #require(settledFDs())
        for _ in 0..<200 {
            let s = try Spawn.start("/bin/sh", ["-c", "echo out; echo err 1>&2"], captureStdout: true, captureStderr: true)
            let out = Spawn.drain(try #require(s.stdout)), err = Spawn.drain(try #require(s.stderr))
            #expect(String(decoding: out, as: UTF8.self) == "out\n" && String(decoding: err, as: UTF8.self) == "err\n")
        }
        for _ in 0..<50 {   // a long-lived child that is stopped, as AppStreamCapture does
            let s = try Spawn.start("/bin/sleep", ["30"], captureStdout: true, captureStderr: false)
            s.process.terminate()
            _ = Spawn.drain(try #require(s.stdout))
        }
        for _ in 0..<50 { #expect((try? Spawn.start("/nonexistent/program", [], captureStdout: true, captureStderr: true)) == nil) }
        let after = try #require(settledFDs())
        #expect(after - before <= 25, "fd count grew from \(before) to \(after)")
    }
}
