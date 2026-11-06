import java.util.Properties

plugins {
    id("com.android.application")
    id("com.chaquo.python")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val signingFile = rootProject.file("key.properties")
val previewBuild = providers.gradleProperty("kmreaderPreview").orNull == "true"
val epubDiagnostic = providers.gradleProperty("kmreaderEpubDiagnostic").orNull == "true"
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
        if (epubDiagnostic) applicationIdSuffix = ".epubdiagnostic"
        resValue("string", "app_name", if (epubDiagnostic) "KMReader EPUB Test" else if (previewBuild) "KMReader Preview" else "KMReader")
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        // Chaquopy needs explicit filters. Build each architecture with
        // --target-platform rather than AGP splits, which conflict with them.
        ndk {
            abiFilters.clear()
            val targets = providers.gradleProperty("target-platform").orNull
                ?: "android-arm,android-arm64,android-x64"
            abiFilters += targets.split(',').map {
                when (it) {
                    "android-arm" -> "armeabi-v7a"
                    "android-arm64" -> "arm64-v8a"
                    "android-x64" -> "x86_64"
                    else -> error("Unsupported Android platform: $it")
                }
            }
        }
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

val kindlePythonSources = layout.buildDirectory.dir("generated/kindlePython")
val prepareKindleSources by tasks.registering(Sync::class) {
    into(kindlePythonSources)
    from("../../tool/kindle_android") { include("*.py") }
    from("../../tool/kindle_personal") {
        include("__init__.py", "mapped_kfx.py", "prepare.py", "common.py")
        into("kindle_personal")
    }
}
chaquopy {
    defaultConfig {
        version = "3.11"
        buildPython(providers.gradleProperty("kindleBuildPython").orNull ?: "python3.11")
        pip {
            install("lxml==5.3.0")
            install("Pillow==11.0.0")
            install("beautifulsoup4==4.14.3")
            install("pypdf==6.21.4")
            install("defusedxml==0.7.1")
            install("kfxlib @ git+https://github.com/kafkasl/ksync.git@fc00a7b7a04badfbd61f3e42aaaa5e45e1d0cfd7#subdirectory=vendor/kfxlib")
        }
    }
    sourceSets.getByName("main") { srcDir(kindlePythonSources) }
}
tasks.configureEach {
    if (name.contains("Python")) dependsOn(prepareKindleSources)
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
