plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.remote_access"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.remote_access"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Remote control requires Android 11+ (foreground-service media projection rules).
        minSdk = 30
        // targetSdk is intentionally pinned to 33. Android 14 (SDK 34+) re-enforces a
        // per-session MediaProjection consent dialog that cannot be suppressed — which
        // would break UNATTENDED kiosk screen capture. Targeting 33 keeps the one-time
        // `appops PROJECT_MEDIA allow` grant effective (tap-free capture). This app is
        // side-loaded via the MDM (not Google Play), so the Play targetSdk floor does
        // not apply. See provisioning/README.md.
        targetSdk = 33
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
