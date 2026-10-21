# 16 — iPhone (fase 2)

Estado: **solo preparación**. La beta pública es Android. En iPhone la app
abre, pero el reconocimiento de señas no existe todavía: al intentar abrir la
cámara se muestra "El reconocimiento de señas llegará pronto a iPhone."
(`CameraBridge.iniciar` convierte el `MissingPluginException` en
`UnsupportedFeatureException.iosProximamente`, ver `senas_core/lib/camera_bridge.dart`).

Ya hecho en la fase 1: `NSCameraUsageDescription` en `univoz/ios/Runner/Info.plist`
(junto a micrófono y reconocimiento de voz) y el mensaje propio de iPhone.

## Qué falta: un plugin Swift con el mismo contrato que Android

Todo lo de Dart (`CameraBridge`, `LandmarkFrame`, `sign_norm`, DTW, sesiones,
avatar) es común. Lo único que falta es el lado nativo, que en Android es
`LandmarkPlugin.kt` (fuente en `senas_core/android/app/src/main/kotlin/com/univoz/senas/`).

### Canales

| Canal | Tipo | Uso |
|---|---|---|
| `univoz/camara` | `MethodChannel` | arrancar y detener la cámara |
| `univoz/landmarks` | `EventChannel` | frames **fusionados** (pose y manos dentro de 120 ms): para reconocer y guardar |
| `univoz/landmarks_preview` | `EventChannel` | frames apenas termina **cualquiera** de los modelos: solo para pintar el esqueleto |

### Métodos de `univoz/camara`

- `iniciar` con `{frontal: bool (default true), session: num}`. Responde un mapa
  `{textureId: int, espejo: bool (siempre false), ancho: int, alto: int}`.
  `ancho`/`alto` son la resolución del preview **ya corregida por rotación**.
  La textura se registra con `FlutterTextureRegistry`; el permiso de cámara lo
  pide Dart (`permission_handler`), el nativo no lo solicita. Si llega un
  `iniciar` de una sesión más nueva, el viejo responde error
  `camera_start_cancelled`.
- `detener` con `{session: num}`. Responde `null`. Libera cámara, motor y textura.
  Debe ser idempotente.
- Cualquier otro método: `notImplemented`.

`session` es un contador creciente de Dart. El plugin guarda el mayor visto
(`sessionToken`) y descarta el arranque que ya no es el vigente.

### Códigos de error de `iniciar` (los traduce `mensajeErrorCamara`)

`camera_permission`, `camera_unavailable`, `camera_busy`,
`camera_start_cancelled`, `camera_start_failed`. Sin mensaje ni detalles
(`message` y `details` en `nil`): Dart no muestra texto del nativo.

### Errores por el stream (`FlutterError` en el sink)

`mediapipe` (una inferencia falló) y `analisis` (un frame falló, o
`tier_rebind_failed`) son **transitorios**; todo lo demás es fatal
(`clasificarErrorStream`).

### Payload de cada frame (mapa por los dos EventChannel)

Mismas claves que `LandmarkPlugin.aMapa` (los arreglos son `Double` planos):

| Clave | Contenido |
|---|---|
| `t` | marca de tiempo del frame, ms |
| `pose` | 33 x (x, y, z, visibilidad), imagen normalizada [0,1] |
| `poseMundo` | 33 x (x, y, z) en metros, origen en el punto medio de la cadera |
| `left`, `right` | 21 x (x, y, z) de imagen por mano (detección cruda) |
| `renderLeft`, `renderRight` | lo mismo, estabilizado para el avatar |
| `leftWorld`, `rightWorld` | 21 x (x, y, z) en metros (solo Holistic) |
| `face` | 17 x (x, y, z), orden `FACE_KEYPOINTS` (solo Holistic) |
| `pose_t`, `hands_t`, `source_skew_ms` | tiempos de cada modelo y su desfase |
| `association` | mapa con la asociación anatómica mano a lado |
| `errors` | lista de `{code, ...}` por frame |
| `capture_mode` | `"holistic"` o `"separado"` |
| `hands_in`, `track`, `pose_ran` | esquema de sesión web (lo registra `sesion_captura.dart`) |
| `image_w`, `image_h` | tamaño del bitmap ya rotado |
| `tier`, `infer_ms`, `thermal` | nivel por dispositivo (`bajo`/`medio`/`alto`), ms de inferencia y estado térmico |

Cualquier clave puede ser `nil`. La referencia exacta de tipos es
`LandmarkEngine.FrameResult` y `LandmarkFrame.fromMap` en
`senas_core/lib/camera_bridge.dart`.

Por el canal viajan **solo landmarks, nunca imágenes**.

## Plan de trabajo

