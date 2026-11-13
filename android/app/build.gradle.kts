import java.util.Base64

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

fun loadDotEnvValueB64(key: String): String {
    val envFile = rootProject.file("../.env")
    if (!envFile.exists()) return ""
    for (line in envFile.readLines()) {
        val trimmed = line.trim()
        if (trimmed.isEmpty() || trimmed.startsWith("#")) continue
        val eqIdx = trimmed.indexOf('=')
        if (eqIdx <= 0) continue
        if (trimmed.substring(0, eqIdx).trim() == key) {
            var raw = trimmed.substring(eqIdx + 1).trim()
            if (raw.length >= 2 &&
                ((raw.startsWith("\"") && raw.endsWith("\"")) ||
                    (raw.startsWith("'") && raw.endsWith("'")))
            ) {
                raw = raw.substring(1, raw.length - 1)
            }
            return Base64.getEncoder().encodeToString(raw.toByteArray(Charsets.UTF_8))
        }
    }
    return ""
}

android {
    namespace = "com.example.cue_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        resValues = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.cue_mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        resValue("string", "dev_gemini_api_key_b64", "")
    }

    buildTypes {
        getByName("debug") {
            resValue("string", "dev_gemini_api_key_b64", loadDotEnvValueB64("GEMINI_API_KEY"))
        }
        release {
            resValue("string", "dev_gemini_api_key_b64", "")
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
