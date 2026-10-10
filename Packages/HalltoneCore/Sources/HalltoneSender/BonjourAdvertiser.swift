#if os(macOS)
import Foundation
import dnssd
import os
import HalltoneCore

private let log = Logger(subsystem: Constants.logSubsystem, category: "Bonjour")

/// Registers `_halltone._udp` with a TXT record via the dnssd C API (the UDP socket is ours,
/// so NWListener's built-in advertising can't be used).
final class BonjourAdvertiser {
    private var ref: DNSServiceRef?
    private var txt = TXTRecordRef()
    private let queue: DispatchQueue

    init(name: String, port: UInt16, txtValues: [String: String], queue: DispatchQueue) {
        self.queue = queue
        TXTRecordCreate(&txt, 0, nil)
        for (k, v) in txtValues {
            let bytes = Array(v.utf8)
            bytes.withUnsafeBufferPointer { TXTRecordSetValue(&txt, k, UInt8(min(bytes.count, 255)), $0.baseAddress) }
        }
        let err = DNSServiceRegister(&ref, 0, 0, name, Constants.serviceType, nil, nil, port.bigEndian,
                                     TXTRecordGetLength(&txt), TXTRecordGetBytesPtr(&txt), nil, nil)
        if err == kDNSServiceErr_NoError, let ref {
            DNSServiceSetDispatchQueue(ref, queue)
            log.info("advertising \(name, privacy: .public) on \(port)")
        } else {
            log.error("DNSServiceRegister failed: \(err)")
        }
    }

    deinit {
        if let ref { DNSServiceRefDeallocate(ref) }
        TXTRecordDeallocate(&txt)
    }
}
#endif
