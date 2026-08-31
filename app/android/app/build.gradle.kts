import java.io.FileInputStream
import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Load signing material from app/android/key.properties when present. The file
// is gitignored; CI populates it via the setup-android-signing composite action.
// When the file (or a flavor's section) is missing, the corresponding signing
// config is not created and the flavor falls back to debug signing so local
// `flutter run --release` still works.
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) FileInputStream(f).use { load(it) }
}
fun hasKey(key: String) = keystoreProperties.getProperty(key)?.isNotBlank() == true

android {
    namespace = "loonyb.in.jeeves"
    // Ahead of flutter.compileSdkVersion (36 on Flutter 3.44.1) because
    // flutter_secure_storage 11 compiles against 37 and AGP 9 enforces the
    // plugin's floor at checkAarMetadata. Drop back to flutter.compileSdkVersion
    // once the pinned Flutter defaults to 37 or higher.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    // AGP 9 defaults resValues off; the dev flavor names itself with resValue().
    buildFeatures {
        resValues = true
    }

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "loonyb.in.jeeves"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Each signing config requires all four properties. If only some are set
    // in a hand-edited local key.properties, fail fast here instead of letting
    // AGP raise a less-obvious null-keystore error at signing time.
    signingConfigs {
        if (hasKey("releaseStoreFile") && hasKey("releaseStorePassword") &&
            hasKey("releaseKeyAlias") && hasKey("releaseKeyPassword")) {
            create("release") {
                storeFile = rootProject.file(keystoreProperties.getProperty("releaseStoreFile"))
                storePassword = keystoreProperties.getProperty("releaseStorePassword")
                keyAlias = keystoreProperties.getProperty("releaseKeyAlias")
                keyPassword = keystoreProperties.getProperty("releaseKeyPassword")
            }
        }
        if (hasKey("devStoreFile") && hasKey("devStorePassword") &&
            hasKey("devKeyAlias") && hasKey("devKeyPassword")) {
            create("devRelease") {
                storeFile = rootProject.file(keystoreProperties.getProperty("devStoreFile"))
                storePassword = keystoreProperties.getProperty("devStorePassword")
                keyAlias = keystoreProperties.getProperty("devKeyAlias")
                keyPassword = keystoreProperties.getProperty("devKeyPassword")
            }
        }
    }

    flavorDimensions += "environment"

    productFlavors {
        create("production") {
            dimension = "environment"
            // Production-flavor signing comes from the project release key when
            // key.properties is configured; otherwise we fall back to the debug
            // keystore so unconfigured local builds still succeed.
            signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug")
        }
        create("dev") {
            dimension = "environment"
            applicationIdSuffix = ".dev"
            resValue("string", "app_name", "Jeeves dev")
            // Dev-flavor PR/profile builds use a separate keystore so a leaked
            // dev key doesn't endanger production. Same debug fallback applies.
            signingConfig = signingConfigs.findByName("devRelease")
                ?: signingConfigs.getByName("debug")
        }
    }

    // signingConfig is selected per product flavor above (so release, profile
    // and any other non-debug build types all pick up the flavor's key). The
    // release block is kept so AGP knows this build type exists, but no
    // explicit signingConfig is required here.
    buildTypes {
        release {
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    // Mobile Wallet Adapter client — lets SWS sign-in work with any MWA-compatible
    // Solana wallet app installed on the device (Phantom, Solflare, etc.).
    implementation("com.solanamobile:mobile-wallet-adapter-clientlib-ktx:2.2.0")
}

flutter {
    source = "../.."
}
