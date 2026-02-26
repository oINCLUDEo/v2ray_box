import Cocoa
import FlutterMacOS
import Network
import NetworkExtension
import CFNetwork
import Darwin

public class V2rayBoxPlugin: NSObject, FlutterPlugin {
    private static let defaultPingTimeoutMs = 7000
    private static let minPingTimeoutMs = 1000
    private static let maxPingTimeoutMs = 30000
    private static let maxParallelPingTasks = 4
    private static let maxLogLines = 300

    private var methodChannel: FlutterMethodChannel?
    private var statusChannel: FlutterEventChannel?
    private var alertsChannel: FlutterEventChannel?
    private var statsChannel: FlutterEventChannel?
    private var pingChannel: FlutterEventChannel?
    private var logsChannel: FlutterEventChannel?

    private var statusEventSink: FlutterEventSink?
    private var alertsEventSink: FlutterEventSink?
    private var statsEventSink: FlutterEventSink?
    private var pingEventSink: FlutterEventSink?
    private var logsEventSink: FlutterEventSink?

    private var debugMode: Bool {
        get { UserDefaults.standard.bool(forKey: "v2ray_box_debug_mode") }
        set { UserDefaults.standard.set(newValue, forKey: "v2ray_box_debug_mode") }
    }

    private var pingTestUrl: String {
        get { UserDefaults.standard.string(forKey: "v2ray_box_ping_test_url") ?? "https://www.gstatic.com/generate_204" }
        set { UserDefaults.standard.set(newValue, forKey: "v2ray_box_ping_test_url") }
    }

    private var coreEngine: String {
        get { UserDefaults.standard.string(forKey: "v2ray_box_core_engine") ?? "singbox" }
        set { UserDefaults.standard.set(newValue, forKey: "v2ray_box_core_engine") }
    }

    private var serviceMode: String {
        get {
            let mode = UserDefaults.standard.string(forKey: "v2ray_box_service_mode") ?? "vpn"
            return (mode == "vpn" || mode == "proxy") ? mode : "vpn"
        }
        set {
            UserDefaults.standard.set((newValue == "proxy") ? "proxy" : "vpn", forKey: "v2ray_box_service_mode")
        }
    }

    private var activeRuntimeEngine: String = "singbox"
    private var activeServiceMode: String = "proxy"
    private var tunnelManager: NETunnelProviderManager?
    private var vpnObserver: NSObjectProtocol?
    private var statsTimer: Timer?
    private var configOptions: String = "{}"
    private var activeConfigPath: String = ""
    private var activeProfileName: String = ""
    private var isRunning: Bool = false

    private var totalUploadTraffic: Int64 = 0
    private var totalDownloadTraffic: Int64 = 0
    private var lastSingboxUpload: Int64 = 0
    private var lastSingboxDownload: Int64 = 0
    private var lastXrayUpload: Int64 = 0
    private var lastXrayDownload: Int64 = 0

    private var coreMonitorTimer: Timer?
    private var failedPortChecks = 0

    private let logBufferLock = NSLock()
    private var logBuffer: [String] = []

    private var singboxConfigBuilder: ConfigBuilder {
        ConfigBuilder(optionsJson: configOptions)
    }

    private var xrayConfigBuilder: XrayConfigBuilder {
        XrayConfigBuilder(optionsJson: configOptions)
    }

    override init() {
        super.init()
        activeRuntimeEngine = coreEngine
        activeServiceMode = serviceMode
        bindCoreLogCallbacks()
        setupVPNObserver()
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "v2ray_box", binaryMessenger: registrar.messenger)
        let instance = V2rayBoxPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        instance.methodChannel = channel

        let statusChannel = FlutterEventChannel(
            name: "v2ray_box/status",
            binaryMessenger: registrar.messenger,
            codec: FlutterJSONMethodCodec.sharedInstance()
        )
        statusChannel.setStreamHandler(StatusStreamHandler(plugin: instance))
        instance.statusChannel = statusChannel

        let alertsChannel = FlutterEventChannel(
            name: "v2ray_box/alerts",
            binaryMessenger: registrar.messenger,
            codec: FlutterJSONMethodCodec.sharedInstance()
        )
        alertsChannel.setStreamHandler(AlertsStreamHandler(plugin: instance))
        instance.alertsChannel = alertsChannel

        let statsChannel = FlutterEventChannel(
            name: "v2ray_box/stats",
            binaryMessenger: registrar.messenger,
            codec: FlutterJSONMethodCodec.sharedInstance()
        )
        statsChannel.setStreamHandler(StatsStreamHandler(plugin: instance))
        instance.statsChannel = statsChannel

        let pingChannel = FlutterEventChannel(
            name: "v2ray_box/ping",
            binaryMessenger: registrar.messenger,
            codec: FlutterJSONMethodCodec.sharedInstance()
        )
        pingChannel.setStreamHandler(PingStreamHandler(plugin: instance))
        instance.pingChannel = pingChannel

