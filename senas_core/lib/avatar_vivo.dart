/// Envio de frames en vivo al visor del avatar (WebView), compartido por
/// Espejo y Traducir. Antes vivia dentro de PantallaEspejo.
///
/// El canal JS no tiene cola util: si se manda cada frame, los envios se
/// apilan y el avatar arrastra segundos de retraso. Por eso: ultimo frame
/// gana, a lo sumo uno cada [kIntervaloEnvio] y nunca dos en vuelo.
library avatar_vivo;

import 'dart:async';

import 'camera_bridge.dart';
import 'diagnostico_latencia.dart';
import 'frame_derivados.dart';

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

/// Metadatos del frame que el visor del espejo usa: tiempos y skew, cara,
/// nivel por dispositivo y seguimiento nativo de manos (sus contadores van a
/// los eventos perf de la sesion). SignSpace y la asociacion/contacto de
/// manos NO viajan: el visor en vivo usa el retarget 'legacy' y solo el panel
/// de diagnostico lee la asociacion; la sesion los registra aparte.
Map<String, dynamic> sourceMetaDeFrame(LandmarkFrame f) {
  return {
    if (f.poseTimestampMs != null) 'pose_t': f.poseTimestampMs,
    if (f.handsTimestampMs != null) 'hands_t': f.handsTimestampMs,
    if (f.sourceSkewMs != null) 'source_skew_ms': f.sourceSkewMs,
    // Cara (Holistic): el visor calcula cabeza y expresiones.
    if (f.face != null) 'face_pts': f.face,
    if (f.imageAspect != null) 'image_aspect': f.imageAspect,
    if (f.tier != null) 'tier': f.tier,
    if (f.inferMs != null) 'infer_ms': f.inferMs,
    if (f.thermal != null) 'thermal': f.thermal,
    'has_hand': f.tieneAlgunaMano,
    'errors': f.errors,
    // Seguimiento de CapturaManos (Kotlin): el visor cuenta recuperaciones y
    // volteos con countHandEvents, como en la web.
    if (f.track != null) 'hand_track': f.track,
  };
}

class AlimentadorAvatar {
  AlimentadorAvatar({
    required this.enviar,
    this.intervalo = kIntervaloEnvio,
    MedidorEnvio? medidor,
  }) : _medidorFijo = medidor;

  final EnviarFrameAvatar enviar;
  final Duration intervalo;

  bool _activo = false;
  bool get activo => _activo;

  /// True mientras hay un frame viajando al WebView.
  bool _enVuelo = false;
  LandmarkFrame? _pendiente;

  /// Ultimo frame con pose usable: su cuerpo se sostiene cuando la pose falta
  /// pero las manos siguen vistas (persona muy cerca de la camara).
  LandmarkFrame? _ultimoConPose;
  Timer? _envioProgramado;
  DateTime _ultimoEnvio = DateTime.fromMillisecondsSinceEpoch(0);

  int framesEnviados = 0;

  // Medicion de latencia (diagnostico_latencia.dart): solo existe con el modo
  // desarrollador encendido; si no, estos metodos no hacen nada. En pruebas
  // se inyecta [medidor].
  final MedidorEnvio? _medidorFijo;
  MedidorEnvio? _medidorPropio;

  MedidorEnvio? get _medidor {
    if (_medidorFijo != null) return _medidorFijo;
    if (!DiagnosticoLatencia.activo) return null;
    return _medidorPropio ??= MedidorEnvio();
  }

  /// Cierra la ventana de 1 s si toca y la imprime (UnivozLat dart ...).
  void _reportar(MedidorEnvio m) {
    final campos = m.cerrarSiToca(relojDiagnosticoUs());
    if (campos != null) DiagnosticoLatencia.emitir('dart', campos);
  }

  void iniciar() {
    _activo = true;
  }

  void detener() {
    _activo = false;
    _pendiente = null;
    _ultimoConPose = null;
    _envioProgramado?.cancel();
    _envioProgramado = null;
  }

  void alFrame(LandmarkFrame f) {
    if (!_activo) return;
    final m = _medidor;
    if (m != null) {
      m.frameLlegado(f.llegadaUs ?? relojDiagnosticoUs());
      if (_pendiente != null) m.reemplazado();
      _reportar(m);
    }
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

    // normalize() devuelve null si no hay pose usable (persona muy cerca o
    // fuera de cuadro, hombros no visibles). Con manos vistas y un cuerpo
    // anterior, el avatar sostiene ese cuerpo y sigue las manos en vivo (un
    // frame con el ultimo cuerpo valido y las manos de este). Sin manos o sin
    // cuerpo previo no se manda nada: el visor conserva la pose y su watchdog
    // vuelve a reposo si el stream queda silencioso mas de 450 ms.
    var base = f;
    var v = normalizarCacheado(f);
    if (v != null) {
      _ultimoConPose = f;
    } else if (_ultimoConPose case final c? when f.tieneAlgunaMano) {
      base = LandmarkFrame(
        timestampMs: f.timestampMs,
        pose: c.pose,
        poseMundo: c.poseMundo,
        left: f.left,
        right: f.right,
        renderLeft: f.renderLeft,
        renderRight: f.renderRight,
      );
      v = normalizarCacheado(base);
    }
    if (v == null) {
      _medidor?.sinPose();
      return;
    }
    final render = normalizarRenderCacheado(base) ?? v;

    _ultimoEnvio = ahora;
    _enVuelo = true;
    final m = _medidor;
    // Solo se lee el reloj con la medicion encendida.
    final inicioUs = m == null ? 0 : relojDiagnosticoUs();
    try {
      await enviar(
        v,
        renderFrame: render,
        timestampMs: f.timestampMs,
        // Formula de la web (calcularCalidadFrameWeb); v ya es valido.
        quality: calidadCacheada(base),
        sourceMeta: {
          ...sourceMetaDeFrame(f),
          // Con el cuerpo sostenido el desfase pose/manos ya no significa
          // nada (y el visor descarta los frames con skew > 120 ms).
          if (!identical(base, f)) 'source_skew_ms': 0,
        },
      );
      if (_activo) framesEnviados++;
      if (m != null) {
        m.enviado(
          esperaMs: (inicioUs - (f.llegadaUs ?? inicioUs)) / 1000,
          viajeMs: (relojDiagnosticoUs() - inicioUs) / 1000,
          capAgeMs: f.capAgeMs,
        );
      }
    } catch (_) {
      // El WebView puede no estar listo todavia (el VRM tarda en cargar).
      // No vale la pena mostrarlo: el siguiente frame llega en 33 ms.
      m?.fallo();
    } finally {
      _enVuelo = false;
      if (_pendiente != null) _enviarPendiente();
    }
  }
}
