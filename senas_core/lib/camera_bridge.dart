/// Puente de Dart hacia la camara nativa.
///
/// Recibe landmarks crudos por EventChannel y los convierte en frames
/// normalizados de 152 dimensiones, listos para el clasificador.
library camera_bridge;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';

import 'sign_norm.dart';
import 'sign_space.dart';

const String kCanalMetodos = 'univoz/camara';

// Fusionado: solo llegan frames donde pose y manos estan dentro de una
// ventana temporal compatible de 120 ms. Usar para normalizar/clasificar
// (DtwClassifier) o guardar muestras; preview queda separado para UI.
const String kCanalEventos = 'univoz/landmarks';

// Preview: llega un frame apenas termina CUALQUIERA de los dos modelos del
// lado nativo, sin esperar al otro (puede traer pose y manos de instantes
// ligeramente distintos). Es el que hay que usar para pintar el esqueleto
// en pantalla: se siente a tiempo real. No usar para guardar datos.
const String kCanalEventosPreview = 'univoz/landmarks_preview';

/// Error for a native-only capability requested from an unsupported target.
class UnsupportedFeatureException implements Exception {
  final String feature;
  final String message;

  const UnsupportedFeatureException({
    required this.feature,
    required this.message,
  });

  const UnsupportedFeatureException.camara()
      : feature = 'camara',
        message = 'La cámara de señas está disponible en Android.';

  /// iPhone todavia no tiene plugin nativo de captura (fase 2, ver
  /// docs/16-ios-fase2.md): el canal no existe y Flutter lo reporta como
  /// MissingPluginException. No es un fallo de camara ni de permisos.
  const UnsupportedFeatureException.iosProximamente()
      : feature = 'camara_ios',
        message = 'El reconocimiento de señas llegará pronto a iPhone.';

  @override
  String toString() => message;
}

/// Texto del vigilante de estancamiento (ControladorCaptura): la camara
/// venia mandando frames y se callo. Ya es el texto para la persona.
const String kCamaraSinRespuesta = 'La cámara dejó de responder.';

/// Maps platform failures to safe, user-facing messages.
String mensajeErrorCamara(Object error) {
  if (error is UnsupportedFeatureException) return error.message;
  if (error is StateError && error.message == kCamaraSinRespuesta) {
    return kCamaraSinRespuesta;
  }
  if (error is StateError &&
      error.message == 'La cámara se conectó pero no envió imagen.') {
    return 'La cámara se conectó pero no envió imagen. Revisa el encuadre y reintenta.';
  }
  if (error is PlatformException) {
    return switch (error.code) {
      'camera_permission' => 'Concede permiso de cámara para continuar.',
      'camera_busy' =>
        'La cámara está siendo usada por otra aplicación. Ciérrala y reintenta.',
      'camera_unavailable' =>
        'La cámara no está disponible en este dispositivo.',
      'camera_start_cancelled' => 'El inicio de cámara fue cancelado.',
      'mediapipe_init' =>
        'No se pudo preparar el reconocimiento de señas en este teléfono.',
      // Errores que llegan por el stream de landmarks (sink?.error nativo).
      'mediapipe' || 'analisis' => 'Hubo un problema con la cámara.',
      _ => 'No se pudo iniciar la cámara. Revisa permisos y reintenta.',
    };
  }
  return 'No se pudo iniciar la cámara. Revisa permisos y reintenta.';
}

/// Que tanto afecta un error del stream de landmarks.
enum GravedadError { fatal, transitorio }

/// Clasifica por codigo lo que emite el lado nativo por el stream
/// (`sink?.error`): `mediapipe` (una inferencia fallo: holistic/manos/pose) y
/// `analisis` (un frame fallo, o `tier_rebind_failed`: la camara sigue con la
/// resolucion anterior) son transitorios. Todo lo demas (apertura o enlace de
/// camara, permiso, desconocidos) es fatal.
GravedadError clasificarErrorStream(Object error) {
  if (error is PlatformException &&
      (error.code == 'mediapipe' || error.code == 'analisis')) {
    return GravedadError.transitorio;
  }
  return GravedadError.fatal;
}