        let logsChannel = FlutterEventChannel(
            name: "v2ray_box/logs",
            binaryMessenger: registrar.messenger,
            codec: FlutterJSONMethodCodec.sharedInstance()
        )
        logsChannel.setStreamHandler(LogsStreamHandler(plugin: instance))
        instance.logsChannel = logsChannel
    }

    deinit {
        if let observer = vpnObserver {
            NotificationCenter.default.removeObserver(observer)
            vpnObserver = nil
        }
        statsTimer?.invalidate()
        coreMonitorTimer?.invalidate()
        if isRunning {
            stopCore()
            if activeServiceMode == "vpn" {
                stopTunnelIfNeeded()
            } else {
                disableSystemProxy()
            }
        }
        XrayProcess.shared.onLog = nil
        SingboxProcess.shared.onLog = nil
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getPlatformVersion":
            result("macOS " + ProcessInfo.processInfo.operatingSystemVersionString)

        case "setup":
            setup(result: result)

        case "parse_config":
            guard let args = call.arguments as? [String: Any],
                  let link = args["link"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing link parameter", details: nil))
                return
            }
            let debug = args["debug"] as? Bool ?? false
            parseConfig(link: link, debug: debug, result: result)

        case "change_config_options":
            guard let options = call.arguments as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing options parameter", details: nil))
                return
            }
            configOptions = options
            result(true)

        case "generate_config":
            guard let args = call.arguments as? [String: Any],
                  let link = args["link"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing link parameter", details: nil))
                return
            }
            generateConfig(link: link, result: result)

        case "start":
            guard let args = call.arguments as? [String: Any],
                  let link = args["link"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing link parameter", details: nil))
                return
            }
            let name = args["name"] as? String ?? ""
            start(link: link, name: name, result: result)

        case "stop":
            stop(result: result)

        case "restart":
            guard let args = call.arguments as? [String: Any],
                  let link = args["link"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing link parameter", details: nil))
                return
            }
            let name = args["name"] as? String ?? ""
            restart(link: link, name: name, result: result)

        case "check_vpn_permission":
            result(true)

        case "request_vpn_permission":
            result(true)

        case "set_service_mode":
            guard let mode = call.arguments as? String,
                  mode == "vpn" || mode == "proxy" else {
                result(FlutterError(code: "INVALID_ARGS", message: "Mode must be 'vpn' or 'proxy'", details: nil))
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                self.serviceMode = mode
                if self.isRunning {
                    self.stopCoreMonitor()
                    self.stopCore()
                    if self.activeServiceMode == "vpn" {
                        self.stopTunnelIfNeeded()
                    } else {
                        self.disableSystemProxy()
                    }
                    self.isRunning = false
                    self.resetRateCounters()
                }
                self.activeServiceMode = mode
                DispatchQueue.main.async {
                    self.statusEventSink?(["status": "Stopped"])
                    result(true)
                }
            }

        case "get_service_mode":
            result(serviceMode)

        case "set_notification_stop_button_text", "set_notification_title", "set_notification_icon":
            result(true)

        case "get_installed_packages":
            result("[]")

        case "get_package_icon":
            result(nil)

        case "url_test":
            guard let args = call.arguments as? [String: Any],
                  let link = args["link"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing link parameter", details: nil))
                return
            }
            let timeout = parsePingTimeout(args["timeout"])
            urlTest(link: link, timeout: timeout, result: result)

        case "url_test_all":
            guard let args = call.arguments as? [String: Any],
                  let links = args["links"] as? [String] else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing links parameter", details: nil))
                return
            }
            let timeout = parsePingTimeout(args["timeout"])
            urlTestAll(links: links, timeout: timeout, result: result)

        case "set_per_app_proxy_mode", "set_per_app_proxy_list":
            result(true)

        case "get_per_app_proxy_mode":
            result("off")

        case "get_per_app_proxy_list":
            result([String]())

        case "get_total_traffic":
            result(["upload": totalUploadTraffic, "download": totalDownloadTraffic])

        case "reset_total_traffic":
            resetTrafficCounters()
            result(true)

        case "set_core_engine":
            guard let engine = call.arguments as? String,
                  engine == "xray" || engine == "singbox" else {
                result(FlutterError(code: "INVALID_ARGS", message: "Engine must be 'xray' or 'singbox'", details: nil))
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                if self.coreEngine != engine {
                    if self.isRunning {
                        self.stopCoreMonitor()
                        self.stopCore()
                        if self.activeServiceMode == "vpn" {
                            self.stopTunnelIfNeeded()
                        } else {
                            self.disableSystemProxy()
                        }
                        self.isRunning = false
                    }
                    self.coreEngine = engine
                    self.activeRuntimeEngine = engine
                    self.resetTrafficCounters()
                    DispatchQueue.main.async {
                        self.statusEventSink?(["status": "Stopped"])
                        result(true)
                    }
                } else {
                    DispatchQueue.main.async { result(true) }
                }
            }

        case "get_core_engine":
            result(coreEngine)

        case "get_core_info":
            ensureCoreBinariesPrepared()
            var info: [String: Any] = [
                "core": coreEngine,
                "active_runtime_engine": activeRuntimeEngine
            ]
            if coreEngine == "xray" {
                info["engine"] = "xray-core"
                info["version_source"] = "xray binary"
                info["version"] = XrayProcess.shared.getVersion()
            } else {
                info["engine"] = "sing-box"
                info["version_source"] = "sing-box binary"
                info["version"] = SingboxProcess.shared.getVersion()
            }
            result(info)

        case "check_config_json":
            guard let configJson = call.arguments as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing config JSON", details: nil))
                return
            }
            if let data = configJson.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data)) != nil {
                result("")
            } else {
                result("Invalid JSON format")
            }

        case "start_with_json":
            guard let args = call.arguments as? [String: Any],
                  let configJson = args["config"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing config parameter", details: nil))
                return
            }
            let name = args["name"] as? String ?? ""
            startWithJson(configJson: configJson, name: name, result: result)

        case "get_logs":
            result(logSnapshot())

        case "clear_logs":
            clearLogBuffer()
            result(true)

        case "set_debug_mode":
            if let enabled = call.arguments as? Bool {
                debugMode = enabled
            }
            result(true)

        case "get_debug_mode":
            result(debugMode)

        case "format_bytes":
            let bytes: Int64
            if let b = call.arguments as? Int64 {
                bytes = b
            } else if let b = call.arguments as? Int {
                bytes = Int64(b)
            } else {
                result("0 B")
                return
            }
            result(formatBytesLocal(bytes))

        case "get_active_config":
            getActiveConfig(result: result)

        case "proxy_display_type":
            if let type = call.arguments as? String {
                result(type.prefix(1).uppercased() + type.dropFirst())
            } else {
                result("")
            }

        case "format_config":
            guard let configJson = call.arguments as? String else {
                result("")
                return
            }
            if let data = configJson.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
               let str = String(data: pretty, encoding: .utf8) {
                result(str)
            } else {
                result(configJson)
            }

        case "available_port":
            if let startPort = call.arguments as? Int {
                result(findAvailablePort(from: startPort))
            } else {
                result(-1)
            }

        case "select_outbound":
            result(false)

        case "set_clash_mode":
            result(false)

        case "parse_subscription":
            result([String: Any]())

        case "generate_subscription_link":
            result("")

        case "set_locale":
            result(true)

        case "set_ping_test_url":
            if let url = call.arguments as? String {
                pingTestUrl = url
            }
            result(true)

        case "get_ping_test_url":
            result(pingTestUrl)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - VPN (PacketTunnel)

    private func setupVPNObserver() {
        vpnObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard self.activeServiceMode == "vpn" || self.serviceMode == "vpn" else { return }
            guard let connection = notification.object as? NEVPNConnection else { return }
            if let managedConnection = self.tunnelManager?.connection, managedConnection !== connection {
                return
            }
            self.handleVPNStatusChange(connection.status)
        }
    }

    private func handleVPNStatusChange(_ status: NEVPNStatus) {
        let statusString: String
        switch status {
        case .connecting, .reasserting:
            statusString = "Starting"
        case .connected:
            isRunning = true
            statusString = "Started"
        case .disconnecting:
            statusString = "Stopping"
        case .disconnected, .invalid:
            if activeServiceMode == "vpn" {
                stopCoreMonitor()
                if XrayProcess.shared.isRunning || SingboxProcess.shared.isRunning {
                    stopCore()
                }
                isRunning = false
                resetRateCounters()
            }
            statusString = "Stopped"
        @unknown default:
            statusString = "Stopped"
        }
        statusEventSink?(["status": statusString])
    }

    private func packetTunnelBundleIdentifier() -> String {
        if let explicit = Bundle.main.object(forInfoDictionaryKey: "PacketTunnelBundleIdentifier") as? String,
           !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return explicit
        }
        let mainId = Bundle.main.bundleIdentifier ?? "com.example.v2ray_box_example"
        return "\(mainId).PacketTunnel"
    }

    private func loadOrCreateTunnelManager() throws -> NETunnelProviderManager {
        if let cached = tunnelManager {
            return cached
        }

        let desiredBundleId = packetTunnelBundleIdentifier()
        let semaphore = DispatchSemaphore(value: 0)
        var loadedManagers: [NETunnelProviderManager] = []
        var loadError: Error?
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            loadedManagers = managers ?? []
            loadError = error
            semaphore.signal()
        }
        semaphore.wait()
        if let loadError {
            throw loadError
        }

        if let existing = loadedManagers.first(where: { manager in
            guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else { return false }
            return proto.providerBundleIdentifier == desiredBundleId
        }) {
            try configureAndEnableTunnelManager(existing, providerBundleId: desiredBundleId)
            tunnelManager = existing
            return existing
        }

        let created = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = desiredBundleId
        proto.serverAddress = "V2Ray Box"
        created.protocolConfiguration = proto
        created.localizedDescription = "V2Ray Box"
        created.isEnabled = true
        try saveAndReload(manager: created)
        tunnelManager = created
        return created
    }

    private func configureAndEnableTunnelManager(_ manager: NETunnelProviderManager, providerBundleId: String) throws {
        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleId
        proto.serverAddress = "V2Ray Box"
        manager.protocolConfiguration = proto
        manager.localizedDescription = "V2Ray Box"
        manager.isEnabled = true
        try saveAndReload(manager: manager)
    }

    private func saveAndReload(manager: NETunnelProviderManager) throws {
        let saveSemaphore = DispatchSemaphore(value: 0)
        var saveError: Error?
        manager.saveToPreferences { error in
            saveError = error
            saveSemaphore.signal()
        }
        saveSemaphore.wait()
        if let saveError {
            throw saveError
        }

        let loadSemaphore = DispatchSemaphore(value: 0)
        var reloadError: Error?
        manager.loadFromPreferences { error in
            reloadError = error
            loadSemaphore.signal()
        }
        loadSemaphore.wait()
        if let reloadError {
            throw reloadError
        }
    }

    private func startTunnel(httpPort: Int, socksPort: Int) throws {
        let manager = try loadOrCreateTunnelManager()
        guard let session = manager.connection as? NETunnelProviderSession else {
            throw NSError(domain: "V2rayBox", code: -201, userInfo: [NSLocalizedDescriptionKey: "Tunnel provider session is unavailable"])
        }

        switch manager.connection.status {
        case .connected, .connecting, .reasserting:
            return
        default:
            break
        }

        var options: [String: NSObject] = [
            "HttpPort": NSNumber(value: max(1, httpPort)),
            "SocksPort": NSNumber(value: max(1, socksPort))
        ]
        options["CoreEngine"] = activeRuntimeEngine as NSString

        try session.startVPNTunnel(options: options)
        if !waitForTunnelConnected(manager: manager, timeoutMs: 9000) {
            throw NSError(domain: "V2rayBox", code: -202, userInfo: [NSLocalizedDescriptionKey: "Tunnel did not become ready"])
        }
    }

    private func waitForTunnelConnected(manager: NETunnelProviderManager, timeoutMs: Int) -> Bool {
        let deadline = Date().addingTimeInterval(Double(max(1500, timeoutMs)) / 1000.0)
        while Date() < deadline {
            let status = manager.connection.status
            if status == .connected {
                return true
            }
            if status == .invalid || status == .disconnected {
                usleep(100_000)
            } else {
                usleep(140_000)
            }
        }
        return manager.connection.status == .connected
    }

    private func stopTunnelIfNeeded() {
        guard let manager = tunnelManager else { return }
        let status = manager.connection.status
        if status == .disconnected || status == .invalid {
            return
        }
        manager.connection.stopVPNTunnel()
        let deadline = Date().addingTimeInterval(3.5)
        while Date() < deadline {
            let current = manager.connection.status
            if current == .disconnected || current == .invalid {
                break
            }
            usleep(120_000)
        }
    }

    // MARK: - Setup

    private func setup(result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let fileManager = FileManager.default
                let baseDir = self.getBaseDirectory()
                let workingDir = self.getWorkingDirectory()
                let tempDir = self.getTempDirectory()

                try fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: workingDir, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: workingDir.appendingPathComponent("profiles"), withIntermediateDirectories: true)
                self.ensureCoreBinariesPrepared()

                DispatchQueue.main.async {
                    result("")
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "SETUP_ERROR", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    // MARK: - Parse Config

    private func parseConfig(link: String, debug: Bool, result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let built = try self.buildConfigForLink(link)
                let validationPath = self.getTempDirectory().appendingPathComponent("config_check.json")
                try FileManager.default.createDirectory(at: validationPath.deletingLastPathComponent(), withIntermediateDirectories: true)
                try built.config.write(to: validationPath, atomically: true, encoding: .utf8)

                let validationError: String
                if built.runtimeEngine == "xray" {
                    validationError = XrayProcess.shared.validateConfig(configPath: validationPath.path)
                } else {
                    validationError = SingboxProcess.shared.validateConfig(configPath: validationPath.path, workingDir: self.getWorkingDirectory().path)
                }

                if debug && !validationError.isEmpty {
                    self.appendCoreLog("Config parse error (\(built.runtimeEngine)): \(validationError)", source: "parser")
                }

                DispatchQueue.main.async {
                    result(validationError)
                }
            } catch {
                DispatchQueue.main.async {
                    result(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Generate Config

    private func generateConfig(link: String, result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let built = try self.buildConfigForLink(link)
                DispatchQueue.main.async {
                    result(built.config)
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "BUILD_CONFIG", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    // MARK: - Start / Restart / Stop

    private func start(link: String, name: String, result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                self.ensureCoreBinariesPrepared()
                let built = try self.buildConfigForLink(link)
                let mode = self.serviceMode
                let ok = self.startConnection(
                    configJson: built.config,
                    runtimeEngine: built.runtimeEngine,
                    name: name,
                    mode: mode
                )
                DispatchQueue.main.async {
                    if ok {
                        result(true)
                    } else {
                        result(FlutterError(code: "START_ERROR", message: "Failed to start \(built.runtimeEngine) core", details: nil))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "START_ERROR", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    private func restart(link: String, name: String, result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                self.ensureCoreBinariesPrepared()
                let built = try self.buildConfigForLink(link)
                let mode = self.serviceMode
                let ok = self.startConnection(
                    configJson: built.config,
                    runtimeEngine: built.runtimeEngine,
                    name: name,
                    mode: mode
                )
                DispatchQueue.main.async {
                    if ok {
                        result(true)
                    } else {
                        result(FlutterError(code: "RESTART_ERROR", message: "Failed to restart \(built.runtimeEngine) core", details: nil))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "RESTART_ERROR", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    private func stop(result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.stopCoreMonitor()

            if !self.isRunning {
                DispatchQueue.main.async { result(true) }
                return
            }

            DispatchQueue.main.async {
                self.statusEventSink?(["status": "Stopping"])
            }

            if self.activeServiceMode == "vpn" {
                self.stopTunnelIfNeeded()
            }
            self.stopCore()
            if self.activeServiceMode == "proxy" {
                self.disableSystemProxy()
            }
            self.isRunning = false
            self.resetRateCounters()

            DispatchQueue.main.async {
                self.statusEventSink?(["status": "Stopped"])
                result(true)
            }
        }
    }

    private func startWithJson(configJson: String, name: String, result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .userInitiated).async {
            let runtimeEngine = self.coreEngine
            let mode = self.serviceMode
            do {
                self.ensureCoreBinariesPrepared()
                let configPath = self.getTempDirectory().appendingPathComponent("config_json_check.json")
                try FileManager.default.createDirectory(at: configPath.deletingLastPathComponent(), withIntermediateDirectories: true)
                try configJson.write(to: configPath, atomically: true, encoding: .utf8)

                let validationError: String
                if runtimeEngine == "xray" {
                    validationError = XrayProcess.shared.validateConfig(configPath: configPath.path)
                } else {
                    validationError = SingboxProcess.shared.validateConfig(configPath: configPath.path, workingDir: self.getWorkingDirectory().path)
                }
                if !validationError.isEmpty {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "INVALID_CONFIG", message: validationError, details: nil))
                    }
                    return
                }

                let ok = self.startConnection(
                    configJson: configJson,
                    runtimeEngine: runtimeEngine,
                    name: name,
                    mode: mode
                )
                DispatchQueue.main.async {
                    if ok {
                        result(true)
                    } else {
                        result(FlutterError(code: "START_ERROR", message: "Failed to start \(runtimeEngine) core", details: nil))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "START_ERROR", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    private func startConnection(configJson: String, runtimeEngine: String, name: String, mode: String) -> Bool {
        activeProfileName = name

        if isRunning {
            stopCoreMonitor()
            if activeServiceMode == "vpn" {
                stopTunnelIfNeeded()
            }
            stopCore()
            if activeServiceMode == "proxy" {
                disableSystemProxy()
            }
            isRunning = false
            usleep(180_000)
        }

        do {
            let configPath = getWorkingDirectory().appendingPathComponent("profiles/active_config.json")
            try FileManager.default.createDirectory(at: configPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            try configJson.write(to: configPath, atomically: true, encoding: .utf8)
            activeConfigPath = configPath.path
            activeRuntimeEngine = runtimeEngine
            activeServiceMode = (mode == "proxy") ? "proxy" : "vpn"

            resetRateCounters()

            DispatchQueue.main.async {
                self.statusEventSink?(["status": "Starting"])
            }

            let success = startCore(configPath: configPath.path, runtimeEngine: runtimeEngine)
            if !success {
                isRunning = false
                DispatchQueue.main.async {
                    self.statusEventSink?(["status": "Stopped"])
                }
                return false
            }

            isRunning = true
            if activeServiceMode == "vpn" {
                do {
                    let httpPort = getHttpProxyPort(for: runtimeEngine)
                    let socksPort = getProxyPort(for: runtimeEngine)
                    try startTunnel(httpPort: httpPort, socksPort: socksPort)
                } catch {
                    appendCoreLog("Failed to start VPN tunnel: \(error.localizedDescription)", source: "vpn")
                    stopCore()
                    isRunning = false
                    DispatchQueue.main.async {
                        self.statusEventSink?(["status": "Stopped"])
                    }
                    return false
                }
            } else {
                let proxyPort = getProxyPort(for: runtimeEngine)
                enableSystemProxy(port: proxyPort)
            }
            startCoreMonitor()

            DispatchQueue.main.async {
                self.statusEventSink?(["status": "Started"])
            }
            return true
        } catch {
            appendCoreLog("Start exception: \(error.localizedDescription)", source: "plugin")
            isRunning = false
            return false
        }
    }

    private func startCore(configPath: String, runtimeEngine: String) -> Bool {
        if runtimeEngine == "xray" {
            return XrayProcess.shared.start(configPath: configPath)
        }
        return SingboxProcess.shared.start(configPath: configPath, workingDir: getWorkingDirectory().path)
    }

    private func stopCore() {
        if XrayProcess.shared.isRunning {
            XrayProcess.shared.stop()
        }
        if SingboxProcess.shared.isRunning {
            SingboxProcess.shared.stop()
        }
    }

    private func startCoreMonitor() {
        stopCoreMonitor()
        failedPortChecks = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard self.isRunning else { return }
            self.coreMonitorTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                self.checkCoreStatus()
            }
        }
    }

    private func stopCoreMonitor() {
        coreMonitorTimer?.invalidate()
        coreMonitorTimer = nil
    }

    private func checkCoreStatus() {
        guard isRunning else {
            stopCoreMonitor()
            return
        }

        let running: Bool = (activeRuntimeEngine == "xray") ? XrayProcess.shared.isRunning : SingboxProcess.shared.isRunning
        if running {
            failedPortChecks = 0
            return
        }

        failedPortChecks += 1
        if failedPortChecks < 2 { return }

        isRunning = false
        stopCoreMonitor()
        if activeServiceMode == "vpn" {
            stopTunnelIfNeeded()
        } else {
            disableSystemProxy()
        }
        DispatchQueue.main.async {
            self.statusEventSink?(["status": "Stopped"])
        }
    }

    // MARK: - URL Test

    private func urlTest(link: String, timeout: Int, result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .userInitiated).async {
            let latency = self.performURLTestSync(link: link, timeoutMs: timeout)
            DispatchQueue.main.async {
                result(latency)
            }
        }
    }

    private func urlTestAll(links: [String], timeout: Int, result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .userInitiated).async {
            if links.isEmpty {
                DispatchQueue.main.async {
                    result([String: Int]())
                }
                return
            }

            var output: [String: Int] = [:]
            let outputLock = NSLock()
            let group = DispatchGroup()
            let maxWorkers = max(1, min(Self.maxParallelPingTasks, links.count))
            let semaphore = DispatchSemaphore(value: maxWorkers)

            for link in links {
                semaphore.wait()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer {
                        semaphore.signal()
                        group.leave()
                    }

                    let latency = self.performURLTestSync(link: link, timeoutMs: timeout)
                    outputLock.lock()
                    output[link] = latency
                    outputLock.unlock()

                    let event: [String: Any] = ["link": link, "latency": latency]
                    DispatchQueue.main.async {
                        self.pingEventSink?(event)
                    }
                }
            }

            group.wait()

            DispatchQueue.main.async {
                result(output)
            }
        }
    }

    private func performURLTestSync(link: String, timeoutMs: Int) -> Int {
        // Keep ping path deterministic (same as Android behavior):
        // prefer xray for xray-compatible links regardless of selected runtime core.
        let runtimeEngine = CoreCompatibility.isXrayCompatible(link: link) ? "xray" : "singbox"
        let effectiveTimeout = max(Self.minPingTimeoutMs, timeoutMs)
        let canFallbackToXray = runtimeEngine == "singbox" && CoreCompatibility.isXrayCompatible(link: link)
        let primaryTimeout = canFallbackToXray
            ? max(Self.minPingTimeoutMs, min(3500, effectiveTimeout / 2))
            : effectiveTimeout

        let primaryLatency = performURLTestSync(link: link, timeoutMs: primaryTimeout, runtimeEngine: runtimeEngine)
        if primaryLatency >= 0 {
            return primaryLatency
        }

        // sing-box ping path can fail on xray-only transports (for example xhttp/mkcp).
        if canFallbackToXray {
            let fallbackTimeout = max(Self.minPingTimeoutMs, effectiveTimeout - primaryTimeout)
            return performURLTestSync(link: link, timeoutMs: fallbackTimeout, runtimeEngine: "xray")
        }

        return -1
    }

    private func performURLTestSync(link: String, timeoutMs: Int, runtimeEngine: String) -> Int {
        ensureCoreBinariesPrepared()
        guard let proxyPort = reservePingPort(),
              let configJson = buildPingConfig(link: link, runtimeEngine: runtimeEngine, proxyPort: proxyPort) else {
            return -1
        }

        let tempConfig = getTempDirectory().appendingPathComponent("ping_\(UUID().uuidString).json")
        do {
            try FileManager.default.createDirectory(at: tempConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
            try configJson.write(to: tempConfig, atomically: true, encoding: .utf8)
        } catch {
            return -1
        }

        guard let proc = launchPingCore(runtimeEngine: runtimeEngine, configPath: tempConfig.path) else {
            try? FileManager.default.removeItem(at: tempConfig)
            return -1
        }

        defer {
            stopTempProcess(proc)
            try? FileManager.default.removeItem(at: tempConfig)
        }

        let readyTimeout = max(900, min(2500, timeoutMs / 2))
        guard waitForLocalProxyReady(port: proxyPort, timeoutMs: readyTimeout) else {
            return -1
        }

        let sessionTimeout = max(1200, min(timeoutMs, 10000))
        guard let pingSession = makeSocksPingSession(proxyPort: proxyPort, timeoutMs: sessionTimeout) else {
            return -1
        }
        defer { pingSession.invalidateAndCancel() }

        // Warmup once to avoid counting cold-start jitter.
        let warmupTimeout = max(900, min(1800, timeoutMs / 3))
        _ = measureHTTPThroughSocks(session: pingSession, timeoutMs: warmupTimeout)

        let startedAt = Date()
        var remaining = timeoutMs
        var bestLatency = -1
        var attempts = 0
        while remaining > 0 && attempts < 2 {
            if !proc.isRunning {
                return -1
            }
            let attemptTimeout = min(remaining, 3000)
            let latency = measureHTTPThroughSocks(session: pingSession, timeoutMs: attemptTimeout)
            if latency >= 0 {
                if bestLatency < 0 || latency < bestLatency {
                    bestLatency = latency
                }
            }
            attempts += 1
            usleep(120_000)
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            remaining = timeoutMs - elapsed
        }
        return bestLatency
    }

    private func buildPingConfig(link: String, runtimeEngine: String, proxyPort: Int) -> String? {
        if runtimeEngine == "xray" {
            guard var outbound = XrayConfigBuilder.parseOutbound(link) else { return nil }
            outbound["tag"] = "proxy"
            outbound.removeValue(forKey: "mux")

            let config: [String: Any] = [
                "log": ["loglevel": debugMode ? "debug" : "warning"],
                "inbounds": [[
                    "tag": "socks",
                    "protocol": "socks",
                    "listen": "127.0.0.1",
                    "port": proxyPort,
                    "settings": [
                        "udp": true,
                        "auth": "noauth"
                    ]
                ]],
                "outbounds": [
                    outbound,
                    [
                        "tag": "direct",
                        "protocol": "freedom",
                        "settings": ["domainStrategy": "UseIP"]
                    ] as [String: Any],
                    [
                        "tag": "block",
                        "protocol": "blackhole",
                        "settings": ["response": ["type": "http"]]
                    ] as [String: Any]
                ],
                "routing": [
                    "domainStrategy": "AsIs",
                    "rules": [[
                        "type": "field",
                        "inboundTag": ["socks"],
                        "outboundTag": "proxy"
                    ]]
                ]
            ]
            return jsonString(config)
        }

        guard var outbound = ConfigBuilder.parseOutbound(link) else { return nil }
        outbound["tag"] = "proxy"
        outbound.removeValue(forKey: "multiplex")

        let config: [String: Any] = [
            "log": ["level": debugMode ? "debug" : "warn", "timestamp": true],
            "inbounds": [[
                "type": "mixed",
                "tag": "mixed-in",
                "listen": "127.0.0.1",
                "listen_port": proxyPort
            ]],
            "outbounds": [
                outbound,
                ["type": "direct", "tag": "direct"]
            ],
            "route": [
                "auto_detect_interface": true,
                "final": "proxy"
            ]
        ]
        return jsonString(config)
    }

    private func jsonString(_ value: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func reservePingPort() -> Int? {
        let start = Int.random(in: 20000...50000)
        let port = findAvailablePort(from: start)
        return port > 0 ? port : nil
    }

    private func launchPingCore(runtimeEngine: String, configPath: String) -> Process? {
        let proc = Process()
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        do {
            if runtimeEngine == "xray" {
                guard let binaryPath = XrayProcess.shared.getBinaryPath() else { return nil }
                proc.executableURL = URL(fileURLWithPath: binaryPath)
                proc.arguments = ["run", "-c", configPath]
                var env = ProcessInfo.processInfo.environment
                let binaryDir = URL(fileURLWithPath: binaryPath).deletingLastPathComponent().path
                env["XRAY_LOCATION_ASSET"] = binaryDir
                proc.environment = env
            } else {
                guard let binaryPath = SingboxProcess.shared.getBinaryPath() else { return nil }
                proc.executableURL = URL(fileURLWithPath: binaryPath)
                proc.arguments = ["run", "-c", configPath, "-D", getWorkingDirectory().path]
                proc.currentDirectoryURL = getWorkingDirectory()
            }
            try proc.run()
            usleep(250_000)
            return proc.isRunning ? proc : nil
        } catch {
            return nil
        }
    }

    private func stopTempProcess(_ proc: Process) {
        if proc.isRunning {
            proc.terminate()
            let deadline = Date().addingTimeInterval(1.2)
            while proc.isRunning && Date() < deadline {
                usleep(40_000)
            }
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }
    }

    private func measureHTTPThroughSocks(proxyPort: Int, timeoutMs: Int) -> Int {
        guard let session = makeSocksPingSession(proxyPort: proxyPort, timeoutMs: timeoutMs) else {
            return -1
        }
        defer { session.invalidateAndCancel() }
        return measureHTTPThroughSocks(session: session, timeoutMs: timeoutMs)
    }

    private func makeSocksPingSession(proxyPort: Int, timeoutMs: Int) -> URLSession? {
        guard URL(string: pingTestUrl) != nil else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = max(1.0, Double(timeoutMs) / 1000.0)
        config.timeoutIntervalForResource = max(1.0, Double(timeoutMs) / 1000.0)
        config.connectionProxyDictionary = [
            kCFNetworkProxiesSOCKSEnable as String: true,
            kCFNetworkProxiesSOCKSProxy as String: "127.0.0.1",
            kCFNetworkProxiesSOCKSPort as String: proxyPort
        ]
        return URLSession(configuration: config)
    }

    private func measureHTTPThroughSocks(session: URLSession, timeoutMs: Int) -> Int {
        guard let url = URL(string: pingTestUrl) else { return -1 }
        let sem = DispatchSemaphore(value: 0)
        var latency = -1
        let start = CFAbsoluteTimeGetCurrent()
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: max(1.0, Double(timeoutMs) / 1000.0))

        session.dataTask(with: request) { _, response, error in
            defer { sem.signal() }
            if error != nil { return }
            if let http = response as? HTTPURLResponse, (http.statusCode == 200 || http.statusCode == 204) {
                latency = max(1, Int((CFAbsoluteTimeGetCurrent() - start) * 1000))
            }
        }.resume()

        let wait = sem.wait(timeout: .now() + .milliseconds(timeoutMs))
        return wait == .success ? latency : -1
    }

    private func waitForLocalProxyReady(port: Int, timeoutMs: Int) -> Bool {
        let deadline = Date().addingTimeInterval(Double(max(300, timeoutMs)) / 1000.0)
        while Date() < deadline {
            if canConnectLocalPort(port: port, timeoutMs: 220) {
                return true
            }
            usleep(60_000)
        }
        return false
    }

    private func canConnectLocalPort(port: Int, timeoutMs: Int) -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(max(1, min(65535, port)))) else {
            return false
        }
        let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var settled = false
        var success = false

        connection.stateUpdateHandler = { state in
            lock.lock()
            defer { lock.unlock() }
            if settled { return }
            switch state {
            case .ready:
                success = true
                settled = true
                semaphore.signal()
            case .failed, .cancelled:
                settled = true
                semaphore.signal()
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue.global(qos: .utility))
        let waitResult = semaphore.wait(timeout: .now() + .milliseconds(max(80, timeoutMs)))
        connection.cancel()
        if waitResult == .timedOut {
            return false
        }
        return success
    }

    // MARK: - System Proxy

    private func enableSystemProxy(port: Int) {
        let host = "127.0.0.1"
        let services = getActiveNetworkServices()
        appendCoreLog("Setting system proxy on services: \(services)", source: "proxy")
        for service in services {
            runNetworkSetup(["-setwebproxy", service, host, "\(port)"])
            runNetworkSetup(["-setsecurewebproxy", service, host, "\(port)"])
            runNetworkSetup(["-setsocksfirewallproxy", service, host, "\(port)"])
            runNetworkSetup(["-setwebproxystate", service, "on"])
            runNetworkSetup(["-setsecurewebproxystate", service, "on"])
            runNetworkSetup(["-setsocksfirewallproxystate", service, "on"])
        }
    }

    private func disableSystemProxy() {
        let services = getActiveNetworkServices()
        for service in services {
            runNetworkSetup(["-setwebproxystate", service, "off"])
            runNetworkSetup(["-setsecurewebproxystate", service, "off"])
            runNetworkSetup(["-setsocksfirewallproxystate", service, "off"])
        }
    }

    @discardableResult
    private func runNetworkSetup(_ args: [String]) -> Bool {
        do {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            task.arguments = args
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func getActiveNetworkServices() -> [String] {
        do {
            let task = Process()
            let pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            task.arguments = ["-listallnetworkservices"]
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return ["Wi-Fi"] }

            var services: [String] = []
            for line in output.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed.hasPrefix("An asterisk") || trimmed.hasPrefix("*") {
                    continue
                }

                let checkTask = Process()
                let checkPipe = Pipe()
                checkTask.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
                checkTask.arguments = ["-getinfo", trimmed]
                checkTask.standardOutput = checkPipe
                checkTask.standardError = FileHandle.nullDevice
                try checkTask.run()
                checkTask.waitUntilExit()

                let info = String(data: checkPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if info.contains("IP address:") && !info.contains("IP address: none") {
                    services.append(trimmed)
                }
            }
            return services.isEmpty ? ["Wi-Fi"] : services
        } catch {
            return ["Wi-Fi"]
        }
    }

    private func getProxyPort(for engine: String) -> Int {
        if let data = configOptions.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if engine == "xray" {
                return json["socks-port"] as? Int ?? 10808
            }
            return json["mixed-port"] as? Int ?? 2080
        }
        return engine == "xray" ? 10808 : 2080
    }

    private func getHttpProxyPort(for engine: String) -> Int {
        if let data = configOptions.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if engine == "xray" {
                return json["http-port"] as? Int ?? 10809
            }
            return json["mixed-port"] as? Int ?? 2080
        }
        return engine == "xray" ? 10809 : 2080
    }

    private func getXrayApiPort() -> Int {
        if let data = configOptions.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json["xray-api-port"] as? Int ?? 10085
        }
        return 10085
    }

    private func getClashApiPort() -> Int {
        if let data = configOptions.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json["clash-api-port"] as? Int ?? 9090
        }
        return 9090
    }

    // MARK: - Stats

    private func startStatsTimer() {
        stopStatsTimer()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            self.updateStats()
        }
    }

    private func stopStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = nil
    }

    private func updateStats() {
        guard isRunning else { return }

        if activeRuntimeEngine == "singbox" {
            pollSingboxStats()
        } else {
            pollXrayStats()
        }
    }

    private func pollSingboxStats() {
        let clashApiPort = getClashApiPort()
        guard let url = URL(string: "http://127.0.0.1:\(clashApiPort)/connections") else { return }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: config)

        session.dataTask(with: url) { data, _, error in
            guard error == nil,
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }

            let totalUpload = json["uploadTotal"] as? Int64 ?? 0
            let totalDownload = json["downloadTotal"] as? Int64 ?? 0

            let upPerSec = max(0, totalUpload - self.lastSingboxUpload)
            let downPerSec = max(0, totalDownload - self.lastSingboxDownload)

            self.lastSingboxUpload = totalUpload
            self.lastSingboxDownload = totalDownload
            self.totalUploadTraffic = totalUpload
            self.totalDownloadTraffic = totalDownload

            DispatchQueue.main.async {
                self.statsEventSink?([
                    "connections-in": 0,
                    "connections-out": 0,
                    "uplink": upPerSec,
                    "downlink": downPerSec,
                    "uplink-total": totalUpload,
                    "downlink-total": totalDownload
                ])
            }
        }.resume()
    }

    private func pollXrayStats() {
        guard let stats = XrayProcess.shared.queryTrafficStats(apiServer: "127.0.0.1:\(getXrayApiPort())") else {
            return
        }

        let upPerSec = max(0, stats.upload - lastXrayUpload)
        let downPerSec = max(0, stats.download - lastXrayDownload)

        lastXrayUpload = stats.upload
        lastXrayDownload = stats.download
        totalUploadTraffic = stats.upload
        totalDownloadTraffic = stats.download

        DispatchQueue.main.async {
            self.statsEventSink?([
                "connections-in": 0,
                "connections-out": 0,
                "uplink": upPerSec,
                "downlink": downPerSec,
                "uplink-total": stats.upload,
                "downlink-total": stats.download
            ])
        }
    }

    private func resetTrafficCounters() {
        totalUploadTraffic = 0
        totalDownloadTraffic = 0
        resetRateCounters()
    }

    private func resetRateCounters() {
        lastSingboxUpload = 0
        lastSingboxDownload = 0
        lastXrayUpload = 0
        lastXrayDownload = 0
    }

    // MARK: - Logs

    private func bindCoreLogCallbacks() {
        XrayProcess.shared.onLog = { [weak self] line in
            self?.appendCoreLog(line, source: "xray")
        }
        SingboxProcess.shared.onLog = { [weak self] line in
            self?.appendCoreLog(line, source: "singbox")
        }
    }

    private func appendCoreLog(_ line: String, source: String) {
        let clean = sanitizeLogLine(line)
        guard !clean.isEmpty else { return }

        let final = "[\(source)] \(clean)"

        logBufferLock.lock()
        if logBuffer.count >= Self.maxLogLines {
            logBuffer.removeFirst(logBuffer.count - Self.maxLogLines + 1)
        }
        logBuffer.append(final)
        logBufferLock.unlock()

        DispatchQueue.main.async {
            self.logsEventSink?(["message": final])
        }
    }

    private func clearLogBuffer() {
        logBufferLock.lock()
        logBuffer.removeAll(keepingCapacity: false)
        logBufferLock.unlock()
        DispatchQueue.main.async {
            self.logsEventSink?(["cleared": true])
        }
    }

    private func logSnapshot() -> [String] {
        logBufferLock.lock()
        let snapshot = logBuffer
        logBufferLock.unlock()
        return snapshot
    }

    private func sanitizeLogLine(_ line: String) -> String {
        line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{0}", with: "")
    }

    // MARK: - Helpers

    private func buildConfigForLink(_ link: String) throws -> (config: String, runtimeEngine: String) {
        let runtimeEngine = CoreCompatibility.resolveEngineForLink(preferredEngine: coreEngine, link: link)
        if runtimeEngine == "xray" {
            let config = try xrayConfigBuilder.buildConfig(from: link, proxyOnly: true)
            return (config, "xray")
        }
        let config = try singboxConfigBuilder.buildConfig(from: link)
        return (config, "singbox")
    }

    private func parsePingTimeout(_ value: Any?) -> Int {
        let raw = (value as? NSNumber)?.intValue ?? Self.defaultPingTimeoutMs
        return max(Self.minPingTimeoutMs, min(Self.maxPingTimeoutMs, raw))
    }

    private func paddedBase64(_ str: String) -> String {
        var s = str.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder > 0 {
            s += String(repeating: "=", count: 4 - remainder)
        }
        return s
    }

    private func ensureCoreBinariesPrepared() {
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        let coreDir = appSupport.appendingPathComponent("v2ray_box/cores", isDirectory: true)
        do {
            try fileManager.createDirectory(at: coreDir, withIntermediateDirectories: true)
        } catch {
            appendCoreLog("Failed to create core dir: \(error.localizedDescription)", source: "setup")
            return
        }

        _ = ensureBinary("xray", in: coreDir)
        _ = ensureBinary("sing-box", in: coreDir)
    }

    private func ensureBinary(_ binaryName: String, in targetDir: URL) -> Bool {
        let fileManager = FileManager.default
        let destination = targetDir.appendingPathComponent(binaryName)

        if fileManager.fileExists(atPath: destination.path) {
            do {
                try fileManager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: destination.path)
            } catch {
                appendCoreLog("chmod failed for \(binaryName): \(error.localizedDescription)", source: "setup")
            }
            return true
        }

        for source in candidateBinarySources(binaryName: binaryName) where fileManager.fileExists(atPath: source.path) {
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: source, to: destination)
                try fileManager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: destination.path)
                appendCoreLog("Prepared \(binaryName) from \(source.path)", source: "setup")
                return true
            } catch {
                appendCoreLog("Failed to copy \(binaryName) from \(source.path): \(error.localizedDescription)", source: "setup")
            }
        }
        return false
    }

    private func candidateBinarySources(binaryName: String) -> [URL] {
        var sources: [URL] = []

        if let executablePath = Bundle.main.executablePath {
            let executableURL = URL(fileURLWithPath: executablePath)
            sources.append(executableURL.deletingLastPathComponent().appendingPathComponent("../Frameworks/\(binaryName)").standardizedFileURL)
            sources.append(executableURL.deletingLastPathComponent().appendingPathComponent("../Resources/\(binaryName)").standardizedFileURL)
        }
        if let resourcePath = Bundle.main.resourcePath {
            let resourceURL = URL(fileURLWithPath: resourcePath, isDirectory: true)
            sources.append(resourceURL.appendingPathComponent("../Frameworks/\(binaryName)").standardizedFileURL)
            sources.append(resourceURL.appendingPathComponent(binaryName).standardizedFileURL)
        }

        let pluginBundle = Bundle(for: type(of: self))
        if let pluginResourcePath = pluginBundle.resourcePath {
            let pluginResourceURL = URL(fileURLWithPath: pluginResourcePath, isDirectory: true)
            sources.append(pluginResourceURL.appendingPathComponent("../Frameworks/\(binaryName)").standardizedFileURL)
            sources.append(pluginResourceURL.appendingPathComponent(binaryName).standardizedFileURL)
        }

        let cwd = FileManager.default.currentDirectoryPath
        sources.append(URL(fileURLWithPath: cwd).appendingPathComponent("macos/Frameworks/\(binaryName)").standardizedFileURL)
        sources.append(URL(fileURLWithPath: cwd).appendingPathComponent("example/macos/Frameworks/\(binaryName)").standardizedFileURL)

        var probe = Bundle.main.bundleURL
        for _ in 0..<10 {
            probe = probe.deletingLastPathComponent()
            sources.append(probe.appendingPathComponent("macos/Frameworks/\(binaryName)").standardizedFileURL)
            sources.append(probe.appendingPathComponent("example/macos/Frameworks/\(binaryName)").standardizedFileURL)
        }

        return uniqueURLs(sources)
    }

    private func uniqueURLs(_ values: [URL]) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        for value in values {
            let key = value.path
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(value)
        }
        return out
    }

    // MARK: - Get Active Config

    private func getActiveConfig(result: @escaping FlutterResult) {
        let configPath = getWorkingDirectory().appendingPathComponent("profiles/active_config.json")
        if let content = try? String(contentsOf: configPath, encoding: .utf8) {
            result(content)
        } else {
            result("")
        }
    }

    // MARK: - Format Bytes (local)

    private func formatBytesLocal(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 { return "\(bytes) B" }
        return String(format: "%.2f %@", value, units[unitIndex])
    }

    // MARK: - Find Available Port

    private func findAvailablePort(from startPort: Int) -> Int {
        for port in startPort..<65535 {
            let socketFD = socket(AF_INET, SOCK_STREAM, 0)
            guard socketFD >= 0 else { continue }
            defer { close(socketFD) }

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port).bigEndian
            addr.sin_addr.s_addr = INADDR_ANY

            let bindResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bindResult == 0 { return port }
        }
        return -1
    }

    private func getBaseDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("V2rayBox", isDirectory: true)
    }

    private func getWorkingDirectory() -> URL {
        getBaseDirectory().appendingPathComponent("working", isDirectory: true)
    }

    private func getTempDirectory() -> URL {
        getBaseDirectory().appendingPathComponent("temp", isDirectory: true)
    }

    // MARK: - Event Sinks

    func setStatusEventSink(_ sink: FlutterEventSink?) {
        statusEventSink = sink
        if sink != nil {
            sink?(["status": isRunning ? "Started" : "Stopped"])
        }
    }

    func setAlertsEventSink(_ sink: FlutterEventSink?) {
        alertsEventSink = sink
    }

    func setStatsEventSink(_ sink: FlutterEventSink?) {
        statsEventSink = sink
        if sink != nil {
            startStatsTimer()
        } else {
            stopStatsTimer()
        }
    }

    func setPingEventSink(_ sink: FlutterEventSink?) {
        pingEventSink = sink
    }

    func setLogsEventSink(_ sink: FlutterEventSink?) {
        logsEventSink = sink
    }
}

