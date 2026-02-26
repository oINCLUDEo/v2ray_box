import Foundation
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let httpPort = (options?["HttpPort"] as? NSNumber)?.intValue ?? 10809
        let socksPort = (options?["SocksPort"] as? NSNumber)?.intValue ?? 10808
        let selectedPort = max(1, httpPort > 0 ? httpPort : socksPort)

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: 1500)

        let ipv4 = NEIPv4Settings(addresses: ["172.19.0.2"], subnetMasks: ["255.255.255.252"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        let ipv6 = NEIPv6Settings(addresses: ["fd00::2"], networkPrefixLengths: [64])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6

        settings.dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])

        let proxySettings = NEProxySettings()
        let localProxy = NEProxyServer(address: "127.0.0.1", port: selectedPort)
        proxySettings.httpEnabled = true
        proxySettings.httpsEnabled = true
        proxySettings.httpServer = localProxy
        proxySettings.httpsServer = localProxy
        proxySettings.matchDomains = [""]
        proxySettings.excludeSimpleHostnames = true
        settings.proxySettings = proxySettings

        setTunnelNetworkSettings(settings) { error in
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        completionHandler?("ok".data(using: .utf8))
    }
}
