# iOS Setup Guide for V2Ray Box Plugin

Complete guide for setting up the V2Ray Box plugin for iOS.

## Prerequisites

- Xcode 15 or later
- iOS 15.0 minimum deployment target
- Apple Developer Account with Network Extension capability
- Physical iOS device (VPN does NOT work on Simulator)

---

## Step 1: Open Project in Xcode

```bash
cd your_flutter_project/ios
open Runner.xcworkspace
```

> ⚠️ **Important:** Always open the `.xcworkspace` file, not `.xcodeproj`

---

## Step 2: Add Network Extension Target

1. In Xcode, go to: **File → New → Target...**
2. Select **iOS**
3. Find and select **Network Extension**
4. Click **Next**
5. Configure:
   - **Product Name:** `PacketTunnel`
   - **Team:** Same team as Runner
   - **Bundle Identifier:** `{your.app.bundle.id}.PacketTunnel`
   - **Language:** Swift
   - **Provider Type:** `Packet Tunnel`
6. Click **Finish**
7. If asked "Activate scheme?" → Click **Cancel**

---

## Step 3: Configure App Groups

### For Runner Target:

1. In the Navigator on the left, click on **Runner** (blue project icon)
2. Select the **Runner** target
3. Open the **Signing & Capabilities** tab
4. Click **+ Capability**
5. Add **App Groups**
6. Click **+** and add:
   ```
   group.{your.app.bundle.id}
   ```

### For PacketTunnel Target:

1. Select the **PacketTunnel** target
2. Go to **Signing & Capabilities** tab
3. **+ Capability** → **App Groups**
4. Add the same group:
   ```
   group.{your.app.bundle.id}
   ```

---

## Step 4: Configure Network Extensions Capability

### For Runner Target:

1. Select **Runner** target
2. **+ Capability** → **Network Extensions**
3. Check **Packet Tunnel**

### For PacketTunnel Target:

1. Select **PacketTunnel** target
2. **+ Capability** → **Network Extensions**
3. Check **Packet Tunnel**

---

## Step 5: Add HiddifyCore Framework to PacketTunnel

1. Select the **PacketTunnel** target
2. Open the **General** tab
3. In **Frameworks, Libraries, and Embedded Content**:
   - Click **+**
   - Select **Add Other... → Add Files...**
   - Navigate to:
     ```
     Pods/v2ray_box/Frameworks/HiddifyCore.xcframework
     ```
   - Select it and click **Open**
4. Make sure **Embed & Sign** is selected

---

## Step 6: Add libresolv

1. Select the **PacketTunnel** target
2. Go to **General** tab
3. In **Frameworks, Libraries, and Embedded Content**:
   - Click **+**
   - Search for: `libresolv`
   - Select **libresolv.tbd** and click **Add**

---

## Step 7: Embed PacketTunnel in Runner

1. Select the **Runner** target
2. Go to **General** tab
3. Navigate to **Frameworks, Libraries, and Embedded Content**
4. Click **+**
5. Find and add **PacketTunnel.appex**
6. Set it to **Embed & Sign**

---

## Step 8: Build Phases Order (Important!)

1. Select the **Runner** target
2. Open the **Build Phases** tab
3. Find **[CP] Embed Pods Frameworks**
4. Drag it **above** **Thin Binary**

### Correct Order:
```
1. Target Dependencies
2. Run Script (flutter)
3. Compile Sources
4. Link Binary With Libraries
5. Copy Bundle Resources
6. Embed Frameworks
7. Embed App Extensions
8. [CP] Embed Pods Frameworks  ← Must be before Thin Binary
9. Thin Binary
```

---

## Step 9: PacketTunnelProvider Code

Replace the content of `PacketTunnel/PacketTunnelProvider.swift` with the following code:

