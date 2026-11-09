# AirEngine update: setup checklist

**None of this was compiled or run.** The build sandbox could not reach the Dart/Flutter SDK.
Run `flutter pub get`, `flutter analyze` and `flutter test` first, and send me any error text.

## 1. Files

Copy the contents of `lib/` and `test/` into your project (keep the folder structure) and replace `pubspec.yaml`.

**Delete** `lib/storage_service.dart` (or wherever it lives). `AppRepository` replaces it and nothing imports it any more.

New: `app_controller.dart`, `settings_screen.dart`, `support_resources_screen.dart`, `logic/`, `services/`, `utils/`, `widgets/app_lock_gate.dart`, `widgets/export_sheet.dart`, `models/app_settings.dart`.
Changed: `main.dart`, `breath_test_screen.dart`, `onboarding_screen.dart`, `models/breath_log.dart`, `models/user_profile.dart`, `repositories/app_repository.dart`, `widgets/milestone_progress_card.dart`.
Included unchanged for completeness: `breath_audio_service.dart`, `models/medical_milestone_model.dart`.

Then: `flutter pub get`, `flutter analyze`, `flutter test`.

## 2. Android

**`android/app/build.gradle(.kts)`** (needed by flutter_local_notifications)
```kotlin
android {
    compileSdk = 35            // or higher
    defaultConfig {
        minSdk = 23            // the audio recorder needs 23 or higher
    }
    compileOptions {
        isCoreLibraryDesugaringEnabled = true
    }
}
dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
```
(Groovy build files: `coreLibraryDesugaringEnabled true` and `coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'`.)

**`android/app/src/main/AndroidManifest.xml`**, inside `<manifest>`:
```xml
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
<uses-permission android:name="android.permission.VIBRATE"/>
<uses-permission android:name="android.permission.USE_BIOMETRIC"/>
```
Inside `<application>`:
```xml
<receiver android:exported="false"
    android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver"/>
<receiver android:exported="false"
    android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver">
    <intent-filter>
        <action android:name="android.intent.action.BOOT_COMPLETED"/>
        <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
        <action android:name="android.intent.action.QUICKBOOT_POWERON"/>
        <action android:name="com.htc.intent.action.QUICKBOOT_POWERON"/>
    </intent-filter>
</receiver>
```
Optional, only needed if you later call `canLaunchUrl` (the support screen does not):
```xml
<queries>
    <intent><action android:name="android.intent.action.VIEW"/><data android:scheme="https"/></intent>
    <intent><action android:name="android.intent.action.VIEW"/><data android:scheme="tel"/></intent>
</queries>
```

**`MainActivity`** (local_auth needs a FragmentActivity): in `MainActivity.kt` use
```kotlin
import io.flutter.embedding.android.FlutterFragmentActivity
class MainActivity : FlutterFragmentActivity()
```
If the biometric prompt crashes, make the `LaunchTheme` / `NormalTheme` in `res/values/styles.xml`
(and `values-night`) inherit from `Theme.AppCompat.DayNight.NoActionBar` instead of `@android:style/Theme.Light...`.

If your project already has some of these permissions or settings (the microphone and location ones from before), keep one copy and merge, rather than adding duplicates.

## 3. iOS (`ios/Runner/Info.plist`)
Building for iOS needs a Mac with Xcode. In Xcode, set the minimum iOS version to 13.0 or higher
(Runner target → General → Minimum Deployments), and run `cd ios && pod install` after `flutter pub get`.

```xml
<key>NSMicrophoneUsageDescription</key>
<string>AirEngine listens to your exhale to measure how long you can blow.</string>
<key>NSLocationWhenInUseUsageDescription</key>
<string>Optional: saves where a craving happened, only on this phone, only if you turn it on in Settings.</string>
<key>NSFaceIDUsageDescription</key>
<string>Unlock AirEngine with Face ID.</string>
```
`ios/Runner/AppDelegate.swift`, inside `didFinishLaunchingWithOptions`, before the `return`:
```swift
if #available(iOS 10.0, *) {
  UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
}
```

## 4. Behaviour changes you will notice

- **Location is off by default.** Enable it in Settings. "Delete all saved locations" removes existing coordinates.
  Exports leave location out unless you tick the box (CSV only), and then round it to about 1 km.
- **Slip-ups now count** relapse entries *and* tests labelled "After I smoked". Secondhand-smoke tests never count.
- **Times are stored in UTC** and shown in the phone's current time zone. Old entries without a zone are read as local time.
- **Backups** contain profiles and logs, not settings. Restore offers Merge (adds what is missing) or Replace.
- **App lock** asks for fingerprint/face/phone PIN; it re-locks after 20 seconds in the background.
  Turning it on requires one successful unlock first, so you cannot lock yourself out.
- **Reminders** use inexact alarms, so a daily reminder can arrive a few minutes late. No special permission is needed.
- **Not done (as agreed):** encrypted storage / Drift, and dark mode. Data is still in SharedPreferences, unencrypted.
- **Quitline numbers** on the support screen were written from memory. Check them against the official sites before release.
