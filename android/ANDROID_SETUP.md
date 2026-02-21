# Android Setup Guide for V2Ray Box Plugin

Complete guide for setting up the V2Ray Box plugin for Android.

## Requirements

- **Minimum SDK**: 24 (Android 7.0)
- **Target SDK**: 36
- **Kotlin**: 2.0+
- **Gradle**: 8.0+

---

## Step 1: Add hiddify-core.aar

Download `hiddify-core.aar` from [hiddify-core releases](https://github.com/hiddify/hiddify-core/releases) and place it in:

```
your_app/android/app/libs/hiddify-core.aar
```

> **Note:** Create the `libs` folder if it doesn't exist.

---

## Step 2: Update android/app/build.gradle.kts

```kotlin
android {
    // ...
    
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

dependencies {
    implementation(fileTree(mapOf("dir" to "libs", "include" to listOf("*.jar", "*.aar"))))
}
```

If you're using Groovy (`build.gradle`):

```groovy
android {
    // ...
    
    packagingOptions {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

dependencies {
    implementation fileTree(dir: 'libs', include: ['*.jar', '*.aar'])
}
```

---

## Step 3: Add Permissions to AndroidManifest.xml

Add these permissions to `android/app/src/main/AndroidManifest.xml`:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    
    <!-- Required Permissions -->
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_SPECIAL_USE" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
    
    <!-- VPN Permission -->
    <uses-permission android:name="android.permission.BIND_VPN_SERVICE" />
    
    <!-- For per-app proxy feature -->
    <uses-permission android:name="android.permission.QUERY_ALL_PACKAGES" />
    
    <!-- Network State -->
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <uses-permission android:name="android.permission.CHANGE_NETWORK_STATE" />
    
    <application
        ...>
        
        <!-- VPN Service -->
        <service
            android:name="com.example.v2ray_box.bg.VPNService"
            android:exported="false"
            android:foregroundServiceType="specialUse"
            android:permission="android.permission.BIND_VPN_SERVICE">
            <intent-filter>
                <action android:name="android.net.VpnService" />
            </intent-filter>
            <property
                android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"
                android:value="vpn" />
        </service>
        
        <!-- Proxy Service (optional, for proxy mode) -->
        <service
            android:name="com.example.v2ray_box.bg.ProxyService"
            android:exported="false"
            android:foregroundServiceType="specialUse">
            <property
                android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"
                android:value="proxy" />
        </service>
        
    </application>
</manifest>
```

---

## Step 4: ProGuard Rules (if using minification)

Add to `android/app/proguard-rules.pro`:

```proguard
-keep class com.hiddify.** { *; }
-keep class go.** { *; }
-keep class libcore.** { *; }
```

---

## Final Project Structure

```
your_app/
├── android/
│   ├── app/
│   │   ├── libs/
│   │   │   └── hiddify-core.aar
│   │   ├── src/
│   │   │   └── main/
│   │   │       └── AndroidManifest.xml
│   │   ├── build.gradle.kts
│   │   └── proguard-rules.pro
│   └── build.gradle.kts
└── pubspec.yaml
```

---

## Troubleshooting

### VPN Permission Denied

Make sure you've added the `BIND_VPN_SERVICE` permission and declared the VPN service in AndroidManifest.xml.

**Solution:**
1. Check that the service declaration is inside `<application>` tag
2. Verify the service name matches: `com.example.v2ray_box.bg.VPNService`
3. Request VPN permission before connecting:
   ```dart
   await v2rayBox.requestVpnPermission();
   ```

---

### Notification Not Showing

Ensure `POST_NOTIFICATIONS` permission is granted (required for Android 13+).

**Solution:**
```dart
// Request notification permission (Android 13+)
import 'package:permission_handler/permission_handler.dart';

if (await Permission.notification.isDenied) {
  await Permission.notification.request();
}
```

---

### Per-App Proxy Not Working

Add `QUERY_ALL_PACKAGES` permission to query installed applications.

**Solution:**
1. Add permission to AndroidManifest.xml:
   ```xml
   <uses-permission android:name="android.permission.QUERY_ALL_PACKAGES" />
   ```
2. Note: This permission may require justification for Google Play Store submission.

---

### Traffic Stats Always Zero

The stats are only available when connected.

**Solution:**
Make sure the VPN is in `started` status before reading stats:
```dart
v2rayBox.watchStatus().listen((status) {
  if (status == VpnStatus.started) {
    // Now stats will be available
  }
});
```

---

### App Crashes on Connection

This usually happens when `hiddify-core.aar` is missing or not properly linked.

**Solution:**
1. Verify `hiddify-core.aar` exists in `android/app/libs/`
2. Run `flutter clean && flutter pub get`
3. Rebuild the app

---

### Build Error: "Cannot find symbol"

**Solution:**
1. Make sure the `implementation fileTree(...)` line is in dependencies
2. Sync Gradle files in Android Studio
3. Invalidate caches and restart Android Studio if needed

---

## Permissions Summary

| Permission | Required | Purpose |
|------------|----------|---------|
| `INTERNET` | ✅ Yes | Network access |
| `FOREGROUND_SERVICE` | ✅ Yes | Keep VPN running |
| `FOREGROUND_SERVICE_SPECIAL_USE` | ✅ Yes | VPN foreground service |
| `POST_NOTIFICATIONS` | ✅ Yes | Show VPN notification |
| `BIND_VPN_SERVICE` | ✅ Yes | Create VPN connection |
| `ACCESS_NETWORK_STATE` | ✅ Yes | Check network status |
| `CHANGE_NETWORK_STATE` | ⚠️ Recommended | Modify network settings |
| `QUERY_ALL_PACKAGES` | ⚠️ Optional | Per-app proxy feature |
| `RECEIVE_BOOT_COMPLETED` | ⚠️ Optional | Auto-start on boot |

---

## Flutter Usage Example

```dart
import 'package:v2ray_box/v2ray_box.dart';

final v2ray = V2rayBox();

// Initialize
await v2ray.initialize();

// Request VPN permission
final hasPermission = await v2ray.checkVpnPermission();
if (!hasPermission) {
  await v2ray.requestVpnPermission();
}

// Connect
await v2ray.connect('vless://...', name: 'My Server');

// Watch status
v2ray.watchStatus().listen((status) {
  print('VPN Status: $status');
});

// Watch traffic stats
v2ray.watchStats().listen((stats) {
  print('Upload: ${stats.formattedUplink}');
  print('Download: ${stats.formattedDownlink}');
});

// Disconnect
await v2ray.disconnect();
```

---

## Checklist

- [ ] `hiddify-core.aar` placed in `android/app/libs/`
- [ ] `build.gradle.kts` updated with packaging and dependencies
- [ ] All required permissions added to `AndroidManifest.xml`
- [ ] VPN service declared in `AndroidManifest.xml`
- [ ] ProGuard rules added (if using minification)
- [ ] App rebuilt after changes (`flutter clean && flutter run`)

