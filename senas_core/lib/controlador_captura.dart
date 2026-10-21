/// Ciclo de vida de la camara + grabacion de una sena.
///
/// Lo comparten la pantalla de reconocimiento y la de captura de muestras:
/// las dos necesitan exactamente lo mismo (preview en vivo, esqueleto, y un
/// buffer de frames ya normalizados) y solo se diferencian en que hacen con
/// la secuencia al final. Tenerlo en un solo lugar evita que las dos
/// pantallas se desincronicen cuando cambie el pipeline.
library controlador_captura;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/widgets.dart' show AppLifecycleState;

import 'camera_bridge.dart';
import 'frame_derivados.dart';
import 'body_profile.dart';
import 'motion_contract.dart';
import 'sesion_captura.dart';
import 'sign_norm.dart' show fillGaps, kTFrames, resample;

/// Observable camera lifecycle. [lista] alone cannot distinguish a native
/// camera that bound successfully from one that never emits its first frame.
enum EstadoCamara { detenida, inicializando, enlazada, lista, error }

/// Resultado completo de una captura. La secuencia normalizada alimenta DTW
/// y el modelo; los landmarks crudos permiten auditar o re-normalizar sin
/// guardar video.
class CapturaMovimiento {
  final MotionSequenceV2 secuencia;
  final List<LandmarkFrame> framesCrudos;
  final int framesInvalidos;
  final double? fps;
  final int? duracionMs;
  final double? visibilidadMin;
  final double qualityScore;
  final String checksumSha256;

  CapturaMovimiento({
    required this.secuencia,
    required List<LandmarkFrame> framesCrudos,
    required this.framesInvalidos,
    required this.fps,
    required this.duracionMs,
    required this.visibilidadMin,
    required this.qualityScore,
    required this.checksumSha256,
  }) : framesCrudos = List<LandmarkFrame>.unmodifiable(framesCrudos);

  Map<String, dynamic> toJson() => {
        'schema': 'MotionCaptureV1',
        'sequence': secuencia.toJson(),
        'frames': framesCrudos.map((frame) => frame.toJson()).toList(),
        'frames_invalidos': framesInvalidos,
        if (fps != null) 'fps': fps,
        if (duracionMs != null) 'duracion_ms': duracionMs,
        if (visibilidadMin != null) 'visibilidad_min': visibilidadMin,
        'quality_score': qualityScore,
        'checksum_sha256': checksumSha256,
      };
}

/// Vigila que la camara siga mandando frames una vez que arranco. Si pasan
/// [limite] sin ninguno (preview o fusionado) con la app en primer plano,
/// avisa una vez con [alEstancarse]. En segundo plano no cuenta: Android
/// suelta la camara y el silencio es normal.
///
/// En vez de rearmar un Timer por frame (dos streams a ~30 FPS) cada frame
/// solo levanta una bandera y un tic cada [paso] lleva la cuenta: avisa
/// entre [limite] y [limite] + [paso] despues del ultimo frame.
class VigilanteEstancamiento {
  VigilanteEstancamiento({
    required this.alEstancarse,
    this.limite = const Duration(seconds: 4),
    this.paso = const Duration(milliseconds: 250),
    bool Function()? enPrimerPlano,
  }) : _enPrimerPlano = enPrimerPlano ?? appEnPrimerPlano;

  final VoidCallback alEstancarse;
  final Duration limite;
  final Duration paso;
  final bool Function() _enPrimerPlano;

  Timer? _tic;
  bool _huboFrame = false;
  int _sinFrameMs = 0;

  bool get activo => _tic != null;

  /// Empieza (o reinicia) la cuenta desde cero.
  void iniciar() {
    _tic?.cancel();
    _huboFrame = false;
    _sinFrameMs = 0;
    _tic = Timer.periodic(paso, (_) => _alTic());
  }

  /// Llego un frame: la camara sigue viva.
  void frame() => _huboFrame = true;

  void detener() {
    _tic?.cancel();
    _tic = null;
  }

  void _alTic() {
    if (_huboFrame || !_enPrimerPlano()) {
      _huboFrame = false;
      _sinFrameMs = 0;
      return;
    }
    _sinFrameMs += paso.inMilliseconds;
    if (_sinFrameMs < limite.inMilliseconds) return;
    detener();
    alEstancarse();
  }
}

