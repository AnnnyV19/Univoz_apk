/// Envio de frames en vivo al visor del avatar (WebView), compartido por
/// Espejo y Traducir. Antes vivia dentro de PantallaEspejo.
///
/// El canal JS no tiene cola util: si se manda cada frame, los envios se
/// apilan y el avatar arrastra segundos de retraso. Por eso: ultimo frame
/// gana, a lo sumo uno cada [kIntervaloEnvio] y nunca dos en vuelo.
library avatar_vivo;

import 'dart:async';

import 'camera_bridge.dart';
import 'sign_norm.dart' show calidadFrame;

/// Tope de envio al WebView. El canal de landmarks entrega ~30 FPS; el
/// avatar queda libre para actualizarse a 60 FPS.
const Duration kIntervaloEnvio = Duration(milliseconds: 33);

/// Misma firma que AvatarBridge.mostrarFrame (inyectable en pruebas).
typedef EnviarFrameAvatar = Future<void> Function(
  List<double> v, {
  List<double>? renderFrame,
  int? timestampMs,
  double quality,
  Map<String, dynamic>? sourceMeta,
});

/// Metadatos del frame que el visor usa (docs/02, sourceMeta): tiempos y
/// skew, SignSpace, cara, nivel por dispositivo, asociacion de manos.
Map<String, dynamic> sourceMetaDeFrame(LandmarkFrame f,
    {Map<String, double?>? perfilMedidas}) {
  return {
    if (f.poseTimestampMs != null) 'pose_t': f.poseTimestampMs,
    if (f.handsTimestampMs != null) 'hands_t': f.handsTimestampMs,
    if (f.sourceSkewMs != null) 'source_skew_ms': f.sourceSkewMs,
    if (f.signSpace(profileMeasures: perfilMedidas) case final ss?)
      'sign_space': ss.toJson(),
    // Cara (Holistic): el visor calcula cabeza y expresiones.
    if (f.face != null) 'face_pts': f.face,
    if (f.imageAspect != null) 'image_aspect': f.imageAspect,
    if (f.tier != null) 'tier': f.tier,
    if (f.inferMs != null) 'infer_ms': f.inferMs,
    if (f.thermal != null) 'thermal': f.thermal,
    'has_hand': f.tieneAlgunaMano,
    'association': f.association,
    'tracks': {
      'left': f.association['left_state'],
      'right': f.association['right_state'],
    },
    'contact': {
      'active': f.association['contact'] == true,
      'wrist_distance_shoulders': f.association['contact_wrist_distance'],
    },
    'errors': f.errors,
    // Seguimiento de CapturaManos (Kotlin): el visor cuenta recuperaciones y
    // volteos con countHandEvents, como en la web.
    if (f.track != null) 'hand_track': f.track,
  };
}

class AlimentadorAvatar {
  AlimentadorAvatar({
    required this.enviar,
    this.perfilMedidas,
    this.intervalo = kIntervaloEnvio,
  });

  final EnviarFrameAvatar enviar;
  final Map<String, double?>? Function()? perfilMedidas;
  final Duration intervalo;

  bool _activo = false;
  bool get activo => _activo;

  /// True mientras hay un frame viajando al WebView.
  bool _enVuelo = false;
  LandmarkFrame? _pendiente;
  Timer? _envioProgramado;
  DateTime _ultimoEnvio = DateTime.fromMillisecondsSinceEpoch(0);

  int framesEnviados = 0;

  void iniciar() {
    _activo = true;
  }

  void detener() {
    _activo = false;
    _pendiente = null;
    _envioProgramado?.cancel();
    _envioProgramado = null;
  }

  void alFrame(LandmarkFrame f) {
    if (!_activo) return;
    _pendiente = f; // último frame gana; nunca acumular cola.
    _enviarPendiente();
  }

  Future<void> _enviarPendiente() async {
    if (!_activo || _enVuelo) return;
    final f = _pendiente;
    if (f == null) return;

    final ahora = DateTime.now();
    final restante = intervalo - ahora.difference(_ultimoEnvio);
    if (restante > Duration.zero) {
      _envioProgramado ??= Timer(restante, () {
        _envioProgramado = null;
        _enviarPendiente();
      });
      return;
    }
    _pendiente = null;

    // normalize() devuelve null si no hay pose usable (persona fuera de
    // cuadro, hombros no visibles). En ese caso no se manda nada: WebView
    // conserva pose durante un gap breve y su watchdog vuelve a reposo si el
    // stream queda silencioso mas de 450 ms.
    final v = f.normalize();
    if (v == null) return;
    final render = f.normalizeForRender() ?? v;

    _ultimoEnvio = ahora;
    _enVuelo = true;
    try {
      await enviar(
        v,
        renderFrame: render,
        timestampMs: f.timestampMs,
        // Formula de la web (calcularCalidadFrameWeb); v ya es valido.
        quality: calidadFrame(f.pose, f.poseMundo, f.left, f.right),
        sourceMeta: sourceMetaDeFrame(f, perfilMedidas: perfilMedidas?.call()),
      );
      if (_activo) framesEnviados++;
    } catch (_) {
      // El WebView puede no estar listo todavia (el VRM tarda en cargar).
      // No vale la pena mostrarlo: el siguiente frame llega en 33 ms.
    } finally {
      _enVuelo = false;
      if (_pendiente != null) _enviarPendiente();
    }
  }
}
