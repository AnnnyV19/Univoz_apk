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
import 'dart:math' as math;

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/widgets.dart' show AppLifecycleState;

import 'camera_bridge.dart';
import 'frame_derivados.dart';
import 'body_profile.dart';
import 'motion_contract.dart';
import 'sesion_captura.dart';
import 'sign_norm.dart'
    show
        fillGaps,
        isotropizarSecuencia,
        kAspectoAnalisisApp,
        kOffLocL,
        kOffPresL,
        kOffPresR,
        kOffShapeL,
        kOffShapeR,
        kTFrames,
        resample;
import 'suavizado_landmarks.dart';

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

  /// Relacion ancho / alto de la imagen con la que se grabo. La secuencia
  /// guardada sigue en el formato 2.0.0 (sin corregir): este dato es lo que
  /// permite corregirla despues, al comparar.
  final double aspecto;

  CapturaMovimiento({
    required this.secuencia,
    required List<LandmarkFrame> framesCrudos,
    required this.framesInvalidos,
    required this.fps,
    required this.duracionMs,
    required this.visibilidadMin,
    required this.qualityScore,
    required this.checksumSha256,
    this.aspecto = kAspectoAnalisisApp,
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
        'aspecto': aspecto,
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

  /// Calma el temblor de los puntos que se dibujan. Solo afecta a [frame]
  /// (lo que se pinta): la grabacion y el reconocimiento leen los frames
  /// fusionados sin filtrar (camara.vectores / camara.frames).
  final SuavizadorLandmarks _suavizador = SuavizadorLandmarks();

  /// Para comparar o depurar: con false se pintan los puntos crudos.
  bool suavizarPreview = true;

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

  Future<void> iniciar(
      {bool frontal = true,
      bool cruzarManos = false,
      bool separado = false}) async {
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
    _suavizador.reiniciar();
    _notificar();

    // Subscribe before binding CameraX so the first preview event cannot be
    // lost while the platform texture is coming online.
    _subPreview = camara.framesPreview.listen(
      (f) {
        if (_apagado || inicio != _inicioActual) return;
        frame.value = suavizarPreview ? _suavizador.filtrar(f) : f;
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
      final c = await camara.iniciar(frontal: frontal, separado: separado);
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
    final aspectos = _framesCrudos
        .map((frame) => frame.imageAspect)
        .whereType<double>()
        .toList()
      ..sort();
    final aspecto =
        aspectos.isEmpty ? kAspectoAnalisisApp : aspectos[aspectos.length ~/ 2];
    return CapturaMovimiento(
      aspecto: aspecto,
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

  /// Para reconocimiento: devuelve solo la secuencia, con la forma de la mano
  /// ya corregida por el aspecto de la imagen (isotropizarSecuencia), que es
  /// como estan las plantillas del diccionario. Lo que se GUARDA (muestras
  /// locales, subida a la base) sale de [terminarCaptura], sin corregir: ese
  /// es el formato 2.0.0 y la correccion se aplica siempre al comparar.
  Future<List<List<double>>?> terminar({int? hastaMs}) async {
    final c = await terminarCaptura(hastaMs: hastaMs);
    if (c == null) return null;
    return isotropizarSecuencia(
      c.secuencia.frames.map((frame) => List<double>.from(frame)).toList(),
      c.aspecto,
    );
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
/// El mismo "quieto/movimiento" que el visor del avatar le manda a Traducir
/// (rig_math.mjs, createResponsiveRigFilter.motionDiagnostics + el criterio
/// de index.html), calculado en Dart sobre los frames FUSIONADOS ya
/// normalizados. Así el modo automático funciona igual con o sin avatar:
/// antes, sin el visor, se caía al detector por pixeles del preview, que
/// casi nunca arrancaba ni cortaba bien.
class MovimientoTipoVisor {
  MovimientoTipoVisor({this.intervaloMs = 33, this.usarCuerpo = true});

  /// Si el cuerpo (pose, vector 0-23) cuenta como movimiento. Con los brazos
  /// fuera de cuadro la pose salta sola (visibilidad de muñecas 0.2-0.7,
  /// `bone_length_*`/`wrist_teleport` en la sesion del 2026-10-29) y, con
  /// cualquier mano presente, eso arrancaba capturas falsas. En Traducir se
  /// apaga: la seña se mide por muñeca (ubicacion) y dedos, que ya salen
  /// de las manos y no de la pose.
  final bool usarCuerpo;

  /// Igual que kIntervaloEnvio: el visor medía entre frames recibidos a
  /// este ritmo, no entre todos los de la cámara.
  final int intervaloMs;

  List<double>? _anterior;
  int? _anteriorMs;
  // Cada mano se compara con la última vez que estuvo presente (como el
  // DetectorAutomatico): una mano que aparece o desaparece no es movimiento.
  // Sin esto, la otra mano entrando y saliendo de cuadro contaba como
  // movimiento sin parar y la seña nunca terminaba.
  final List<List<double>?> _mano = [null, null];
  final List<int?> _manoMs = [null, null];

  void reiniciar() {
    _anterior = null;
    _anteriorMs = null;
    _mano[0] = _mano[1] = null;
    _manoMs[0] = _manoMs[1] = null;
  }

  /// null si el frame se salta por el ritmo; si no, si hay movimiento.
  bool? alFrame(List<double> v, int timestampMs) {
    final antMs = _anteriorMs;
    if (antMs != null && timestampMs - antMs < intervaloMs && timestampMs >= antMs) {
      return null;
    }
    if (v.length < kOffShapeR + 60) return false;
    final ant = _anterior;
    _anterior = List<double>.of(v);
    _anteriorMs = timestampMs;

    // Todo llevado a "por frame de 33 ms": si los frames fusionados llegan
    // más espaciados, el mismo gesto no debe parecer más brusco.
    double escala(int dt) => intervaloMs / dt.clamp(10, 200);

    var cuerpo = 0.0, muneca = 0.0, forma = 0.0;
    if (ant != null && ant.length == v.length && antMs != null) {
      final k = escala(timestampMs - antMs);
      for (var i = 0; i < kOffLocL; i++) {
        final d = (v[i] - ant[i]) * k;
        cuerpo += d * d;
      }
    }
    const loc = [kOffLocL, kOffLocL + 3];
    const pres = [kOffPresL, kOffPresR];
    const shape = [kOffShapeL, kOffShapeR];
    var conMano = false;
    for (var lado = 0; lado < 2; lado++) {
      if (v[pres[lado]] < .5) continue;
      conMano = true;
      final actual = <double>[
        ...v.sublist(loc[lado], loc[lado] + 3),
        ...v.sublist(shape[lado], shape[lado] + 60),
      ];
      final previa = _mano[lado];
      final previaMs = _manoMs[lado];
      _mano[lado] = actual;
      _manoMs[lado] = timestampMs;
      if (previa == null || previaMs == null) continue;
      final dt = timestampMs - previaMs;
      if (dt <= 0 || dt > 250) continue; // reapareció: no es movimiento
      final k = escala(dt);
      for (var i = 0; i < 3; i++) {
        final d = (actual[i] - previa[i]) * k;
        muneca += d * d;
      }
      for (var i = 3; i < actual.length; i++) {
        final d = (actual[i] - previa[i]) * k;
        forma += d * d;
      }
    }
    if (ant == null) return false;
    double c(double x) => x < 0 ? 0 : (x > 1 ? 1 : x);
    // Umbrales "intentional" del filtro: cuerpo .08, muñeca .06, dedos .08.
    final puntaje = math.max(
        usarCuerpo ? c(math.sqrt(cuerpo) / 0.08) : 0.0,
        c(math.sqrt(muneca) / 0.06));
    final dedos = c(math.sqrt(forma) / 0.08);
    return conMano && (puntaje >= .8 || dedos >= .8);
  }
}

class FuenteMovimientoAuto {
  FuenteMovimientoAuto(this.detector);

  final DetectorAutomatico detector;

  bool _activa = false;
  bool _visorListo = false;

  /// Lo ultimo que dijo el visor. Si llega en mitad de una sena se aplica
  /// al volver el detector a `quieto`: cambiar de fuente lo reiniciaria en
  /// silencio (la barra seguiria en "Grabando..." sin que nadie la cierre).
  bool _visorDeseado = false;
  Stream<LandmarkFrame>? _preview;

  /// True si el movimiento viene del visor (y los frames no se escuchan).
  bool get usaVisor => _activa && _visorListo;
  bool get activa => _activa;

  /// True si hay un cambio de fuente esperando a que termine la sena.
  bool get cambioDiferido => _activa && _visorDeseado != _visorListo;

  Future<void> iniciar(Stream<LandmarkFrame> preview,
      {required bool visorListo}) async {
    _activa = true;
    _preview = preview;
    _visorListo = visorListo;
    _visorDeseado = visorListo;
    detector.alVolverAQuieto = () => unawaited(_aplicarVisor());
    await _reiniciarDetector();
  }

  /// El visor cambio de estado: solo se re-engancha si la fuente cambia, y
  /// no en mitad de una sena (grabando, reconociendo o en pausa).
  Future<void> visorCambio({required bool listo}) async {
    _visorDeseado = listo;
    await _aplicarVisor();
  }

  Future<void> _aplicarVisor() async {
    if (_visorListo == _visorDeseado) return;
    if (_activa && detector.estado != EstadoAuto.quieto) return;
    _visorListo = _visorDeseado;
    if (_activa) await _reiniciarDetector();
  }

  Future<void> detener() async {
    _activa = false;
    _preview = null;
    _visorDeseado = _visorListo;
    detector.alVolverAQuieto = null;
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

  /// Tiempo que el movimiento debe sostenerse, sin un solo frame quieto, para
  /// arrancar la captura. Un frame suelto (una mano que parpadea, un salto de
  /// pose) ya no abre una captura: en la sesion del 2026-10-29, 9 de 22
  /// capturas salieron de 1 o 2 frames. 0 = arranca al primer frame. Se mide
  /// por tiempo, no por frames, para no depender de los FPS del telefono.
  final int msMovimientoParaIniciar;

  DetectorAutomatico({
    this.umbralMovimiento = 0.015,
    this.framesQuietosParaCortar = 20,
    this.minFramesParaReconocer = 8,
    this.msMovimientoParaIniciar = 0,
  });

  /// Instante del primer frame de la racha de movimiento que aun no basta
  /// para arrancar; null si el ultimo frame estuvo quieto.
  int? _inicioRachaMs;

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

  /// Se llama cada vez que el detector vuelve a `quieto` por su propio
  /// camino (fin de la pausa), nunca por [detener].
  void Function()? alVolverAQuieto;

  void iniciar(Stream<LandmarkFrame> preview) {
    _sub?.cancel();
    _resetContadores();
    _sub = preview.listen(_procesarFrame);
  }

  void _procesarFrame(LandmarkFrame frame) {
    if (_estado == EstadoAuto.reconociendo || _estado == EstadoAuto.pausa) {
      _resetContadores();
      return;
    }

    final t = frame.timestampMs;
    final anterior = _frameAnterior;
    _frameAnterior = frame;

    // Cada mano se compara con la ULTIMA vez que se vio esa mano, no con el
    // frame anterior: el preview sale apenas termina cualquiera de los dos
    // modelos nativos, así que puede alternar frames con manos y frames solo
    // con pose. Comparando contra el frame anterior, una mano en movimiento
    // junto a un frame sin manos daba 0 y la seña nunca arrancaba (Traducir
    // sin avatar y la pantalla partida de Comunicarse).
    var suma = 0.0;
    var n = 0;
    void mano(List<List<double>>? act, bool izquierda) {
      if (act == null) return;
      final ant = izquierda ? _izqAnt : _derAnt;
      final antMs = izquierda ? _izqMs : _derMs;
      if (ant != null && antMs != null) {
        final dt = t - antMs;
        // Timestamp repetido o hacia atrás: sin dato. Hueco largo: la mano
        // reapareció, no es movimiento.
        if (dt > 0 && dt <= 250) {
          final len = ant.length < act.length ? ant.length : act.length;
          var s = 0.0;
          for (var i = 0; i < len; i++) {
            s += (act[i][0] - ant[i][0]).abs();
            s += (act[i][1] - ant[i][1]).abs();
          }
          if (len > 0) {
            // Llevado a "por frame de 30 FPS".
            suma += s / (2 * len) * _msPorFrameReferencia / dt.clamp(10, 200);
            n++;
          }
        }
      }
      if (izquierda) {
        _izqAnt = act;
        _izqMs = t;
      } else {
        _derAnt = act;
        _derMs = t;
      }
    }

    mano(frame.left, true);
    mano(frame.right, false);
    if (anterior == null) return;

    final crudoMs = t - anterior.timestampMs;
    final dtMs = crudoMs > 0
        ? crudoMs.clamp(10, 200).toDouble()
        : _msPorFrameReferencia;
    final mov = n > 0 ? suma / n : 0.0;
    _avanzar(mov > umbralMovimiento, dtMs, t);
  }

  List<List<double>>? _izqAnt;
  List<List<double>>? _derAnt;
  int? _izqMs;
  int? _derMs;

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
      if (!hayMovimiento) {
        _inicioRachaMs = null;
      } else {
        final inicio = _inicioRachaMs ??= timestampMs;
        if (timestampMs - inicio >= msMovimientoParaIniciar) {
          _inicioRachaMs = null;
          _msQuietos = 0;
          _cambiarEstado(EstadoAuto.grabando);
          onInicioDetectado?.call();
        }
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
      alVolverAQuieto?.call();
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
    _izqAnt = null;
    _derAnt = null;
    _izqMs = null;
    _derMs = null;
    _ultimoAlimentadoMs = null;
    _msQuietos = 0;
    _inicioRachaMs = null;
  }
}
