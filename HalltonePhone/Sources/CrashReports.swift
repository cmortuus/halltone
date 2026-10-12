import Foundation
import MetricKit

/// Writes crash reports into the diagnostics log. After a crash iOS hands MetricKit the report
/// (exception, signal, stack trace) on a later launch; it goes into halltone.log, which the user
/// can send from About → Share diagnostics log. Nothing leaves the phone on its own.
final class CrashReports: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReports()

    func start() {
        MXMetricManager.shared.add(self)
        // Reports that arrived while the app wasn't subscribed yet.
        didReceive(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                let meta = crash.metaData
                var summary = "CRASH (\(meta.applicationBuildVersion), \(meta.osVersion))"
                if let type = crash.exceptionType { summary += " exception \(type)" }
                if let code = crash.exceptionCode { summary += " code \(code)" }
                if let signal = crash.signal { summary += " signal \(signal)" }
                if let reason = crash.terminationReason { summary += " — \(reason)" }
                summary += " between \(payload.timeStampBegin) and \(payload.timeStampEnd)"
                diag(summary)
                let stack = String(decoding: crash.callStackTree.jsonRepresentation(), as: UTF8.self)
                diag("CRASH stack: \(stack)")
            }
            for hang in payload.hangDiagnostics ?? [] {
                diag("HANG for \(hang.hangDuration) (\(hang.metaData.applicationBuildVersion))")
            }
        }
    }
}