/// Primer plano segun el binding de Flutter. Sin binding (pruebas puras) o
/// sin estado informado todavia, se asume primer plano.
bool appEnPrimerPlano() {
  try {
    final estado = SchedulerBinding.instance.lifecycleState;
    return estado == null || estado == AppLifecycleState.resumed;
  } catch (_) {
    return true;
  }
}

class ControladorCaptura extends ChangeNotifier {
  /// [camara] se inyecta en pruebas; por defecto, la camara nativa.
  /// [enPrimerPlano] reemplaza al ciclo de vida de la app en pruebas.
  ControladorCaptura({
    CameraBridge? camara,
    int Function()? ahora,
    bool Function()? enPrimerPlano,
  })  : camara = camara ?? CameraBridge(),
        _ahora = ahora ?? (() => DateTime.now().millisecondsSinceEpoch),
        _enPrimerPlano = enPrimerPlano;

  final CameraBridge camara;
  final int Function() _ahora;
  final bool Function()? _enPrimerPlano;

  /// La camara arranco y despues se callo (cable logico roto, servicio de
  /// camara caido): error bloqueante con Reintentar, igual que los fatales.
  late final VigilanteEstancamiento _estancamiento = VigilanteEstancamiento(
    enPrimerPlano: _enPrimerPlano,
    alEstancarse: () {
      if (_apagado || iniciada == null) return;
      _marcarError(StateError(kCamaraSinRespuesta));
      unawaited(camara.detener());
    },
  );

  /// Errores transitorios del stream nativo: solo a la sesion, y escalan al
  /// error bloqueante si persisten sin frames (ver [VigilanteErrores]).
  final VigilanteErrores _vigilante = VigilanteErrores();
  int _ultimoLogTransitorioMs = -1000000;
  int _transitoriosSinLog = 0;

  /// Frames fusionados que se guardan aunque no se este grabando: el
  /// detector automatico declara el inicio cuando la sena ya arranco, y
  /// [empezar] recupera ese comienzo desde aca (pre-roll).
  static const int kAnilloMs = 400;

  /// Ultimo frame para pintar el esqueleto. Va aparte del ChangeNotifier
  /// para que el preview se repinte a 30 fps sin reconstruir la pantalla
  /// entera en cada frame.
  final ValueNotifier<LandmarkFrame?> frame =
      ValueNotifier<LandmarkFrame?>(null);

  CamaraIniciada? iniciada;
  EstadoCamara estado = EstadoCamara.detenida;
  String? error;
  bool grabando = false;
  bool _apagado = false;
  bool _primerFrameRecibido = false;
  int _inicioActual = 0;

  Timer? _watchdogPreview;
  StreamSubscription<LandmarkFrame>? _subPreview;
  StreamSubscription<LandmarkFrame>? _subFusion;
  final List<LandmarkFrame> _anillo = [];
  // Paralelos: cada frame crudo y su vector (null si no se pudo normalizar).
  final List<LandmarkFrame> _framesCrudos = [];
  final List<List<double>?> _vectores = [];
  int _framesInvalidos = 0;

  /// Cuantos frames utilizables lleva (o dejo, tras recortar) la grabacion.
  int get framesGrabados => _vectores.where((v) => v != null).length;

  // ---- Sesion automatica (docs/13) ----------------------------------------
  SesionCaptura? _sesion;
  BodyProfileCapture? _capturaPerfil;
  Timer? _flushSesion;
  int _frameSesion = 0;

  /// Se llama cuando la medicion automatica del cuerpo termina.
  void Function(BodyProfile perfil)? onPerfilCorporal;
  SesionCaptura? get sesion => _sesion;

  /// Con consentimiento ya dado: registra cada frame de esta sesion de camara
  /// en [sumidero] y mide el cuerpo en segundo plano.
  void activarSesionAutomatica({
    required SumideroSesion sumidero,
    Map<String, dynamic> meta = const {},
  }) {
    unawaited(_cerrarSesion('restart'));
    _sesion = SesionCaptura(sumidero: sumidero, meta: meta);
    _capturaPerfil = BodyProfileCapture()..start(consent: true);
    _frameSesion = 0;
    _flushSesion?.cancel();
    _flushSesion = Timer.periodic(
        const Duration(seconds: 1), (_) => unawaited(_sesion?.flush()));
    _sesion!.evento('session_auto_start');
  }