// MARK: - Stream Handlers

class StatusStreamHandler: NSObject, FlutterStreamHandler {
    weak var plugin: V2rayBoxPlugin?

    init(plugin: V2rayBoxPlugin) {
        self.plugin = plugin
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        plugin?.setStatusEventSink(events)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        plugin?.setStatusEventSink(nil)
        return nil
    }
}

class AlertsStreamHandler: NSObject, FlutterStreamHandler {
    weak var plugin: V2rayBoxPlugin?

    init(plugin: V2rayBoxPlugin) {
        self.plugin = plugin
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        plugin?.setAlertsEventSink(events)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        plugin?.setAlertsEventSink(nil)
        return nil
    }
}

class StatsStreamHandler: NSObject, FlutterStreamHandler {
    weak var plugin: V2rayBoxPlugin?

    init(plugin: V2rayBoxPlugin) {
        self.plugin = plugin
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        plugin?.setStatsEventSink(events)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        plugin?.setStatsEventSink(nil)
        return nil
    }
}

class PingStreamHandler: NSObject, FlutterStreamHandler {
    weak var plugin: V2rayBoxPlugin?

    init(plugin: V2rayBoxPlugin) {
        self.plugin = plugin
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        plugin?.setPingEventSink(events)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        plugin?.setPingEventSink(nil)
        return nil
    }
}

class LogsStreamHandler: NSObject, FlutterStreamHandler {
    weak var plugin: V2rayBoxPlugin?

    init(plugin: V2rayBoxPlugin) {
        self.plugin = plugin
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        plugin?.setLogsEventSink(events)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        plugin?.setLogsEventSink(nil)
        return nil
    }
}
