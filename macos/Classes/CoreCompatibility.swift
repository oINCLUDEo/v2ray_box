import Foundation

struct ConfigLinkMeta {
    let protocolName: String
    let transport: String?
    let shadowsocksPlugin: String?
}

enum CoreCompatibility {
    private static let xrayProtocols: Set<String> = [
        "vmess",
        "vless",
        "trojan",
        "ss",
        "shadowsocks",
        "wg",
        "wireguard"
    ]

    private static let xrayTransports: Set<String> = [
        "tcp",
        "kcp",
        "mkcp",
        "ws",
        "websocket",
        "grpc",
        "http",
        "h2",
        "httpupgrade",
        "xhttp",
        "splithttp",
        "quic"
    ]

    static func resolveEngineForLink(preferredEngine: String, link: String) -> String {
        let preferred = preferredEngine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if preferred == "singbox" {
            return "singbox"
        }
        return isXrayCompatible(link: link) ? "xray" : "singbox"
    }

    static func isXrayCompatible(link: String) -> Bool {
        guard let meta = parseConfigLinkMeta(link: link) else {
            return false
        }

        let proto = meta.protocolName
        if ["tuic", "ssh", "hy", "hysteria", "hy2", "hysteria2"].contains(proto) {
            return false
        }
        if !xrayProtocols.contains(proto) {
            return false
        }
        if let transport = meta.transport, !transport.isEmpty, !xrayTransports.contains(transport) {
            return false
        }
        if proto == "ss" || proto == "shadowsocks" {
            let plugin = meta.shadowsocksPlugin?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let plugin, !plugin.isEmpty, !plugin.contains("obfs=http") {
                return false
            }
        }
        return true
    }

    static func parseConfigLinkMeta(link: String) -> ConfigLinkMeta? {
        let schemeRaw = link.components(separatedBy: "://").first?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if schemeRaw.isEmpty {
            return nil
        }
        let protocolName: String
        switch schemeRaw {
        case "wireguard":
            protocolName = "wg"
        case "hysteria2":
            protocolName = "hy2"
        default:
            protocolName = schemeRaw
        }

        let params = parseQueryParams(link: link)
        let transport = normalizeTransport(params["type"] ?? params["net"] ?? vmessNetworkFromPayload(link: link))
        let ssPlugin = (protocolName == "ss" || protocolName == "shadowsocks") ? params["plugin"] : nil
        return ConfigLinkMeta(protocolName: protocolName, transport: transport, shadowsocksPlugin: ssPlugin)
    }

    private static func normalizeTransport(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "websocket":
            return "ws"
        case "http2":
            return "h2"
        case "http-upgrade":
            return "httpupgrade"
        case "split-http":
            return "splithttp"
        default:
            return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    private static func parseQueryParams(link: String) -> [String: String] {
        guard let components = URLComponents(string: link) else {
            return [:]
        }
        var params: [String: String] = [:]
        for item in components.queryItems ?? [] {
            params[item.name.lowercased()] = item.value ?? ""
        }
        return params
    }

    private static func vmessNetworkFromPayload(link: String) -> String? {
        guard link.hasPrefix("vmess://") else {
            return nil
        }
        let payload = String(link.dropFirst("vmess://".count)).components(separatedBy: "#").first ?? ""
        guard let data = Data(base64Encoded: payload) ?? Data(base64Encoded: paddedBase64(payload)),
              let decoded = String(data: data, encoding: .utf8),
              decoded.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"),
              let jsonData = decoded.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else {
            return nil
        }
        return (json["net"] as? String)?.lowercased()
    }

    private static func paddedBase64(_ input: String) -> String {
        var value = input.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = value.count % 4
        if remainder > 0 {
            value += String(repeating: "=", count: 4 - remainder)
        }
        return value
    }
}
