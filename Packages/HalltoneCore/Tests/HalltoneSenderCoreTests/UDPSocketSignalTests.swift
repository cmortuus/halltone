import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import HalltoneSenderCore

/// A signal landing on the receive thread must not end it. With SO_RCVTIMEO set, recvmsg returns
/// EINTR after any handled signal (signal(7): never restarted), and `receive` used to report that
/// as an error, so SenderCore's receive loop exited and the sender went deaf to phones.
@Suite(.serialized, .timeLimit(.minutes(1))) struct UDPSocketSignalTests {
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var thread: pthread_t?
        var errors = 0, interrupted = 0, got: [UInt8] = [], stop = false
    }

    static func loopback(port: UInt16) -> sockaddr_storage {
        var a = sockaddr_in6()
        #if canImport(Darwin)
        a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        #endif
        a.sin6_family = sa_family_t(AF_INET6)
        a.sin6_port = port.bigEndian
        a.sin6_addr = in6addr_loopback
        var s = sockaddr_storage()
        withUnsafeBytes(of: &a) { src in withUnsafeMutableBytes(of: &s) { $0.copyMemory(from: src) } }
        return s
    }

    @Test func receiveSurvivesSignalsAndStillGetsThePacket() throws {
        var bound: (UDPSocket, UInt16)?
        for _ in 0..<20 where bound == nil {
            let port = UInt16.random(in: 40000...60000)
            if let s = try? UDPSocket(port: port) { bound = (s, port) }
        }
        let (sock, port) = try #require(bound)
        signal(SIGUSR2) { _ in }   // a handled, otherwise harmless signal
        let st = State()
        let ready = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let t = Thread {
            st.lock.lock(); st.thread = pthread_self(); st.lock.unlock()
            ready.signal()
            let buf = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 16)
            defer { buf.deallocate(); done.signal() }
            var from = sockaddr_storage()
            while true {
                st.lock.lock(); let stop = st.stop; st.lock.unlock()
                if stop { return }
                let n = sock.receive(into: buf, capacity: 64, from: &from)
                st.lock.lock()
                if n < 0 { st.errors += 1; if errno == EINTR { st.interrupted += 1 } }
                if n > 0 { st.got = Array(UnsafeRawBufferPointer(start: buf, count: n)); st.stop = true }
                st.lock.unlock()
            }
        }
        t.start()
        #expect(ready.wait(timeout: .now() + 5) == .success)
        st.lock.lock(); let target = try #require(st.thread); st.lock.unlock()
        for _ in 0..<100 { pthread_kill(target, SIGUSR2); usleep(5_000) }   // while it blocks in recvmsg
        let client = try #require(try? UDPSocket(port: 0))
        let marker: [UInt8] = [0x48, 0x54]
        _ = marker.withUnsafeBytes { client.send($0.baseAddress!, $0.count, to: Self.loopback(port: port)) }
        let finished = done.wait(timeout: .now() + 5) == .success
        if !finished { st.lock.lock(); st.stop = true; st.lock.unlock(); _ = done.wait(timeout: .now() + 2) }
        st.lock.lock(); defer { st.lock.unlock() }
        #expect(st.errors == 0, "receive reported \(st.errors) errors (\(st.interrupted) EINTR) for signals")
        #expect(st.got == marker, "packet sent after the signals was not received")
    }
}
