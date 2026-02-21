## 1.0.0

* **Dual-core support** — Xray-core and sing-box with runtime switching via `setCoreEngine()` / `getCoreEngine()`
* **Protocols** — VLESS, VMess, Trojan, Shadowsocks, Hysteria, Hysteria2, TUIC, WireGuard, SSH
* **Transports** — WebSocket, gRPC, HTTP/H2, HTTPUpgrade, xHTTP, QUIC
* **Security** — TLS, Reality, uTLS fingerprint, Multiplex (mux)
* **VPN & Proxy modes** — Full-device VPN via TUN or local SOCKS/HTTP proxy
* **Real-time traffic stats** — Xray stats API and sing-box Clash API
* **Ping testing** — Single and parallel batch ping with streaming results
* **Per-app proxy** — Include/exclude specific apps from VPN (Android)
* **Persistent traffic storage** — Cumulative upload/download across sessions
* **Customizable notifications** — Title, icon, stop button text (Android)
* **Config utilities** — Parse, validate, generate, format configs
* **Subscription support** — Parse and generate subscription import links
* **Debug mode** — Toggle verbose logging
* **Platform support** — Android, iOS (VPN via NetworkExtension), macOS (system proxy)
* **iOS** — sing-box via HiddifyCore xcframework, Xray via XrayConfigBuilder with PacketTunnel extension
* **macOS** — Both cores run as CLI binaries (subprocesses) with automatic system proxy configuration
