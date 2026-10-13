import CallKit

/// Reports whether a phone or FaceTime call is in progress on this iPhone (CallKit's observer;
/// no permission needed). Halltone stays silent during calls: iOS's interruption messages
/// alone aren't enough, because it says "resume" several times mid-call.
final class CallWatcher: NSObject, CXCallObserverDelegate {
    private let observer = CXCallObserver()
    var onChange: ((Bool) -> Void)?
    private(set) var inCall = false

    override init() {
        super.init()
        observer.setDelegate(self, queue: .main)
        inCall = observer.calls.contains { !$0.hasEnded }
    }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        let now = callObserver.calls.contains { !$0.hasEnded }
        guard now != inCall else { return }
        inCall = now
        onChange?(now)
    }
}