  void _registrarSesion(LandmarkFrame f) {
    final sesion = _sesion;
    if (sesion == null) return;
    sesion.frame(frameDeSesion(f, id: ++_frameSesion));
    final captura = _capturaPerfil;
    if (captura != null && captura.state == BodyCaptureState.capturing) {
      captura.push(f.pose, f.poseMundo);
      if (captura.state == BodyCaptureState.done && captura.profile != null) {
        sesion.evento('body_profile', {'profile': captura.profile!.toJson()});
        onPerfilCorporal?.call(captura.profile!);
        _capturaPerfil = null;
      }
    }
  }

  Future<void> _cerrarSesion(String razon) async {
    _flushSesion?.cancel();
    _flushSesion = null;
    final sesion = _sesion;
    _sesion = null;
    _capturaPerfil = null;
    await sesion?.cerrar(razon: razon);
  }
  int get framesRecibidos => _framesCrudos.length;
  int get framesInvalidos => _framesInvalidos;
  bool get lista => iniciada != null;
  bool get primerFrameRecibido => _primerFrameRecibido;

  Future<void> iniciar({bool frontal = true, bool cruzarManos = false}) async {
    // Parámetro legado para no romper llamadas existentes. El motor resuelve
    // lado anatómico por cadena hombro-codo-muñeca y nunca cruza frames.
    camara.cruzarManos = false;
    final inicio = ++_inicioActual;
    _watchdogPreview?.cancel();
    _watchdogPreview = null;
    _estancamiento.detener();
    await _subPreview?.cancel();
    _subPreview = null;
    if (iniciada != null) await camara.detener();
    iniciada = null;
    error = null;
    estado = EstadoCamara.inicializando;
    _primerFrameRecibido = false;
    frame.value = null;
    _vigilante.frameValido();
    _notificar();

    // Subscribe before binding CameraX so the first preview event cannot be
    // lost while the platform texture is coming online.
    _subPreview = camara.framesPreview.listen(
      (f) {
        if (_apagado || inicio != _inicioActual) return;
        frame.value = f;
        _vigilante.frameValido();
        _estancamiento.frame();
        _registrarSesion(f);
        if (!_primerFrameRecibido) {
          _primerFrameRecibido = true;
          _watchdogPreview?.cancel();
          _watchdogPreview = null;
          estado = EstadoCamara.lista;
          // Desde aqui la camara ya mostro imagen: si se calla, es un
          // estancamiento (el vigilante de 5 s solo cubre el arranque).
          _estancamiento.iniciar();
          _notificar();
        }
      },
      onError: (Object e, StackTrace stack) {
        if (inicio != _inicioActual) return;
        _errorDeStream(e);
      },
    );
    await _subFusion?.cancel();
    _subFusion = null;
    _anillo.clear();
    _escucharFusion();
    try {
      final c = await camara.iniciar(frontal: frontal);
      if (_apagado || inicio != _inicioActual) {
        await camara.detener();
        return;
      }
      if (estado == EstadoCamara.error) {
        // Un error del stream llego mientras enlazaba: no se pisa con
        // "enlazada"; la camara se suelta y el usuario ve el Reintentar.
        await camara.detener();
        _notificar();
        return;
      }
      iniciada = c;
      estado = EstadoCamara.enlazada;
      _watchdogPreview = Timer(const Duration(seconds: 5), () {
        if (!_primerFrameRecibido && inicio == _inicioActual) {
          _marcarError(
            StateError('La cámara se conectó pero no envió imagen.'),
          );
          unawaited(camara.detener());
        }
      });
    } catch (e) {
      if (inicio == _inicioActual) {
        _marcarError(e);
        await _subPreview?.cancel();
        _subPreview = null;
      }
    }
    _notificar();
  }

  void _marcarError(Object e) {
    _sesion?.evento('camera_error', {'error': e.toString()});
    error = mensajeErrorCamara(e);
    estado = EstadoCamara.error;
    iniciada = null;
    _watchdogPreview?.cancel();
    _watchdogPreview = null;
    _estancamiento.detener();
    _notificar();
  }