/// Decide cuando errores transitorios dejan de serlo: si llevan [ventanaMs]
/// llegando sin que haya pasado ningun frame valido, hay que avisar.
class VigilanteErrores {
  final int ventanaMs;
  int? _primerErrorMs;

  VigilanteErrores({this.ventanaMs = 3000});

  /// Un frame llego bien: los errores aislados no cuentan.
  void frameValido() => _primerErrorMs = null;

  /// Registra un error transitorio en [ahoraMs]; true si ya hay que escalar.
  bool registrarTransitorio(int ahoraMs) {
    final primero = _primerErrorMs ??= ahoraMs;
    return ahoraMs - primero >= ventanaMs;
  }
}

/// Un frame crudo tal como llega del lado nativo.
class LandmarkFrame {
  /// Milisegundos, estrictamente creciente.
  final int timestampMs;

  /// 33 landmarks de pose en coordenadas de imagen, cada uno
  /// [x, y, z, visibility]. Null si no hubo. Son los que se pintan sobre el
  /// preview de la camara.
  final List<List<double>>? pose;

  /// 33 landmarks de pose en METROS, cada uno [x, y, z], con origen en el
  /// punto medio de las caderas. Es el esqueleto 3D real.
  ///
  /// Existe aparte de [pose] porque la Z de las coordenadas de imagen es
  /// solo una profundidad relativa aproximada: se midio incoherente entre
  /// puntos vecinos (un antebrazo de 0.8 anchos de hombro con 3.5 de
  /// recorrido en Z), asi que no sirve para reconstruir una postura. La
  /// normalizacion usa esta y no aquella.
  final List<List<double>>? poseMundo;

  /// 21 landmarks por mano, cada uno [x, y, z]. Null si esa mano no aparecio.
  final List<List<double>>? left;
  final List<List<double>>? right;
  final List<List<double>>? renderLeft;
  final List<List<double>>? renderRight;

  /// Timestamps reales de cada detector. Permiten medir la fusion en vez de
  /// esconder hasta 120 ms de desfase bajo un único [timestampMs].
  final int? poseTimestampMs;
  final int? handsTimestampMs;
  final int? sourceSkewMs;
  final Map<String, dynamic> association;
  final List<Map<String, dynamic>> errors;

  /// Solo captura Holistic: 17 puntos clave de cara (x, y, z en imagen) en
  /// el orden de [kFaceKeypoints], y manos en metros.
  final List<List<double>>? face;
  final List<List<double>>? leftWorld;
  final List<List<double>>? rightWorld;

  /// `holistic` o `separado` (respaldo).
  final String captureMode;

  /// Ancho / alto de la imagen analizada (ya rotada), o null.
  final double? imageAspect;

  /// Nivel por dispositivo ('bajo' | 'medio' | 'alto'), DeviceTier.kt.
  final String? tier;

  /// Inferencia del ultimo resultado nativo, ms.
  final double? inferMs;

  /// PowerManager.THERMAL_STATUS_* (0-6); null sin API (Android < 10).
  final int? thermal;

  /// Entrada de manos de la captura nativa con el esquema de sesion web
  /// (`hands`: candidatas, compuerta, nacimiento, lados, utilizables).
  final Map<String, dynamic>? handsIn;

  /// Seguimiento por lado (estado, superficie palma/dorso, recuperacion).
  final Map<String, dynamic>? track;

  /// La pose de este frame salio del mismo instante (no del cache).
  final bool? poseRan;

  const LandmarkFrame({
    required this.timestampMs,
    this.pose,
    this.poseMundo,
    this.left,
    this.right,
    this.renderLeft,
    this.renderRight,
    this.poseTimestampMs,
    this.handsTimestampMs,
    this.sourceSkewMs,
    this.association = const {},
    this.errors = const [],
    this.face,
    this.leftWorld,
    this.rightWorld,
    this.captureMode = 'separado',
    this.imageAspect,
    this.tier,
    this.inferMs,
    this.thermal,
    this.handsIn,
    this.track,
    this.poseRan,
  });

