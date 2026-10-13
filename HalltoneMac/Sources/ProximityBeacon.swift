import CoreBluetooth
import os
import HalltoneCore

private let log = Logger(subsystem: Constants.logSubsystem, category: "Beacon")

/// Advertises a small Bluetooth LE service so a listening phone can measure the signal strength
/// and tell whether it's near this Mac (the phone's Auto latency mode). It carries only the
/// Mac's name, so the phone can pick its own Mac when there are several.
final class ProximityBeacon: NSObject, CBPeripheralManagerDelegate {
    private let name: String
    private var manager: CBPeripheralManager?
    private let service = CBUUID(string: Constants.proximityServiceUUID)

    init(name: String) {
        self.name = name
        super.init()
    }

    func start() {
        guard manager == nil else { return }
        manager = CBPeripheralManager(delegate: self, queue: nil)
    }

    func stop() {
        manager?.stopAdvertising()
        manager?.removeAllServices()
        manager = nil
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else {
            log.notice("Bluetooth not available for the beacon (state \(peripheral.state.rawValue))")
            return
        }
        let nameChar = CBMutableCharacteristic(type: CBUUID(string: Constants.proximityNameUUID), properties: [.read],
                                               value: Data(name.utf8), permissions: [.readable])
        let svc = CBMutableService(type: service, primary: true)
        svc.characteristics = [nameChar]
        peripheral.removeAllServices()
        peripheral.add(svc)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            log.error("beacon service: \(error.localizedDescription, privacy: .public)")
            return
        }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [self.service],
                                     CBAdvertisementDataLocalNameKey: "Halltone"])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error { log.error("beacon advertising: \(error.localizedDescription, privacy: .public)") }
        else { log.notice("proximity beacon advertising") }
    }
}