  /// Error del stream nativo (sink?.error), segun [clasificarErrorStream].
  /// Transitorio: queda en la sesion (con tope de frecuencia, pueden ser uno
  /// por frame) y la camara sigue; solo si persiste [VigilanteErrores] sin
  /// ningun frame valido escala. Fatal (o escalado): estado recuperable con
  /// el texto amable del mapper y "Reintentar" de la pantalla. Un error no es
  /// un frame, asi que nunca entra a la grabacion. Preview y fusion suelen
  /// traer el mismo error: el segundo se ignora si ya se esta en error.
  void _errorDeStream(Object e) {
    if (_apagado || estado == EstadoCamara.error) return;
    if (clasificarErrorStream(e) == GravedadError.transitorio) {
      // El nativo sigue vivo (p. ej. tier_rebind_failed al cambiar de nivel
      // por dispositivo): no es silencio. Si estos errores siguen sin
      // frames, quien escala es [VigilanteErrores] (3 s).
      _estancamiento.frame();
      final ahora = _ahora();
      _registrarTransitorio(e, ahora);
      if (!_vigilante.registrarTransitorio(ahora)) return;
    }
    _marcarError(e);
    unawaited(camara.detener());
  }

  void _registrarTransitorio(Object e, int ahora) {
    _transitoriosSinLog++;
    if (ahora - _ultimoLogTransitorioMs < 1000) return;
    _ultimoLogTransitorioMs = ahora;
    _sesion?.evento('error_transitorio', {
      'error': e.toString(),
      'cuantos': _transitoriosSinLog,
    });
    _transitoriosSinLog = 0;
  }

  /// Una sola suscripcion a los frames fusionados: llena el anillo y, si se
  /// esta grabando, la grabacion.
  void _escucharFusion() {
    _subFusion ??= camara.frames.listen(
      _alFrameFusionado,
      onError: (Object e, StackTrace stack) => _errorDeStream(e),
    );
  }

  void _alFrameFusionado(LandmarkFrame f) {
    if (_apagado) return;
    _vigilante.frameValido();
    _estancamiento.frame();
    if (grabando) {
      _agregar(f);
      if (_framesCrudos.length % 5 == 0) _notificar();
      return;
    }
    _anillo.add(f);
    final desde = f.timestampMs - kAnilloMs;
    while (_anillo.isNotEmpty && _anillo.first.timestampMs < desde) {
      _anillo.removeAt(0);
    }
  }

  void _agregar(LandmarkFrame f) {
    _framesCrudos.add(f);
    final vec = normalizarCacheado(f);
    _vectores.add(vec);
    if (vec == null) _framesInvalidos++;
  }

  /// Empieza a grabar. [preRollMs] suma los frames de ese tramo anterior
  /// (del anillo): el detector automatico avisa cuando la sena ya empezo.
  void empezar({int preRollMs = 0}) {
    _framesCrudos.clear();
    _vectores.clear();
    _framesInvalidos = 0;
    if (preRollMs > 0 && _anillo.isNotEmpty) {
      final desde = _anillo.last.timestampMs - preRollMs;
      for (final f in _anillo) {
        if (f.timestampMs >= desde) _agregar(f);
      }
    }
    _anillo.clear();
    grabando = true;
    _escucharFusion();
    _notificar();
  }