  /// Copia de este frame con otros landmarks de pose y de manos (en imagen) y
  /// TODO lo demas igual: mundo, render, cara, aspecto, nivel del dispositivo,
  /// metadatos. Quien reemplaza landmarks (p. ej. el suavizado visual) debe
  /// pasar por aqui y no armar un LandmarkFrame nuevo campo por campo: al
  /// agregar un campo a la clase se olvidaba copiarlo y llegaba en null. Los
  /// tres son obligatorios para poder pasar null a proposito (mano ausente).
  LandmarkFrame conLandmarks({
    required List<List<double>>? pose,
    required List<List<double>>? left,
    required List<List<double>>? right,
  }) =>
      LandmarkFrame(
        timestampMs: timestampMs,
        pose: pose,
        poseMundo: poseMundo,
        left: left,
        right: right,
        renderLeft: renderLeft,
        renderRight: renderRight,
        poseTimestampMs: poseTimestampMs,
        handsTimestampMs: handsTimestampMs,
        sourceSkewMs: sourceSkewMs,
        association: association,
        errors: errors,
        face: face,
        leftWorld: leftWorld,
        rightWorld: rightWorld,
        captureMode: captureMode,
        imageAspect: imageAspect,
        tier: tier,
        inferMs: inferMs,
        thermal: thermal,
        handsIn: handsIn,
        track: track,
        poseRan: poseRan,
      );

  /// El aspecto a usar para corregir la forma de la mano.
  double get aspectoEfectivo => imageAspect ?? kAspectoAnalisisApp;

  /// Decodifica desde el mapa que llega por el canal del lado nativo.
  /// [swapHands] cruza izquierda y derecha -- ver CameraBridge.cruzarManos.
  factory LandmarkFrame.fromMap(Map<Object?, Object?> map,
      {bool swapHands = false}) {
    final pose = _desempacar(map['pose'], 4);
    final poseMundo = _desempacar(map['poseMundo'], 3);
    var izq = _desempacar(map['left'], 3);
    var der = _desempacar(map['right'], 3);
    var renderIzq = _desempacar(map['renderLeft'] ?? map['render_left'], 3);
    var renderDer = _desempacar(map['renderRight'] ?? map['render_right'], 3);
    var mundoIzq = _desempacar(map['leftWorld'], 3);
    var mundoDer = _desempacar(map['rightWorld'], 3);
    if (swapHands) {
      final tmp = izq;
      izq = der;
      der = tmp;
      final tmpMundo = mundoIzq;
      mundoIzq = mundoDer;
      mundoDer = tmpMundo;
      final tmpRender = renderIzq;
      renderIzq = renderDer;
      renderDer = tmpRender;
    }
    final poseT = (map['pose_t'] as num?)?.toInt();
    final handsT = (map['hands_t'] as num?)?.toInt();
    final explicitSkew = (map['source_skew_ms'] as num?)?.toInt();
    final association = map['association'] is Map
        ? (map['association'] as Map)
            .map((key, value) => MapEntry(key.toString(), value))
        : const <String, dynamic>{};
    final errors = map['errors'] is List
        ? (map['errors'] as List)
            .whereType<Map>()
            .map((error) =>
                error.map((key, value) => MapEntry(key.toString(), value)))
            .toList(growable: false)
        : const <Map<String, dynamic>>[];
    return LandmarkFrame(
      timestampMs: (map['t'] as num).toInt(),
      pose: pose,
      poseMundo: poseMundo,
      left: izq,
      right: der,
      renderLeft: renderIzq,
      renderRight: renderDer,
      poseTimestampMs: poseT,
      handsTimestampMs: handsT,
      sourceSkewMs: explicitSkew ??
          (poseT != null && handsT != null ? (poseT - handsT).abs() : null),
      association: association,
      errors: errors,
      face: _desempacar(map['face'], 3),
      leftWorld: mundoIzq,
      rightWorld: mundoDer,
      captureMode: map['capture_mode'] as String? ?? 'separado',
      imageAspect: _aspecto(map['image_w'], map['image_h']),
      tier: map['tier'] is String ? map['tier'] as String : null,
      inferMs: (map['infer_ms'] as num?)?.toDouble(),
      thermal: (map['thermal'] as num?)?.toInt(),
      handsIn: _mapa(map['hands_in']),
      track: _mapa(map['track']),
      poseRan: map['pose_ran'] is bool ? map['pose_ran'] as bool : null,
    );
  }

