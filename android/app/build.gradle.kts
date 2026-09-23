import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing (Phase 6). Secrets never live in the repository:
// android/key.properties and the keystore it points to are gitignored.
// See docs/RELEASE.md for the file format.
val releaseKeys = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.isFile) f.inputStream().use { load(it) }
}
val hasReleaseKeys = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
    .all { !releaseKeys.getProperty(it).isNullOrBlank() }

android {
    namespace = "com.safeguard.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Placeholder ID: change before publishing to Google Play.
        applicationId = "com.safeguard.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Android 7.0+: hardware-backed Keystore AES-GCM for secure storage.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Build flavours (Phase 7). `flutter run` / `flutter build` without
    // --flavor use "prod" (pubspec: flutter.default-flavor).
    //  - dev:     developer builds; separate package, installs side by side.
    //  - staging: internal QA / sideloaded beta builds; separate package.
    //  - prod:    the Play Store package (also used on Play testing tracks).
    // No flavour has different endpoints or credentials: the app has none.
    buildFeatures {
        // resValue(app_name) below; off by default in recent AGP versions.
        resValues = true
    }
    flavorDimensions += "env"
    productFlavors {
        create("dev") {
            dimension = "env"
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
            resValue("string", "app_name", "SafeGuard Dev")
        }
        create("staging") {
            dimension = "env"
            applicationIdSuffix = ".staging"
            versionNameSuffix = "-staging"
            resValue("string", "app_name", "SafeGuard Beta")
        }
        create("prod") {
            dimension = "env"
            resValue("string", "app_name", "SafeGuard")
        }
    }

    // Bundled domain lists are memory-mapped from the APK; they must be stored
    // uncompressed (they are random hashes and wouldn't compress anyway).
    androidResources {
        noCompress += "sgbl"
    }

    signingConfigs {
        if (hasReleaseKeys) {
            create("release") {
                storeFile = rootProject.file(releaseKeys.getProperty("storeFile"))
                storePassword = releaseKeys.getProperty("storePassword")
                keyAlias = releaseKeys.getProperty("keyAlias")
                keyPassword = releaseKeys.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isDebuggable = false
            // R8: shrink, optimise and obfuscate; strips Log.v/d/i calls
            // (see proguard-rules.pro). Resource shrinking drops unused ones.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Without android/key.properties the build is signed with the
            // local debug key so `flutter run --release` still works; such an
            // APK must not be distributed (Play rejects debug-signed uploads).
            signingConfig = if (hasReleaseKeys) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Pure-Kotlin engine tests (DNS parsing, rules, logging, statistics).
    testImplementation("junit:junit:4.13.2")
    // Real SQLite schema/query tests on the JVM (data/SqliteStoresTest).
    testImplementation("org.robolectric:robolectric:4.16")
}
