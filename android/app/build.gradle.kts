plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Persistent release signing (user request: in-place updates). CI writes
// these properties from repo secrets; without them (local dev) the release
// build falls back to the debug key as before.
val oroKeystoreFile = providers.gradleProperty("ORO_KEYSTORE_FILE").orNull

android {
    namespace = "com.ambi.gold_paper_trading"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    signingConfigs {
        if (oroKeystoreFile != null) {
            create("release") {
                storeFile = file(oroKeystoreFile)
                storePassword = providers.gradleProperty("ORO_KEYSTORE_PASSWORD").orNull
                keyAlias = providers.gradleProperty("ORO_KEY_ALIAS").orNull
                keyPassword = providers.gradleProperty("ORO_KEY_PASSWORD").orNull
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications uses java.time APIs
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.ambi.gold_paper_trading"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = if (oroKeystoreFile != null) {
                signingConfigs.getByName("release")
            } else {
                // Local builds without the keystore: debug key.
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = true
            isShrinkResources = true
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}

flutter {
    source = "../.."
}