  /// Mapa del canal (Map<Object?, Object?> anidado) con claves String.
  static Map<String, dynamic>? _mapa(Object? raw) =>
      raw is Map ? raw.map((k, v) => MapEntry(k.toString(), _valor(v))) : null;

  static Object? _valor(Object? v) => v is Map
      ? _mapa(v)
      : v is List && v is! TypedData
          ? v.map(_valor).toList(growable: false)
          : v;

  static double? _aspecto(Object? w, Object? h) {
    if (w is! num || h is! num || w <= 0 || h <= 0) return null;
    return w / h;
  }

  static List<List<double>>? _desempacar(Object? raw, int ancho) {
    if (raw == null) return null;
    if (raw is List && raw.isNotEmpty && raw.first is List) {
      return raw
          .map((row) => (row as List)
              .map((value) => (value as num).toDouble())
              .toList(growable: false))
          .toList(growable: false);
    }
    final flat = raw is Float64List
        ? raw
        : Float64List.fromList(
            (raw as List).map((v) => (v as num).toDouble()).toList());
    final n = flat.length ~/ ancho;
    return List<List<double>>.generate(
      n,
      (i) => List<double>.generate(ancho, (j) => flat[i * ancho + j],
          growable: false),
      growable: false,
    );
  }

  /// Vector de 152 dimensiones, o null si el frame no sirve.
  ///
  /// Necesita [poseMundo]: sin el esqueleto metrico no hay forma de
  /// reconstruir la postura. Si el nativo no lo manda (version vieja del
  /// plugin), devuelve null.
  List<double>? normalize() =>
      (!fusionAceptada || pose == null || poseMundo == null)
          ? null
          : normalizeFrame(pose!, poseMundo!, left: left, right: right);

  /// Frame efímero para avatar. Puede contener muñeca predicha y última forma
  /// durante oclusión; nunca se usa para grabación ni reconocimiento. La
  /// ubicacion de cada mano sigue a la muneca estabilizada del render (la de
  /// la pose puede ir atrasada), acotada como en la web.
  List<double>? normalizeForRender() =>
      (!fusionAceptada || pose == null || poseMundo == null)
          ? null
          : normalizeFrame(
              pose!,
              poseMundo!,
              left: renderLeft ?? left,
              right: renderRight ?? right,
              munecasRender: {
                if (renderLeft != null && renderLeft!.isNotEmpty)
                  'left': renderLeft![0],
                if (renderRight != null && renderRight!.isNotEmpty)
                  'right': renderRight![0],
              },
            );

  /// Calidad del frame en [0, 1] con la formula de la web (calidadFrame); 0
  /// si el frame no da vector.
  double get calidad =>
      normalize() == null ? 0.0 : calidadFrame(pose, poseMundo, left, right);

  /// SignSpaceFrame v1 para el avatar (independiente del cuerpo), o null.
  /// No reemplaza a [normalize]: el reconocimiento sigue usando 152D.
  /// Con [profileMeasures] (BodyProfileV1.measures) reconstruye codos ocultos.
  SignSpaceFrame? signSpace({Map<String, double?>? profileMeasures}) =>
      (!fusionAceptada || pose == null || poseMundo == null)
          ? null
          : signSpaceFrame(pose!, poseMundo!, profileMeasures: profileMeasures);

  bool get fusionAceptada => (sourceSkewMs ?? 0).abs() <= 120;
  bool get requiereProyeccionRender {
    final skew = (sourceSkewMs ?? 0).abs();
    return skew > 50 && skew <= 120;
  }

  bool get tieneAlgunaMano => left != null || right != null;

