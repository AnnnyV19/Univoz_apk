import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Firma de release: android/key.properties (ver docs/RELEASE.md). No se versiona.
val keyPropsFile = rootProject.file("key.properties")
val keyProps = Properties().apply {
    if (keyPropsFile.exists()) keyPropsFile.inputStream().use { load(it) }
}

android {
    // El namespace (paquete de R/BuildConfig) se queda; el id que ve Android
    // y Play es applicationId.
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
        // Identidad de la app en el teléfono y en Play: no volver a cambiarla.
        applicationId = "com.univoz.app"
        // MediaPipe tasks-vision/tasks-core 1.0.0 declaran minSdk 24.
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        // Salen de pubspec.yaml (version: 0.9.0+9): Flutter los pasa aquí.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // Solo se crea si hay key.properties: debug y los tests no lo piden.
        if (keyPropsFile.exists()) {
            create("release") {
                keyAlias = keyProps.getProperty("keyAlias")
                keyPassword = keyProps.getProperty("keyPassword")
                storeFile = keyProps.getProperty("storeFile")?.let { file(it) }
                storePassword = keyProps.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
            // R8: reglas en proguard-rules.pro (MediaPipe, protobuf, plugins propios).
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

// senas_core declara sus assets (las dos VRM, los .task, el visor y las
// plantillas) para su web standalone, y Flutter los vuelve a empaquetar aquí
// como packages/senas_core/assets/...: ~68 MB duplicados. La app solo carga
// las rutas propias (assets/avatar/MODELO_UNIVOZ_v0.vrm, assets/avatar_viewer/index.html,
// assets/plantillas.json) y Kotlin lee los .task de src/main/assets, así que
// esos duplicados se quedan fuera del APK. Si algún día senas_core carga un
// asset con package:, quita esta exclusión.
tasks.withType<Copy>().matching { it.name.startsWith("copyFlutterAssets") }
    .configureEach { exclude("**/packages/senas_core/assets/**") }

// Sin llave no hay release: falla antes de compilar y dice por qué. Solo se
// evalúa cuando el grafo de tareas trae un empaquetado release, así que
// `flutter build apk --debug`, `flutter run` y los tests no la necesitan.
gradle.taskGraph.whenReady {
    val pideRelease = allTasks.any {
        it.project == project &&
            Regex("^(assemble|bundle|package)Release$").containsMatchIn(it.name)
    }
    if (pideRelease && !keyPropsFile.exists()) {
        throw GradleException("Falta android/key.properties: ver docs/RELEASE.md")
    }
    if (pideRelease) {
        // Un campo vacío o mal escrito daba un error críptico de firma al final
        // del build: se avisa aquí, con el nombre del campo.
        val faltan = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
            .filter { keyProps.getProperty(it).isNullOrBlank() }
        if (faltan.isNotEmpty()) {
            throw GradleException(
                "android/key.properties no tiene: ${faltan.joinToString(", ")}. " +
                    "Ver docs/RELEASE.md, sección 2.",
            )
        }
        val almacen = file(keyProps.getProperty("storeFile"))
        if (!almacen.exists()) {
            throw GradleException(
                "storeFile de android/key.properties no existe: $almacen. " +
                    "Ver docs/RELEASE.md, sección 2.",
            )
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
    // tasks 1.0.0 declara protobuf-javalite pero llama Any.Builder.build()
    // con la firma de protobuf-java: con javalite, crear Holistic tira
    // NoSuchMethodError y la app se cierra al abrir la camara
    // (senas_core MediaPipeProtobufTest). protobuf-java trae tambien el
    // runtime lite de sus protos.
    implementation("com.google.mediapipe:tasks-vision:1.0.0") {
        exclude(group = "com.google.protobuf", module = "protobuf-javalite")
    }
    implementation("com.google.protobuf:protobuf-java:4.26.1")

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