  /// Finaliza y devuelve secuencia, landmarks crudos y métricas. Con
  /// [hastaMs] descarta los frames posteriores (la cola quieta que el
  /// detector esperó para declarar el fin).
  Future<CapturaMovimiento?> terminarCaptura({int? hastaMs}) async {
    grabando = false;
    _notificar();
    if (hastaMs != null) {
      while (_framesCrudos.isNotEmpty &&
          _framesCrudos.last.timestampMs > hastaMs) {
        _framesCrudos.removeLast();
        if (_vectores.removeLast() == null) _framesInvalidos--;
      }
    }
    final validos = framesGrabados;
    if (validos == 0) return null;

    final rellenada = fillGaps(List.of(_vectores));
    final remuestreada =
        rellenada == null ? null : resample(rellenada, kTFrames);
    if (remuestreada == null) return null;

    final timestamps = _framesCrudos.map((frame) => frame.timestampMs).toList();
    final primero = timestamps.isEmpty ? null : timestamps.first;
    final ultimo = timestamps.isEmpty ? null : timestamps.last;
    final duracion = primero != null && ultimo != null && ultimo >= primero
        ? ultimo - primero
        : null;
    final fps = duracion != null && duracion > 0 && timestamps.length > 1
        ? (timestamps.length - 1) * 1000 / duracion
        : null;
    final visibilidades = _framesCrudos
        .map((frame) => frame.visibilidadMin)
        .whereType<double>()
        .toList();
    final visibilidadMin = visibilidades.isEmpty
        ? null
        : visibilidades.reduce((a, b) => a < b ? a : b);
    final qualityScore =
        _framesCrudos.isEmpty ? 0.0 : validos / _framesCrudos.length;
    final secuencia = MotionSequenceV2.fromFrames(
      remuestreada,
      fps: fps?.round().clamp(1, 120) ?? 30,
      timestampsMs: List.generate(kTFrames, (i) {
        if (duracion == null) return i * 33;
        return primero! + (duracion * i / (kTFrames - 1)).round();
      }),
    );
    final rawJson =
        jsonEncode(_framesCrudos.map((frame) => frame.toJson()).toList());
    final checksum = sha256.convert(utf8.encode(rawJson)).toString();
    return CapturaMovimiento(
      secuencia: secuencia,
      framesCrudos: _framesCrudos,
      framesInvalidos: _framesInvalidos,
      fps: fps,
      duracionMs: duracion,
      visibilidadMin: visibilidadMin,
      qualityScore: qualityScore,
      checksumSha256: checksum,
    );
  }

  /// Compatibilidad para reconocimiento: devuelve solo secuencia.
  Future<List<List<double>>?> terminar({int? hastaMs}) async {
    return (await terminarCaptura(hastaMs: hastaMs))
        ?.secuencia
        .frames
        .map((frame) => List<double>.from(frame))
        .toList();
  }

  Future<void> reiniciar(
      {required bool frontal, required bool cruzarManos}) async {
    await _subFusion?.cancel();
    _subFusion = null;
    grabando = false;
    _inicioActual++;
    _watchdogPreview?.cancel();
    _watchdogPreview = null;
    _estancamiento.detener();
    await _subPreview?.cancel();
    _subPreview = null;
    await camara.detener();
    await iniciar(frontal: frontal, cruzarManos: cruzarManos);
  }

  Future<void> apagar() async {
    // Antes de cualquier await: cerrar la sesion escribe a disco y un tic
    // del vigilante en esa ventana marcaria error sobre un controlador ya
    // liberado.
    _estancamiento.detener();
    _watchdogPreview?.cancel();
    _watchdogPreview = null;
    // Tambien antes del await: cerrar la sesion escribe a disco y, en esa
    // ventana, los frames del preview seguirian tocando un controlador que
    // dispose() ya libero (frame.value, notifyListeners).
    _apagado = true;
    _inicioActual++;
    await _cerrarSesion('camera_stop');
    _watchdogPreview?.cancel();
    _watchdogPreview = null;
    _estancamiento.detener();
    await _subPreview?.cancel();
    await _subFusion?.cancel();
    _subPreview = null;
    _subFusion = null;
    await camara.detener();
    iniciada = null;
    estado = EstadoCamara.detenida;
    // dispose() no espera a apagar(): para entonces frame ya se libero.
    if (!_liberado) frame.value = null;
  }

  void _notificar() {
    if (!_apagado) notifyListeners();
  }

  bool _liberado = false;

  @override
  void dispose() {
    _estancamiento.detener();
    unawaited(apagar());
    _liberado = true;
    frame.dispose();
    super.dispose();
  }
}

/// Decide de donde sale el movimiento que alimenta al [DetectorAutomatico].
///
/// Con el avatar `listo`, del filtro adaptativo del visor (motion:, mismo del
/// laboratorio web). Si el visor no esta listo (cargando, error, tiempo
/// agotado, renderer caido) no manda motion: el detector se alimenta de los
/// frames de preview con su umbral propio. Nunca las dos fuentes a la vez.
class FuenteMovimientoAuto {
  FuenteMovimientoAuto(this.detector);

  final DetectorAutomatico detector;

  bool _activa = false;
  bool _visorListo = false;
  Stream<LandmarkFrame>? _preview;