```swift
import NetworkExtension
import HiddifyCore

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private var boxService: LibboxBoxService?
    private var platformInterface: TunnelPlatformInterface?
    private var config: String?
    
    // ⚠️ Replace with your App Group ID
    private let appGroupId = "group.{your.app.bundle.id}"
    
    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let configString = options?["Config"] as? String else {
            completionHandler(NSError(domain: "V2rayBox", code: -1, userInfo: [NSLocalizedDescriptionKey: "Config not provided"]))
            return
        }
        
        config = configString
        
        do {
            let fileManager = FileManager.default
            guard let sharedDir = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
                completionHandler(NSError(domain: "V2rayBox", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to get shared container"]))
                return
            }
            
            let workingDir = sharedDir.appendingPathComponent("working", isDirectory: true)
            let cacheDir = sharedDir.appendingPathComponent("Library/Caches", isDirectory: true)
            
            try fileManager.createDirectory(at: workingDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            
            let setupOptions = LibboxSetupOptions()
            setupOptions.basePath = sharedDir.path
            setupOptions.workingPath = workingDir.path
            setupOptions.tempPath = cacheDir.path
            
            var error: NSError?
            LibboxSetup(setupOptions, &error)
            if let error = error { throw error }
            
            platformInterface = TunnelPlatformInterface(tunnel: self)
            
            guard let service = LibboxNewService(config, platformInterface, &error) else {
                if let error = error { throw error }
                throw NSError(domain: "V2rayBox", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to create service"])
            }
            
            try service.start()
            boxService = service
            completionHandler(nil)
            
        } catch {
            completionHandler(error)
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        if let service = boxService {
            try? service.close()
            boxService = nil
        }
        platformInterface?.reset()
        completionHandler()
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let message = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil)
            return
        }
        if message == "stats" {
            completionHandler?("0,0".data(using: .utf8))
        } else {
            completionHandler?(nil)
        }
    }
}

// MARK: - Platform Interface

class TunnelPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol {
    private weak var tunnel: PacketTunnelProvider?
    private var networkSettings: NEPacketTunnelNetworkSettings?
    
    init(tunnel: PacketTunnelProvider) {
        self.tunnel = tunnel
        super.init()
    }
    
    func reset() { networkSettings = nil }
    
    func openTun(_ options: (any LibboxTunOptionsProtocol)?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let options = options, let ret0_ = ret0_, let tunnel = tunnel else {
            throw NSError(domain: "V2rayBox", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid parameters"])
        }
        
        let semaphore = DispatchSemaphore(value: 0)
        var resultError: Error?
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        
        if options.getAutoRoute() {
            settings.mtu = NSNumber(value: options.getMTU())
            settings.dnsSettings = NEDNSSettings(servers: ["8.8.8.8", "8.8.4.4"])
            
            var ipv4Addr: [String] = [], ipv4Mask: [String] = []
            if let iter = options.getInet4Address() {
                while iter.hasNext() {
                    if let p = iter.next() {
                        ipv4Addr.append(p.address())
                        ipv4Mask.append(p.mask())
                    }
                }
            }
            if !ipv4Addr.isEmpty {
                let ipv4 = NEIPv4Settings(addresses: ipv4Addr, subnetMasks: ipv4Mask)
                ipv4.includedRoutes = [NEIPv4Route.default()]
                settings.ipv4Settings = ipv4
            } else {
                let ipv4 = NEIPv4Settings(addresses: ["172.19.0.1"], subnetMasks: ["255.255.255.252"])
                ipv4.includedRoutes = [NEIPv4Route.default()]
                settings.ipv4Settings = ipv4
            }
            
            var ipv6Addr: [String] = [], ipv6Prefix: [NSNumber] = []
            if let iter = options.getInet6Address() {
                while iter.hasNext() {
                    if let p = iter.next() {
                        ipv6Addr.append(p.address())
                        ipv6Prefix.append(NSNumber(value: p.prefix()))
                    }
                }
            }
            if !ipv6Addr.isEmpty {
                let ipv6 = NEIPv6Settings(addresses: ipv6Addr, networkPrefixLengths: ipv6Prefix)
                ipv6.includedRoutes = [NEIPv6Route.default()]
                settings.ipv6Settings = ipv6
            }
        } else {
            settings.mtu = NSNumber(value: 9000)
            settings.dnsSettings = NEDNSSettings(servers: ["8.8.8.8"])
            let ipv4 = NEIPv4Settings(addresses: ["172.19.0.1"], subnetMasks: ["255.255.255.252"])
            ipv4.includedRoutes = [NEIPv4Route.default()]
            settings.ipv4Settings = ipv4
        }
        
        networkSettings = settings
        tunnel.setTunnelNetworkSettings(settings) { error in
            resultError = error
            semaphore.signal()
        }
        semaphore.wait()
        
        if let error = resultError { throw error }
        
        let fd = LibboxGetTunnelFileDescriptor()
        if fd != -1 {
            ret0_.pointee = fd
        } else {
            throw NSError(domain: "V2rayBox", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing file descriptor"])
        }
    }
    
    func usePlatformAutoDetectControl() -> Bool { true }
    func autoDetectControl(_ fd: Int32) throws {}
    func findConnectionOwner(_ p: Int32, sourceAddress: String?, sourcePort: Int32, destinationAddress: String?, destinationPort: Int32, ret0_: UnsafeMutablePointer<Int32>?) throws {}
    func packageName(byUid uid: Int32, error: NSErrorPointer) -> String { "" }
    func uid(byPackageName: String?, ret0_: UnsafeMutablePointer<Int32>?) throws {}
    func useProcFS() -> Bool { false }
    func writeLog(_ message: String?) { if let m = message { NSLog("[Libbox] %@", m) } }
    func usePlatformDefaultInterfaceMonitor() -> Bool { false }
    func startDefaultInterfaceMonitor(_ listener: (any LibboxInterfaceUpdateListenerProtocol)?) throws {}
    func closeDefaultInterfaceMonitor(_ listener: (any LibboxInterfaceUpdateListenerProtocol)?) throws {}
    func useGetter() -> Bool { false }
    func getInterfaces() throws -> any LibboxNetworkInterfaceIteratorProtocol { throw NSError(domain: "V2rayBox", code: -1) }
    func underNetworkExtension() -> Bool { true }
    func includeAllNetworks() -> Bool { false }
    func clearDNSCache() {
        guard let s = networkSettings, let t = tunnel else { return }
        t.reasserting = true
        t.setTunnelNetworkSettings(nil) { _ in }
        t.setTunnelNetworkSettings(s) { _ in }
        t.reasserting = false
    }
    func readWIFIState() -> LibboxWIFIState? { nil }
    func send(_ notification: LibboxNotification?) throws {}
    func getSystemProxyStatus() -> LibboxSystemProxyStatus? { LibboxSystemProxyStatus() }
    func setSystemProxyEnabled(_ isEnabled: Bool) throws {}
    func postServiceClose() {}
    func serviceReload() throws {}
}
```

