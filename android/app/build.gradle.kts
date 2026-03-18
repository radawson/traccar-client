import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
    // END: FlutterFire Configuration
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val backgroundGeolocation = project(":flutter_background_geolocation")
apply { from("${backgroundGeolocation.projectDir}/background_geolocation.gradle") }

val keystoreProperties = Properties()
val localKeystorePropertiesFile = rootProject.file("key.properties")
val legacyKeystorePropertiesFile = rootProject.file("../../environment/key.properties")
val keystorePropertiesFile = when {
    localKeystorePropertiesFile.exists() -> localKeystorePropertiesFile
    legacyKeystorePropertiesFile.exists() -> legacyKeystorePropertiesFile
    else -> localKeystorePropertiesFile
}

fun resolveStoreFile(path: String): File {
    val expandedPath = if (path.startsWith("~/")) {
        System.getProperty("user.home") + path.removePrefix("~")
    } else {
        path
    }
    return file(expandedPath)
}

if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "org.traccar.client"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "org.traccar.client"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"].toString()
                keyPassword = keystoreProperties["keyPassword"].toString()
                storeFile = keystoreProperties["storeFile"]?.toString()?.let { resolveStoreFile(it) }
                storePassword = keystoreProperties["storePassword"].toString()
            }
        }
    }
    buildTypes {
        release {
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
            isShrinkResources = false
        }
    }

    lint {
        disable.add("NullSafeMutableLiveData")
    }
}

dependencies {
    implementation("org.slf4j:slf4j-api:2.0.17")
    implementation("com.github.tony19:logback-android:3.0.0")
}

flutter {
    source = "../.."
}