  /// True si el movimiento viene del visor (y los frames no se escuchan).
  bool get usaVisor => _activa && _visorListo;
  bool get activa => _activa;

  Future<void> iniciar(Stream<LandmarkFrame> preview,
      {required bool visorListo}) async {
    _activa = true;
    _preview = preview;
    _visorListo = visorListo;
    await _reiniciarDetector();
  }

  /// El visor cambio de estado: solo se re-engancha si la fuente cambia.
  Future<void> visorCambio({required bool listo}) async {
    if (_visorListo == listo) return;
    _visorListo = listo;
    if (_activa) await _reiniciarDetector();
  }

  Future<void> detener() async {
    _activa = false;
    _preview = null;
    await detector.detener();
  }

  Future<void> _reiniciarDetector() async {
    await detector.detener();
    // El await anterior pudo coincidir con un detener().
    if (!_activa) return;
    final preview = _preview;
    if (!_visorListo && preview != null) detector.iniciar(preview);
  }

  /// Movimiento del visor (onMovimiento). Ignorado si el visor no es la
  /// fuente: evita contar dos veces el mismo frame.
  void alMovimientoVisor(
      {required bool hayMovimiento, required int timestampMs}) {
    if (!usaVisor) return;
    detector.alimentarMovimiento(
        hayMovimiento: hayMovimiento, timestampMs: timestampMs);
  }

  /// Preview sin mano o sin pose: con el visor como fuente no le llega nada
  /// (el no recibe frames sin pose), asi que cuenta como quieto. Con la
  /// fuente propia el detector ya ve ese frame.
  void alPreviewSinMano(LandmarkFrame f) {
    if (!usaVisor) return;
    if (!f.tieneAlgunaMano || normalizarCacheado(f) == null) {
      detector.alimentarMovimiento(
          hayMovimiento: false, timestampMs: f.timestampMs);
    }
  }
}

// ---------------------------------------------------------------------------
// Reconocimiento automatico
// ---------------------------------------------------------------------------

/// Estados posibles del reconocedor automatico de senas.
enum EstadoAuto { quieto, grabando, reconociendo, pausa }

/// Detecta inicio y fin de una sena mirando el movimiento de las manos
/// en el stream de preview de la camara, sin necesidad de un boton.
class DetectorAutomatico {
  /// Promedio de cambio por coordenada (x, y) de los landmarks de la mano
  /// entre frames consecutivos (coordenadas normalizadas 0-1).
  /// 0.015 aprox 1.5% del ancho de pantalla por frame.
  final double umbralMovimiento;

  /// Frames consecutivos quietos antes de declarar que la sena termino.
  /// A ~30 fps: 20 aprox 0.67 segundos.
  final int framesQuietosParaCortar;

  /// Los umbrales se expresan en frames de ~30 FPS, pero el detector mide
  /// por tiempo (timestampMs): con el nivel por dispositivo la camara da
  /// 15/24/30 FPS (DeviceTier.kt) y el corte y la sensibilidad no deben
  /// cambiar con el telefono.
  static const double _msPorFrameReferencia = 1000 / 30;

  /// Frames minimos grabados para que valga la pena reconocer.
  final int minFramesParaReconocer;

  DetectorAutomatico({
    this.umbralMovimiento = 0.015,
    this.framesQuietosParaCortar = 20,
    this.minFramesParaReconocer = 8,
  });

  EstadoAuto _estado = EstadoAuto.quieto;
  EstadoAuto get estado => _estado;

  LandmarkFrame? _frameAnterior;
  int? _ultimoAlimentadoMs;
  double _msQuietos = 0;

  /// Instante del ultimo frame con movimiento de la sena en curso (o de la
  /// ultima, hasta la proxima). Sirve para recortar la cola quieta que el
  /// detector necesita ver antes de declarar el fin.
  int? get ultimoMovimientoMs => _ultimoMovimientoMs;
  int? _ultimoMovimientoMs;
  StreamSubscription<LandmarkFrame>? _sub;

  void Function()? onInicioDetectado;
  void Function()? onFinDetectado;
  void Function(EstadoAuto)? onCambioEstado;

  void iniciar(Stream<LandmarkFrame> preview) {
    _sub?.cancel();
    _resetContadores();
    _sub = preview.listen(_procesarFrame);
  }

