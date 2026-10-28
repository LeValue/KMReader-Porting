import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val signingFile = rootProject.file("key.properties")
val previewBuild = providers.gradleProperty("kmreaderPreview").orNull == "true"
val releaseKeys = Properties()
if (signingFile.exists()) {
    signingFile.inputStream().use { releaseKeys.load(it) }
}

android {
    buildFeatures { resValues = true }
    namespace = "dev.levalue.kmreader"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.levalue.kmreader"
        if (previewBuild) applicationIdSuffix = ".preview"
        resValue("string", "app_name", if (previewBuild) "KMReader Preview" else "KMReader")
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

    signingConfigs {
        if (signingFile.exists()) {
            create("release") {
                storeFile = file(requireNotNull(releaseKeys.getProperty("storeFile")))
                storePassword = requireNotNull(releaseKeys.getProperty("storePassword"))
                keyAlias = requireNotNull(releaseKeys.getProperty("keyAlias"))
                keyPassword = requireNotNull(releaseKeys.getProperty("keyPassword"))
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (signingFile.exists()) signingConfigs.getByName("release") else null
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

// On-device OCR: models are bundled so downloaded comics work offline.
dependencies {
    implementation("androidx.exifinterface:exifinterface:1.4.1")
    implementation("com.google.mlkit:text-recognition:16.0.1")
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")
    implementation("com.google.mlkit:text-recognition-japanese:16.0.1")
    implementation("com.google.mlkit:text-recognition-korean:16.0.1")
    implementation("com.google.mlkit:text-recognition-devanagari:16.0.1")
}