  /// Visibilidad mínima de hombros. Se guarda como métrica de calidad; no se
  /// inventa visibilidad para worldLandmarks porque MediaPipe no la entrega.
  double? get visibilidadMin {
    final p = pose;
    if (p == null || p.length <= kRShoulder) return null;
    if (p[kLShoulder].length < 4 || p[kRShoulder].length < 4) return null;
    return p[kLShoulder][3] < p[kRShoulder][3]
        ? p[kLShoulder][3]
        : p[kRShoulder][3];
  }

  /// Contrato de persistencia para landmarks crudos sin video.
  Map<String, dynamic> toJson() => {
        'schema': 'LandmarkFrameV1',
        't': timestampMs,
        'pose': pose,
        'poseMundo': poseMundo,
        'left': left,
        'right': right,
        'renderLeft': renderLeft,
        'renderRight': renderRight,
        if (poseTimestampMs != null) 'pose_t': poseTimestampMs,
        if (handsTimestampMs != null) 'hands_t': handsTimestampMs,
        if (sourceSkewMs != null) 'source_skew_ms': sourceSkewMs,
        if (association.isNotEmpty) 'association': association,
        if (errors.isNotEmpty) 'errors': errors,
        if (visibilidadMin != null) 'visibilidad_min': visibilidadMin,
        'capture_mode': captureMode,
        if (imageAspect != null) 'image_aspect': imageAspect,
        if (tier != null) 'tier': tier,
        if (inferMs != null) 'infer_ms': inferMs,
        if (thermal != null) 'thermal': thermal,
        if (handsIn != null) 'hands_in': handsIn,
        if (track != null) 'track': track,
        if (poseRan != null) 'pose_ran': poseRan,
        'quality': calidad,
        if (face != null) 'face': face,
        if (leftWorld != null) 'leftWorld': leftWorld,
        if (rightWorld != null) 'rightWorld': rightWorld,
        'valido': esValido,
      };

  bool get esValido => normalize() != null;
}

/// Indices de la malla facial que manda la captura Holistic, en el orden de
/// [LandmarkFrame.face]. Mismos que FACE_KEYPOINTS (Kotlin) y rig_face.mjs.
const List<int> kFaceKeypoints = [
  1,
  10,
  152,
  33,
  133,
  159,
  145,
  263,
  362,
  386,
  374,
  13,
  14,
  61,
  291,
  105,
  334,
];

/// Alias público del contrato de captura versionado.
typedef LandmarkFrameV1 = LandmarkFrame;

/// Resultado de arrancar la camara.
class CamaraIniciada {
  final int textureId;

  /// Conservado por compatibilidad con versiones anteriores. La vista en
  /// vivo ya no se espeja y el valor nuevo siempre es false.
  final bool espejo;

  /// Si la camara que arranco es la frontal. Las pantallas lo usan para
  /// mostrar la vista como un espejo (imagen y landmarks volteados de
  /// izquierda a derecha): solo es presentacion, los datos que van al
  /// reconocimiento y al avatar nunca se voltean.
  final bool frontal;

  /// Resolucion real del preview, ya corregida por rotacion. 0 si el lado
  /// nativo todavia no la informa (versiones viejas de LandmarkPlugin.kt).
  final int ancho;
  final int alto;

  const CamaraIniciada(
    this.textureId,
    this.espejo, {
    this.ancho = 0,
    this.alto = 0,
    this.frontal = false,
  });

  /// Relacion de aspecto (ancho/alto) para usar en un widget AspectRatio.
  /// Si el nativo no informo dimensiones, cae al 3:4 tipico de CameraX.
  double get relacionAspecto => (ancho > 0 && alto > 0) ? ancho / alto : 3 / 4;
}

/// Puente hacia la camara nativa.
class CameraBridge {
  static const MethodChannel _metodos = MethodChannel(kCanalMetodos);
  static const EventChannel _eventos = EventChannel(kCanalEventos);
  static const EventChannel _eventosPreview =
      EventChannel(kCanalEventosPreview);

  /// Campo legado. La asociación anatómica nativa es la única fuente de lado;
  /// no se permite cruzar manos desde una preferencia persistida.
  @Deprecated('La asociación anatómica determina izquierda y derecha')
  bool cruzarManos = false;

