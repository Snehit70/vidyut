plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.snehit.vidyut.vidyut"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.snehit.vidyut.vidyut"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // CI passes the repository-owned signing key explicitly. Keep the
        // debug fallback for local `flutter run --release` builds.
        val ciKeystorePath = providers.environmentVariable("VIDYUT_KEYSTORE_PATH").orNull
        if (ciKeystorePath != null) {
            create("ciRelease") {
                storeFile = file(ciKeystorePath)
                storePassword = providers.environmentVariable("VIDYUT_KEYSTORE_PASSWORD").orNull ?: "android"
                keyAlias = providers.environmentVariable("VIDYUT_KEY_ALIAS").orNull ?: "androiddebugkey"
                keyPassword = providers.environmentVariable("VIDYUT_KEY_PASSWORD").orNull ?: "android"
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (providers.environmentVariable("VIDYUT_KEYSTORE_PATH").orNull != null) {
                signingConfigs.getByName("ciRelease")
            } else {
                // Keep local release builds convenient when CI credentials are absent.
                signingConfigs.getByName("debug")
            }
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
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("androidx.core:core-ktx:1.15.0")
}
