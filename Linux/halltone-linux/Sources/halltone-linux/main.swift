import Foundation
import HalltoneLinuxKit
#if canImport(Glibc)
import Glibc
#endif

// Line-buffer stdout so `journalctl --user -u halltone` shows the banner at once.
setvbuf(stdout, nil, _IOLBF, 0)

/// The running sender, once started. Signals can arrive before it exists (right after launch).
final class RuntimeBox {
    private let lock = NSLock()
    private var runtime: LinuxRuntime?
    func set(_ r: LinuxRuntime) { lock.lock(); runtime = r; lock.unlock() }
    func take() -> LinuxRuntime? { lock.lock(); defer { lock.unlock() }; let r = runtime; runtime = nil; return r }
}
let box = RuntimeBox()

// SIGINT/SIGTERM (Ctrl-C, systemctl stop): tell subscribers goodbye, unpublish, exit. Installed
// before anything else, so a signal during startup can't be lost to SIG_IGN.
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    s.setEventHandler {
        // Never hang on the way out (systemd would wait 90 s before SIGKILL).
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { exit(0) }
        box.take()?.stop()
        exit(0)
    }
    s.resume()
    signalSources.append(s)
}

switch App.start(arguments: Array(CommandLine.arguments.dropFirst())) {
case .failure(let code):
    exit(code.value)
case .success(let runtime):
    box.set(runtime)
    dispatchMain()
}
