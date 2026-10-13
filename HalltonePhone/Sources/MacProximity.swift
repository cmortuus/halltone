import Foundation
import CoreBluetooth
import os
import HalltoneCore

private let log = Logger(subsystem: Constants.logSubsystem, category: "Proximity")

/// Tells from Bluetooth signal strength whether this phone is near the Mac it's listening to,
/// for Auto latency. Connects to the Mac app's beacon (matched by Mac name) and reads the RSSI
/// every 2 s. No beacon in range, or a weak signal for a few readings, means away.
///
/// The near threshold calibrates itself: while the Mac reports someone typing or using the
/// mouse (`calibrating`), the signal seen is what "at the desk" looks like in this room.
final class MacProximity: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    /// true near, false away, nil unknown (no Bluetooth, no permission, no beacon found yet).
    private(set) var near: Bool? { didSet { if near != oldValue { onChange?(near) } } }
    var onChange: ((Bool?) -> Void)?
    /// Set while the Mac sees keyboard/mouse input right now: feeds the "at the desk" baseline.
    var calibrating = false
    /// Smoothed signal strength (dBm), for diagnostics.
    private(set) var rssi: Double?

    private var macName: String?
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var matched = false
    private var rejected: Set<UUID> = []
    private var timer: Timer?
    private var nearRun = 0, farRun = 0
    private var recent: [Double] = []
    private var lostTimer: Timer?
    private let defaults = UserDefaults.standard

    private let serviceUUID = CBUUID(string: Constants.proximityServiceUUID)
    private let nameUUID = CBUUID(string: Constants.proximityNameUUID)

    /// Typical signal at the desk; thresholds sit below it.
    private var baseline: Double {
        get { (defaults.object(forKey: baselineKey) as? Double) ?? -65 }
        set { defaults.set(newValue, forKey: baselineKey) }
    }
    private var baselineKey: String { "proximityBaseline.\(macName ?? "")" }
    /// Walk test: desk -62...-76 dBm, another room -77...-85, so the bands are narrow.
    private var nearThreshold: Double { baseline - 6 }
    private var farThreshold: Double { baseline - 11 }

    func start(macName: String) {
        guard self.macName != macName || central == nil else { return }
        stop()
        self.macName = macName
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func stop() {
        timer?.invalidate(); timer = nil
        lostTimer?.invalidate(); lostTimer = nil
        recent = []
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        central?.stopScan()
        central = nil
        peripheral = nil
        matched = false
        rejected = []
        rssi = nil
        nearRun = 0; farRun = 0
        near = nil
    }

    // MARK: - Central

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            scan()
        default:
            diag("proximity: Bluetooth state \(central.state.rawValue); falling back to Mac activity")
            near = nil
        }
    }

    private func scan() {
        guard let central, central.state == .poweredOn, peripheral == nil else { return }
        central.scanForPeripherals(withServices: [serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard peripheral == nil, !rejected.contains(p.identifier) else { return }
        peripheral = p
        p.delegate = self
        central.stopScan()
        central.connect(p)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        lostTimer?.invalidate(); lostTimer = nil
        if matched { startReading(); return }
        p.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        peripheral = nil
        scan()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        timer?.invalidate(); timer = nil
        guard matched else { peripheral = nil; scan(); return }
        // The link also drops every minute or so at the desk and reconnects within seconds, so
        // only a link that stays down means out of range. A pending connect has no timeout: it
        // reconnects (and readings resume) when the phone comes back.
        diag("proximity: beacon link dropped (\(error?.localizedDescription ?? "no error"))")
        rssi = nil
        recent = []
        nearRun = 0; farRun = 0
        lostTimer?.invalidate()
        lostTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            guard let self, self.peripheral?.state != .connected, self.near != false else { return }
            diag("proximity: Mac beacon out of range; away")
            self.near = false
        }
        central.connect(p)
    }

    // MARK: - Peripheral

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = p.services?.first(where: { $0.uuid == serviceUUID }) else { return reject(p) }
        p.discoverCharacteristics([nameUUID], for: svc)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let c = service.characteristics?.first(where: { $0.uuid == nameUUID }) else { return reject(p) }
        p.readValue(for: c)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard c.uuid == nameUUID, !matched else { return }
        let name = c.value.map { String(decoding: $0, as: UTF8.self) }
        guard name == macName else { return reject(p) }
        matched = true
        diag("proximity: found \(name ?? "?")'s beacon")
        startReading()
    }

    func peripheral(_ p: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        let value = RSSI.doubleValue
        guard value < 0, value > -127 else { return }
        // Median of the last 5 readings (~10 s): bodies and hands make single readings jump.
        recent = Array((recent + [value]).suffix(5))
        let smoothed = recent.sorted()[recent.count / 2]
        rssi = smoothed
        if calibrating {
            // Someone is typing or mousing on the Mac right now, so this is what "at the desk"
            // looks like, phone in a pocket included. Clamped so a bad stretch can't make
            // "near" absurdly strict or loose.
            baseline = min(-45, max(-75, baseline + 0.1 * (smoothed - baseline)))
        }
        if smoothed >= nearThreshold { nearRun += 1; farRun = 0 }
        else if smoothed < farThreshold { farRun += 1; nearRun = 0 }
        else { nearRun = 0; farRun = 0 }
        // Three medians (~6 s) in a row before switching, so a brief dip doesn't flip it.
        if nearRun >= 3, near != true { near = true; diag("proximity: near the Mac (\(Int(smoothed)) dBm)") }
        if farRun >= 3, near != false { near = false; diag("proximity: away from the Mac (\(Int(smoothed)) dBm)") }
    }

    private func reject(_ p: CBPeripheral) {
        rejected.insert(p.identifier)
        central?.cancelPeripheralConnection(p)
        peripheral = nil
        scan()
    }

    private func startReading() {
        timer?.invalidate()
        var ticks = 0
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, let p = self.peripheral, p.state == .connected else { return }
            p.readRSSI()
            // The Mac drops a connection with no data traffic after ~65 s ("disconnected from
            // us"); RSSI reads don't count, so read the name now and then to keep it up.
            ticks += 1
            if ticks % 10 == 0, let c = p.services?.first(where: { $0.uuid == self.serviceUUID })?
                .characteristics?.first(where: { $0.uuid == self.nameUUID }) {
                p.readValue(for: c)
            }
        }
        peripheral?.readRSSI()
    }
}