1. **Plugin Swift** `UnivozLandmarksPlugin` en `univoz/ios/Runner/` (o paquete
   Flutter federado), registrado en `AppDelegate`/`SceneDelegate`, con los tres
   canales de arriba y el mismo ciclo de `session`.
2. **Cámara**: `AVCaptureSession` con la cámara frontal, salida de video a
   `CVPixelBuffer`, textura para el preview con `FlutterTexture`
   (`copyPixelBuffer`). Rotar/orientar para que `ancho`/`alto` y las
   coordenadas coincidan con Android (preview **sin espejo**).
3. **MediaPipe**: `MediaPipeTasksVision` por CocoaPods
   (`pod 'MediaPipeTasksVision'`), `HolisticLandmarker` en modo `.liveStream`,
   con el modelo `holistic_landmarker.task` (el mismo que Android; agregarlo al
   bundle de iOS como recurso, ya que `univoz/assets` ya no lo trae). Respaldo
   "separado" con `PoseLandmarker` + `HandLandmarker` como en `LandmarkEngine.kt`.
4. **Portar la lógica de captura** de Kotlin a Swift, sin cambiarla:
   `CapturaManos`, `HandTrackCoordinator`, `HandCandidateGate`, `JsMath`,
   `DeviceTier` + `DeviceProbe` (RAM, estado térmico con
   `ProcessInfo.thermalState`, delegado GPU/CPU) y `VueloInferencia`.
   Fuente de verdad del comportamiento: los `.mjs` del visor
   (`rig_hand_capture.mjs`, `rig_tracking.mjs`); la regla es la de siempre:
   primero JS, luego regenerar el fixture, luego portar.
5. **Compuerta de paridad**: un test XCTest que lea el fixture
   `senas_core/test/golden/paridad_manos.jsonl.gz` (el mismo de
   `ParidadManosTest.kt`) y exija la misma salida frame a frame. Sin esto
   verde no se publica nada.
6. **Dart**: quitar el aviso "llegará pronto" solo cuando el plugin exista
   (basta con que el canal responda: el `MissingPluginException` desaparece).
   Revisar `kIsWeb`/`Platform.isAndroid` que haya en las pantallas.
7. **Pruebas en teléfono**: mismo protocolo que `09-pruebas-camara.md` en un
   iPhone real (rendimiento por nivel, calor, orientación).

## Requisitos de build

- `univoz/ios/Podfile`: `platform :ios, '15.5'` o más (mínimo de
  MediaPipeTasksVision), `use_frameworks! :linkage => :static` si el pod lo
  pide, y el macro de `permission_handler` para cámara:

  ```ruby
  post_install do |installer|
    installer.pods_project.targets.each do |target|
      flutter_additional_ios_build_settings(target)
      target.build_configurations.each do |config|
        config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= [
          '$(inherited)',
          'PERMISSION_CAMERA=1',
          'PERMISSION_MICROPHONE=1',
          'PERMISSION_SPEECH_RECOGNIZER=1',
        ]
      end
    end
  end
  ```
- `Info.plist`: ya tiene `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`
  y `NSSpeechRecognitionUsageDescription`. Para el botón SOS agregar
  `LSApplicationQueriesSchemes` con `tel` y `sms` (url_launcher en iOS).
- Firma: cuenta de Apple Developer (o certificado de desarrollo gratuito para
  instalar a mano; caduca a los 7 días).

## Compilar e instalar desde Linux: xtool

[xtool](https://github.com/xtool-org/xtool) construye y firma apps de iOS desde
Linux (sin Mac ni Xcode completo) e instala por USB. Ruta propuesta:

1. Instalar xtool y preparar el SDK de iOS (`xtool setup`, necesita el `Xcode.xip`
   para extraer el SDK) e iniciar sesión con el Apple ID.
2. `flutter build ios` **no** funciona sin macOS. Con xtool el plugin Swift y el
   `Runner` se compilan como paquete SwiftPM; el motor de Flutter y el código
   Dart se embeben con `flutter build ios-framework` generado en una Mac o
   con el motor precompilado de Flutter para iOS. Esto es lo más incierto del
   plan: hay que probarlo con una app mínima antes de portar nada.
3. `xtool dev` / `xtool install` instala en el iPhone conectado.
4. Si xtool no alcanza para Flutter, plan B: Mac en la nube (por horas) o CI con
   runner macOS, solo para compilar y firmar.

## Criterios de salida de la fase 2

- Paridad de manos verde en XCTest con el fixture compartido.
- Reconocimiento y avatar funcionando en un iPhone real a >= 20 FPS en nivel medio.
- Ficha de privacidad de App Store coherente con `docs/PRIVACIDAD.md`.
- El aviso "llegará pronto" desaparece.
