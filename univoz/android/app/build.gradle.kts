plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.univoz"
    // Fijo en 36 (no flutter.compileSdkVersion, que aquí resuelve a 33):
    // share_plus y varias libs de androidx que llegan vía senas_core piden
    // compileSdk >= 34. senas_core mismo ya usa 36 por el mismo motivo.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.univoz"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // MediaPipe (reconocimiento de señas) requiere API 21+.
        minSdk = maxOf(flutter.minSdkVersion, 21)
        targetSdk = flutter.targetSdkVersion
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

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // MediaPipe: motor de reconocimiento de manos/cuerpo (ver
    // senas_core/INTEGRACION.md y
    // android/app/src/main/kotlin/LandmarkEngine.kt).
    implementation("com.google.mediapipe:tasks-vision:1.0.0")

    // CameraX: captura de video para el reconocedor de señas.
    implementation("androidx.camera:camera-core:1.3.0")
    implementation("androidx.camera:camera-camera2:1.3.0")
    implementation("androidx.camera:camera-lifecycle:1.3.0")
    implementation("androidx.camera:camera-view:1.3.0")

    // Lifecycle: LandmarkPlugin necesita un LifecycleOwner para CameraX.
    implementation("androidx.lifecycle:lifecycle-process:2.6.1")
    implementation("androidx.lifecycle:lifecycle-runtime:2.6.1")
    implementation("androidx.lifecycle:lifecycle-common:2.6.1")

    // Requerido por com.google.mediapipe:tasks-vision.
    implementation("com.google.guava:guava:30.1-android")
}
