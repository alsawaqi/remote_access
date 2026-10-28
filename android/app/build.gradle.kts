import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------------------------------------------------------------------------
// Release signing
//
// Release builds are signed ONLY with the owner's release keystore, described
// by android/key.properties (gitignored; see android/key.properties.example and
// the "Release signing" section of REMOTE_ACCESS_SETUP.md). There is
// deliberately NO fallback to the debug key: a debug-signed release could be
// replaced by anyone holding the (public) debug key, and a kiosk fleet that was
// installed with one key cannot be upgraded with another.
//
// Debug and profile builds are unaffected and keep using the debug key.
// ---------------------------------------------------------------------------
val keystorePropertiesFile: File = rootProject.file("key.properties")
val keystoreProperties = Properties()
val requiredSigningKeys = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")

val releaseSigningProblem: String? = run {
    if (!keystorePropertiesFile.exists()) {
        return@run "android/key.properties was not found."
    }
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
    val missing = requiredSigningKeys.filter { keystoreProperties.getProperty(it).isNullOrBlank() }
    if (missing.isNotEmpty()) {
        return@run "android/key.properties is missing: ${missing.joinToString(", ")}."
    }
    val store = file(keystoreProperties.getProperty("storeFile"))
    if (!store.isFile) {
        return@run "The keystore named by storeFile in android/key.properties does not exist: ${store.path}"
    }
    null
}

val releaseSigningHelp = """
    |
    |RELEASE SIGNING IS NOT CONFIGURED - refusing to build a release APK.
    |${releaseSigningProblem ?: ""}
    |
    |Release builds are never signed with the debug key. To configure signing:
    |  1. Create (once) a release keystore OUTSIDE this repository, e.g.
    |       keytool -genkeypair -v -keystore <path-outside-repo>/remote-access-release.jks \
    |         -keyalg RSA -keysize 4096 -validity 10000 -alias remote-access
    |  2. Copy android/key.properties.example to android/key.properties and fill in
    |     storeFile (absolute path to the keystore), storePassword, keyAlias, keyPassword.
    |     android/key.properties is gitignored - never commit it or the keystore.
    |  3. Re-run: flutter build apk --release
    |
    |See "Release signing" in REMOTE_ACCESS_SETUP.md.
    |""".trimMargin()

android {
    namespace = "net.mithqal.remoteaccess"
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
        // Final application id. Changing it later means a NEW app on every kiosk
        // (and re-running provisioning/setup-remote-access.sh), so keep it fixed.
        applicationId = "net.mithqal.remoteaccess"
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

    signingConfigs {
        if (releaseSigningProblem == null) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Only ever the owner's release key. When it is not configured the
            // release build is stopped below with an explanation (never debug-signed).
            signingConfig =
                if (releaseSigningProblem == null) signingConfigs.getByName("release") else null
        }
    }
}

// Fail any release build (apk or app bundle) up front when signing is not
// configured. Debug/profile builds never run preReleaseBuild, so they are unaffected.
if (releaseSigningProblem != null) {
    val message = releaseSigningHelp
    tasks.matching { it.name == "preReleaseBuild" }.configureEach {
        doFirst { throw GradleException(message) }
    }
}

flutter {
    source = "../.."
}