---

## Step 10: Configure Entitlements

### Runner.entitlements:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.developer.networking.networkextension</key>
    <array>
        <string>packet-tunnel-provider</string>
    </array>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.{your.app.bundle.id}</string>
    </array>
</dict>
</plist>
```

### PacketTunnel.entitlements:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.developer.networking.networkextension</key>
    <array>
        <string>packet-tunnel-provider</string>
    </array>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.{your.app.bundle.id}</string>
    </array>
</dict>
</plist>
```

---

## Step 11: Configure Podfile

In your `ios/Podfile`, make sure to set:

```ruby
platform :ios, '15.0'

# ... rest of configuration
```

---

## Final Project Structure

```
YourApp/
├── Runner/
│   ├── AppDelegate.swift
│   ├── Runner.entitlements
│   └── ...
├── PacketTunnel/
│   ├── PacketTunnelProvider.swift
│   ├── PacketTunnel.entitlements
│   └── Info.plist
├── Pods/
│   └── v2ray_box/
│       └── Frameworks/
│           └── HiddifyCore.xcframework/
└── Podfile
```

---

## Troubleshooting

### Error: "Found 0 registrations"

```
nesessionmanager Found 0 registrations for {bundle.id}.PacketTunnel
```

**Solution:**
1. Make sure PacketTunnel.appex is embedded in Runner
2. Verify the Bundle Identifier is correct
3. Ensure Network Extensions capability is enabled

---

### Error: "permission denied"

```
PlatformException(START_ERROR, permission denied, null, null)
```

**Solution:**
1. Configure App Groups for both targets
2. Verify entitlements files are correct
3. Use a physical device (not Simulator)

---

### Error: Build Cycle

```
Cycle inside Runner; building could produce unreliable results
```

**Solution:**
1. Fix the Build Phases order
2. Move **[CP] Embed Pods Frameworks** before **Thin Binary**
3. Clean DerivedData:
   ```bash
   rm -rf ~/Library/Developer/Xcode/DerivedData/Runner-*
   ```

---

### Error: Linker (Undefined symbol: _res_9_*)

```
Undefined symbol: _res_9_nclose, _res_9_ninit, _res_9_nsearch
```

**Solution:**
- Add `libresolv.tbd` to the PacketTunnel target

---

### VPN Disconnects Immediately

**Check:**
1. App Group ID matches in both code and Xcode
2. Config link is valid
3. Review logs in Console.app

---

## Limitations

### iOS Simulator
- ❌ VPN does **NOT** work on Simulator
- ✅ Use Simulator only for UI development
- ✅ Always use a physical device for VPN testing

### Memory Limit
- Network Extensions have a 15MB memory limit
- You can disable this limit by passing `disableMemoryLimit: true` if needed

---

## Flutter Usage Example

```dart
import 'package:v2ray_box/v2ray_box.dart';

final v2ray = V2rayBox();

// Initialize
await v2ray.initialize();

// Connect
await v2ray.connect('vless://...', name: 'My Server');

// Watch status
v2ray.watchStatus().listen((status) {
  print('VPN Status: $status');
});

// Disconnect
await v2ray.disconnect();
```

---

## Final Checklist

- [ ] Network Extension target added
- [ ] App Groups configured for both targets
- [ ] Network Extensions capability enabled
- [ ] HiddifyCore.xcframework added to PacketTunnel
- [ ] libresolv.tbd added to PacketTunnel
- [ ] PacketTunnel.appex embedded in Runner
- [ ] Build Phases in correct order
- [ ] PacketTunnelProvider.swift has correct code
- [ ] App Group ID matches in code and Xcode
- [ ] Using physical device for testing
