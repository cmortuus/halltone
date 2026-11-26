import Testing
import Foundation
import HalltoneCore
@testable import HalltoneLinuxKit

@Suite struct DiscoveryTests {
    static func ip(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 { a << 24 | b << 16 | c << 8 | d }

    @Test func wiredBeatsWifiAndVirtualInterfacesAreSkipped() {
        let ifs = [
            InterfaceAddress(name: "docker0", ipv4: Self.ip(172, 17, 0, 1)),
            InterfaceAddress(name: "wlp3s0", ipv4: Self.ip(192, 168, 1, 50)),
            InterfaceAddress(name: "enp5s0", ipv4: Self.ip(192, 168, 1, 40)),
            InterfaceAddress(name: "tailscale0", ipv4: Self.ip(100, 101, 102, 103)),
            InterfaceAddress(name: "virbr0", ipv4: Self.ip(192, 168, 122, 1)),
        ]
        let r = NetworkAddresses.pick(from: ifs, defaultRoute: "wlp3s0")
        #expect(r.addr == "192.168.1.40")
        #expect(r.tailscale == "100.101.102.103")
    }

    @Test func defaultRouteBreaksTiesAndFallsBackToWifi() {
        let two = [InterfaceAddress(name: "eno1", ipv4: Self.ip(10, 0, 0, 5)),
                   InterfaceAddress(name: "eth1", ipv4: Self.ip(10, 0, 1, 5))]
        #expect(NetworkAddresses.pick(from: two, defaultRoute: "eth1").addr == "10.0.1.5")
        #expect(NetworkAddresses.pick(from: two, defaultRoute: nil).addr == "10.0.0.5")
        let wifi = [InterfaceAddress(name: "wlan0", ipv4: Self.ip(192, 168, 0, 9))]
        #expect(NetworkAddresses.pick(from: wifi, defaultRoute: nil).addr == "192.168.0.9")
        #expect(NetworkAddresses.pick(from: [], defaultRoute: nil) == HostAddresses(addr: nil, tailscale: nil))
        // Link-local and a Tailscale address on an odd interface name are never `addr`.
        let odd = [InterfaceAddress(name: "enp1", ipv4: Self.ip(169, 254, 3, 3)),
                   InterfaceAddress(name: "ts0", ipv4: Self.ip(100, 64, 0, 7))]
        let r = NetworkAddresses.pick(from: odd, defaultRoute: nil)
        #expect(r.addr == nil)
        #expect(r.tailscale == "100.64.0.7")
    }

    @Test func parsesTheDefaultRouteFromProcNetRoute() {
        let table = """
        Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT
        wlp3s0\t00000000\t0101A8C0\t0003\t0\t0\t600\t00000000\t0\t0\t0
        enp5s0\t00000000\t0101A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0
        enp5s0\t0001A8C0\t00000000\t0001\t0\t0\t100\t00FFFFFF\t0\t0\t0
        """
        #expect(NetworkAddresses.defaultRouteInterface(procNetRoute: table) == "enp5s0")
        #expect(NetworkAddresses.defaultRouteInterface(procNetRoute: "Iface\tDestination\n") == nil)
    }

    @Test func avahiArgumentsCarryTheSameTxtAsTheMac() {
        let args = AvahiAdvertiser.arguments(
            name: "Gamer PC", port: 47800,
            txt: ["name": "Gamer PC", "v": "1", "port": "47800"],
            addresses: HostAddresses(addr: "192.168.1.40", tailscale: "100.64.0.7"))
        #expect(args == ["Gamer PC", "_halltone._udp", "47800",
                         "name=Gamer PC", "v=1", "port=47800", "addr=192.168.1.40", "ts=100.64.0.7"])
        let bare = AvahiAdvertiser.arguments(name: "n", port: 1, txt: ["name": "n", "v": "1", "port": "1"],
                                             addresses: HostAddresses(addr: nil, tailscale: nil))
        #expect(bare == ["n", "_halltone._udp", "1", "name=n", "v=1", "port=1"])
    }

    @Test func parsesPactlOutput() {
        #expect(DefaultSink.parse("alsa_output.pci-0000_00_1f.3.analog-stereo\n") == "alsa_output.pci-0000_00_1f.3.analog-stereo")
        #expect(DefaultSink.parse("  \n") == nil)
    }

    @Test func realInterfaceEnumerationDoesNotCrash() {
        // On any machine: whatever is up, picking from it returns something sensible or nothing.
        let r = NetworkAddresses.current()
        if let a = r.addr { #expect(a.split(separator: ".").count == 4) }
    }
}