  Stream<LandmarkFrame>? _stream;
  Stream<LandmarkFrame>? _streamPreview;
  // Global al proceso, como el token nativo (solo crece): con un contador por
  // instancia, la primera camara de cada pantalla nueva llegaba con un numero
  // viejo y el lado nativo la cancelaba.
  static int _session = 0;

  /// Pide permiso de camara antes de llamar esto (por ejemplo con
  /// permission_handler). El lado nativo no lo solicita.
  Future<CamaraIniciada> iniciar({bool frontal = true}) async {
    if (kIsWeb) throw const UnsupportedFeatureException.camara();
    final session = ++_session;
    final Map<String, Object?>? r;
    try {
      r = await _metodos.invokeMapMethod<String, Object?>(
        'iniciar',
        {'frontal': frontal, 'session': session},
      );
    } on MissingPluginException {
      // En iPhone el lado nativo aun no existe: mensaje propio, no el
      // generico de "revisa permisos".
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        throw const UnsupportedFeatureException.iosProximamente();
      }
      rethrow;
    }
    if (r == null) throw StateError('la camara no devolvio textura');
    return CamaraIniciada(
      (r['textureId'] as num).toInt(),
      r['espejo'] == true,
      ancho: (r['ancho'] as num?)?.toInt() ?? 0,
      alto: (r['alto'] as num?)?.toInt() ?? 0,
      frontal: frontal,
    );
  }

  Future<void> detener() async {
    final session = ++_session;
    try {
      if (!kIsWeb) {
        await _metodos.invokeMethod<void>('detener', {'session': session});
      }
    } on MissingPluginException {
      // Cleanup must remain idempotent when screen is disposed on a platform
      // without native camera registration.
    } on PlatformException {
      // Native shutdown errors must not turn route disposal into a crash.
    }
    // Los streams NO se sueltan: son broadcast y viven lo que el puente. Quien
    // los escucha (avatar, detector automatico) sigue suscrito despues de
    // voltear la camara; si se crearan nuevos, el receiveBroadcastStream
    // nuevo reemplazaria el manejador del canal y las suscripciones viejas
    // se quedarian mudas para siempre.
  }

  /// Stream de frames FUSIONADOS: pose y manos garantizadas del mismo
  /// instante. Es broadcast: se puede escuchar desde el reconocedor y para
  /// guardar muestras a la vez. Para pintar el esqueleto en vivo usa
  /// [framesPreview], que responde mucho mas rapido.
  Stream<LandmarkFrame> get frames {
    if (kIsWeb) return _stream ??= Stream<LandmarkFrame>.empty();
    return _stream ??= _eventos
        .receiveBroadcastStream()
        .map((e) =>
            LandmarkFrame.fromMap(e as Map<Object?, Object?>, swapHands: false))
        .asBroadcastStream();
  }

  /// Stream de frames en vivo para UI: se actualiza apenas termina
  /// cualquiera de los dos modelos nativos, sin esperar a que coincidan.
  /// Puede traer pose y manos de instantes ligeramente distintos entre si
  /// -- para el ojo humano no se nota, y es lo que hace que el esqueleto en
  /// pantalla se sienta a tiempo real. No usar esto para normalizar ni
  /// guardar muestras (usa [frames] para eso).
  Stream<LandmarkFrame> get framesPreview {
    if (kIsWeb) return _streamPreview ??= Stream<LandmarkFrame>.empty();
    return _streamPreview ??= _eventosPreview
        .receiveBroadcastStream()
        .map((e) =>
            LandmarkFrame.fromMap(e as Map<Object?, Object?>, swapHands: false))
        .asBroadcastStream();
  }

  /// Solo los frames normalizables, ya como vectores de 152 dimensiones.
  Stream<({int t, List<double> vec})> get vectores => frames
      .map((f) => (t: f.timestampMs, vec: f.normalize()))
      .where((e) => e.vec != null)
      .map((e) => (t: e.t, vec: e.vec!));
}
