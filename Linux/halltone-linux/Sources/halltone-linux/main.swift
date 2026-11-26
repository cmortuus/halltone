import Foundation
import HalltoneLinuxKit
#if canImport(Glibc)
import Glibc
#endif

// Line-buffer stdout so `journalctl --user -u halltone` shows the banner at once.
setvbuf(stdout, nil, _IOLBF, 0)

switch App.start(arguments: Array(CommandLine.arguments.dropFirst())) {
case .failure(let code):
    exit(code.value)
case .success(let runtime):
    // SIGINT/SIGTERM (Ctrl-C, systemctl stop): tell subscribers goodbye, unpublish, exit.
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM] {
        let s = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        s.setEventHandler {
            // Never hang on the way out (systemd would wait 90 s before SIGKILL).
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { exit(0) }
            runtime.stop()
            exit(0)
        }
        s.resume()
        sources.append(s)
    }
    dispatchMain()
}
