import Foundation
import HalltoneLinuxKit

/// A scripted MPRIS bus: players with a status, and Pause/Play that change it (optionally not at
/// all, to model a player that ignores Pause).
final class FakeMPRIS: MPRISBackend {
    private let lock = NSLock()
    private var list: [MPRISPlayer] = []
    var failListing = false
    /// Pause/Play calls that succeed but change nothing.
    var ignoresPause = false
    private(set) var sent: [(MPRISCommand, String)] = []

    var all: [MPRISPlayer] {
        get { lock.lock(); defer { lock.unlock() }; return list }
        set { lock.lock(); list = newValue; lock.unlock() }
    }
    var commands: [String] { lock.lock(); defer { lock.unlock() }; return sent.map { "\($0.0.rawValue) \($0.1)" } }

    func add(_ name: String, _ status: MPRISStatus, identity: String = "", track: String = "/t/1", title: String = "Song") {
        all.append(MPRISPlayer(bus: MPRISNames.prefix + name, identity: identity, status: status, trackID: track, title: title))
    }
    func set(_ name: String, _ status: MPRISStatus? = nil, track: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        for i in list.indices where list[i].bus == MPRISNames.prefix + name {
            if let status { list[i].status = status }
            if let track { list[i].trackID = track }
        }
    }
    func status(_ name: String) -> MPRISStatus? { all.first { $0.bus == MPRISNames.prefix + name }?.status }

    func players() throws -> [MPRISPlayer] {
        if failListing { throw BusctlBackend.BusError(description: "no bus") }
        return all
    }
    func send(_ command: MPRISCommand, to bus: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        sent.append((command, bus))
        guard let i = list.firstIndex(where: { $0.bus == bus }) else { return false }
        if !ignoresPause {
            if command == .pause { list[i].status = .paused }
            if command == .play { list[i].status = .playing }
        }
        return true
    }
}
