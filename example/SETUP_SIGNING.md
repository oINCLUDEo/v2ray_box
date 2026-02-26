# Apple Signing & Team Setup Guide (iOS & macOS)

This guide explains how to set up your Apple Developer Team for building the iOS and macOS example apps, both of which use a **PacketTunnel Network Extension**.

## Prerequisites

- An **Apple Developer account** (free or paid)
- A **Developer Team** — a **paid Apple Developer Program membership** is required to use Network Extension entitlements
- Xcode installed

---

## Step 1: Find Your Team ID

1. Go to [developer.apple.com/account](https://developer.apple.com/account) and sign in.
2. Navigate to **Membership Details**.
3. Your **Team ID** is a 10-character alphanumeric string (e.g. `ABCDE12345`).

---

## Step 2: Set the Team in Xcode

### macOS

1. Open the macOS workspace:
   ```bash
   open example/macos/Runner.xcworkspace
   ```

2. In the Project Navigator, select the **Runner** project.

3. For each of these targets — **Runner** and **PacketTunnel**:
   - Go to **Signing & Capabilities** tab.
   - Check **Automatically manage signing**.
   - Select your **Team** from the dropdown.

Xcode will automatically write `DEVELOPMENT_TEAM = <your-team-id>;` into `project.pbxproj`.

### iOS

1. Open the iOS workspace:
   ```bash
   open example/ios/Runner.xcworkspace
   ```

2. In the Project Navigator, select the **Runner** project.

3. For each of these targets — **Runner** and **PacketTunnel**:
   - Go to **Signing & Capabilities** tab.
   - Check **Automatically manage signing**.
   - Select your **Team** from the dropdown.

---

## Step 3: Configure Bundle Identifiers

Bundle identifiers must be unique and tied to your provisioning profiles.

### macOS

Edit `example/macos/Runner/Configs/AppInfo.xcconfig`:
```
PRODUCT_BUNDLE_IDENTIFIER = com.yourcompany.yourapp
```

The PacketTunnel extension identifier is set in `project.pbxproj` under the `PacketTunnel` target:
```
PRODUCT_BUNDLE_IDENTIFIER = com.yourcompany.yourapp.PacketTunnel
```

### iOS

Edit `example/ios/Runner/Info.plist` or set via Xcode under **General → Bundle Identifier**:
```
com.yourcompany.yourapp
```

PacketTunnel extension:
```
com.yourcompany.yourapp.PacketTunnel
```

> **Rule:** The PacketTunnel bundle ID **must** always be `<main app bundle ID>.PacketTunnel`.

---

## Step 4: Enable Network Extension Capability

The **Network Extension** capability is required for VPN/PacketTunnel mode.

For both iOS and macOS, in Xcode:
1. Select the **Runner** target → **Signing & Capabilities**.
2. Click **+ Capability** → add **Network Extensions**.
3. Enable **Packet Tunnel Provider**.
4. Repeat for the **PacketTunnel** target.

> The entitlements files already contain the required keys — you only need to do this if you create a fresh project.

---

## Step 5: Required Entitlements

The following entitlements are already configured in the project files:

### macOS (`DebugProfile.entitlements` / `Release.entitlements`)

| Entitlement | Purpose |
|---|---|
| `com.apple.security.app-sandbox` | Required for sandboxed macOS apps |
| `com.apple.security.network.client` | Outbound connections |
| `com.apple.security.network.server` | Local proxy server |
| `com.apple.developer.networking.networkextension` → `packet-tunnel-provider` | VPN tunnel |

### iOS (`Runner.entitlements`)

| Entitlement | Purpose |
|---|---|
| `com.apple.developer.networking.networkextension` → `packet-tunnel-provider` | VPN tunnel |

---

## Step 6: Build & Run

### macOS
```bash
cd example
flutter pub get
flutter run -d macos
```

### iOS
```bash
cd example
flutter pub get
flutter run -d <your-device-id>
```

Or open the respective `.xcworkspace` in Xcode and press **Run**.

---

## Troubleshooting

| Issue | Solution |
|---|---|
| *"No profiles for ... were found"* | Sign in to your Apple ID in Xcode → Settings → Accounts |
| *"Network Extension requires a paid membership"* | Free accounts cannot use VPN/Network Extension entitlements |
| *"PacketTunnel bundle ID mismatch"* | Ensure PacketTunnel ID is exactly `<main bundle ID>.PacketTunnel` |
| *"Sandbox violation"* (macOS) | Verify entitlements are linked to each target in Xcode |
| *System proxy not working* (macOS) | `proxy` mode uses `networksetup` CLI — run with appropriate user permissions |
| *VPN permission denied* (iOS) | The system will prompt on first start; user must approve in Settings |

---

## Important Notes for Contributors

- **Never commit your Team ID** to source control.
- Both `example/ios/Runner.xcodeproj/project.pbxproj` and `example/macos/Runner.xcodeproj/project.pbxproj` intentionally have `DEVELOPMENT_TEAM = "";` — each developer sets their own team locally via Xcode.
- `Pods/` and `Flutter/ephemeral/` are excluded by `.gitignore` and must not be committed.