  double _calcularMovimiento(LandmarkFrame ant, LandmarkFrame act) {
    double suma = 0;
    int n = 0;

    void agregarMano(List<List<double>>? a, List<List<double>>? b) {
      if (a == null || b == null) return;
      final len = a.length < b.length ? a.length : b.length;
      for (int i = 0; i < len; i++) {
        suma += (b[i][0] - a[i][0]).abs();
        suma += (b[i][1] - a[i][1]).abs();
        n += 2;
      }
    }

    agregarMano(ant.left, act.left);
    agregarMano(ant.right, act.right);
    return n > 0 ? suma / n : 0.0;
  }

  void _procesarFrame(LandmarkFrame frame) {
    if (_estado == EstadoAuto.reconociendo || _estado == EstadoAuto.pausa) {
      _frameAnterior = null;
      return;
    }

    final anterior = _frameAnterior;
    _frameAnterior = frame;
    if (anterior == null) return;

    // Timestamp repetido o hacia atras (preview de dos modelos del mismo
    // frame): tratarlo como un frame de referencia, sin escalar.
    final crudoMs = frame.timestampMs - anterior.timestampMs;
    final dtMs = crudoMs > 0
        ? crudoMs.clamp(10, 200).toDouble()
        : _msPorFrameReferencia;
    final tieneManos = frame.left != null || frame.right != null;
    // Movimiento llevado a "por frame de 30 FPS".
    final mov = tieneManos
        ? _calcularMovimiento(anterior, frame) * _msPorFrameReferencia / dtMs
        : 0.0;
    _avanzar(mov > umbralMovimiento, dtMs, frame.timestampMs);
  }

  /// Movimiento ya decidido por otra fuente: el visor (rig_math.mjs, el
  /// mismo filtro adaptativo del laboratorio web) en Traducir. Misma maquina
  /// de estados y corte por tiempo que [iniciar].
  void alimentarMovimiento(
      {required bool hayMovimiento, required int timestampMs}) {
    if (_estado == EstadoAuto.reconociendo || _estado == EstadoAuto.pausa) {
      _ultimoAlimentadoMs = null;
      return;
    }
    final anterior = _ultimoAlimentadoMs;
    _ultimoAlimentadoMs = timestampMs;
    if (anterior == null) return;
    final crudoMs = timestampMs - anterior;
    final dtMs = crudoMs > 0
        ? crudoMs.clamp(10, 200).toDouble()
        : _msPorFrameReferencia;
    _avanzar(hayMovimiento, dtMs, timestampMs);
  }

  void _avanzar(bool hayMovimiento, double dtMs, int timestampMs) {
    if (hayMovimiento && _estado != EstadoAuto.reconociendo &&
        _estado != EstadoAuto.pausa) {
      _ultimoMovimientoMs = timestampMs;
    }
    if (_estado == EstadoAuto.quieto) {
      if (hayMovimiento) {
        _msQuietos = 0;
        _cambiarEstado(EstadoAuto.grabando);
        onInicioDetectado?.call();
      }
    } else if (_estado == EstadoAuto.grabando) {
      if (!hayMovimiento) {
        _msQuietos += dtMs;
        // Medio frame de holgura: a 30 FPS los timestamps alternan 33/34 ms.
        if (_msQuietos >=
            (framesQuietosParaCortar - .5) * _msPorFrameReferencia) {
          _cambiarEstado(EstadoAuto.reconociendo);
          onFinDetectado?.call();
        }
      } else {
        _msQuietos = 0;
      }
    }
  }

  void _cambiarEstado(EstadoAuto nuevo) {
    if (_estado == nuevo) return;
    _estado = nuevo;
    onCambioEstado?.call(nuevo);
  }

  void entrarPausa(Duration duracion, VoidCallback alVolver) {
    _cambiarEstado(EstadoAuto.pausa);
    Future.delayed(duracion, () {
      _resetContadores();
      _cambiarEstado(EstadoAuto.quieto);
      alVolver();
    });
  }

  Future<void> detener() async {
    await _sub?.cancel();
    _sub = null;
    _resetContadores();
    _estado = EstadoAuto.quieto;
  }

  void _resetContadores() {
    _frameAnterior = null;
    _ultimoAlimentadoMs = null;
    _msQuietos = 0;
  }
}
