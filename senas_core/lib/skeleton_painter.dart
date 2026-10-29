/// Pintor del esqueleto y pantalla de reconocimiento en vivo.
///
/// El pintor se usa con un ValueNotifier<LandmarkFrame> para que solo se
/// repinte cuando cambian los landmarks, no en cada setState.

import 'dart:async';

import 'package:flutter/material.dart';

import 'avatar_bridge.dart';
import 'avatar_vista.dart';
import 'avatar_vivo.dart';
import 'backend_api.dart';
import 'camera_bridge.dart';
import 'controlador_captura.dart';
import 'dtw.dart';
import 'modo_desarrollador.dart';
import 'muestras_locales.dart';
import 'plantillas.dart';
import 'reconocer/carga_camara.dart';
import 'reconocer/disposicion_reconocer.dart';
import 'reconocer/encabezado_reconocer.dart';
import 'reconocer/guia_encuadre.dart';
import 'reconocer/guia_inicial.dart';
import 'reconocer/tarjeta_resultado.dart';
import 'voz.dart';
import 'sesion_automatica.dart';

/// Texto corto para el usuario cuando un intento no llega al clasificador.
/// Los motivos son los mismos que se registran en la sesion.
String? pistaParaResultado(String motivo) => switch (motivo) {
      'muy_corta' => 'Seña muy corta. Repítela un poco más lenta.',
      'vacia' => 'No vi tus manos. Ponte frente a la cámara.',
      'sin_diccionario' => 'Aún no hay señas cargadas.',
      _ => null,
    };

/// Cuanto dura en pantalla la pista de [pistaParaResultado].
const Duration kDuracionPista = Duration(milliseconds: 2500);

/// Pista transitoria: [mostrar] la deja [kDuracionPista] y se borra sola;
/// [alCambiar] avisa a la pantalla para repintar.
class PistaTemporal {
  final VoidCallback alCambiar;
  String? texto;
  Timer? _temporizador;

  PistaTemporal({required this.alCambiar});

  void mostrar(String motivo) {
    _temporizador?.cancel();
    texto = pistaParaResultado(motivo);
    alCambiar();
    _temporizador = Timer(kDuracionPista, () {
      texto = null;
      alCambiar();
    });
  }

  /// Quita la pista ya (otro modo, otra sena en curso).
  void limpiar() {
    _temporizador?.cancel();
    _temporizador = null;
    if (texto == null) return;
    texto = null;
    alCambiar();
  }

  void dispose() => _temporizador?.cancel();
}

class SkeletonPainter extends CustomPainter {
  final LandmarkFrame? frame;

  /// Dibuja los puntos volteados de izquierda a derecha, como en un espejo.
  /// Va junto con voltear la imagen de la camara (ver PantallaDeTranslacion):
  /// si solo se volteara uno de los dos, el esqueleto no caeria sobre la
  /// persona. Las etiquetas I/D siguen siendo el lado real de la persona.
  final bool espejo;

  static const double _minVisibility = 0.5;

  static const _colorCuerpo = Color(0xFF4A90E2);
  static const _colorIzquierda = Color(0xFFFFA726);
  static const _colorDerecha = Color(0xFF42A5F5);

  SkeletonPainter({this.frame, this.espejo = false});

  @override
  void paint(Canvas canvas, Size size) {
    if (frame == null || frame!.pose == null) return;

    final pose = frame!.pose!;

    // Pinta el cuerpo: cabeza, hombros, brazos, cadera
    _paintCuerpo(canvas, pose, size);

    // Pinta las manos
    if (frame!.left != null) {
      _paintMano(canvas, frame!.left!, size,
          color: _colorIzquierda, etiqueta: 'I');
    }
    if (frame!.right != null) {
      _paintMano(canvas, frame!.right!, size,
          color: _colorDerecha, etiqueta: 'D');
    }
  }

  void _paintCuerpo(Canvas canvas, List<List<double>> pose, Size size) {
    final paint = Paint()
      ..color = _colorCuerpo
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;

    final puntoPaint = Paint()
      ..color = _colorCuerpo
      ..style = PaintingStyle.fill;

    // Indices reales de MediaPipe Pose (33 puntos, orden estandar de
    // BlazePose). LandmarkEngine.kt manda el arreglo crudo sin remapear.
    // Solo se dibuja la mitad superior (relevante para senas): cara,
    // hombros y brazos. Sin caderas/piernas a proposito.
    //
    // 0 nariz, 2/5 ojo izq/der, 7/8 oreja izq/der, 9/10 comisura boca
    // izq/der (MediaPipe no tiene un punto de menton propiamente; las
    // comisuras de la boca son la aproximacion mas cercana que existe),
    // 11/12 hombro izq/der, 13/14 codo izq/der, 15/16 muneca izq/der.
    const ramas = [
      (0, 2), // nariz - ojo izq
      (2, 7), // ojo izq - oreja izq
      (0, 5), // nariz - ojo der
      (5, 8), // ojo der - oreja der
      (0, 9), // nariz - comisura boca izq (zona menton)
      (0, 10), // nariz - comisura boca der (zona menton)
      (11, 12), // hombro izq - der
      (11, 13), // hombro izq - codo izq
      (13, 15), // codo izq - muneca izq
      (12, 14), // hombro der - codo der
      (14, 16), // codo der - muneca der
    ];

    for (final (a, b) in ramas) {
      if (a >= pose.length || b >= pose.length) continue;
      final pa = pose[a];
      final pb = pose[b];
      if (pa.length < 4 || pb.length < 4) continue;
      if (pa[3] < _minVisibility || pb[3] < _minVisibility) continue;
      if (!_puntoEnCuadro(pa) || !_puntoEnCuadro(pb)) continue;

      canvas.drawLine(
        _punto(pa, size),
        _punto(pb, size),
        paint,
      );
    }

    // Mismo criterio que ramas: solo los puntos de la mitad superior que
    // realmente usamos, no los 33 (si no, quedaban puntos sueltos de
    // cadera/pierna sin ninguna linea conectandolos).
    const puntosUsados = {0, 2, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};
    for (final i in puntosUsados) {
      if (i >= pose.length) continue;
      final p = pose[i];
      if (p.length < 4 || p[3] < _minVisibility) continue;
      if (!_puntoEnCuadro(p)) continue;
      canvas.drawCircle(_punto(p, size), 3, puntoPaint);
    }

    // La cadena Pose -> mano queda identificable incluso cuando la imagen
    // frontal se interpreta al revés. I/D son lados anatómicos de la persona.
    _paintLado(canvas, pose, size, 11, 13, 15, _colorIzquierda, 'H-I', 'I');
    _paintLado(canvas, pose, size, 12, 14, 16, _colorDerecha, 'H-D', 'D');
  }

  void _paintLado(
      Canvas canvas,
      List<List<double>> pose,
      Size size,
      int hombro,
      int codo,
      int muneca,
      Color color,
      String etiquetaHombro,
      String etiquetaMuneca) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    void line(int a, int b) {
      if (a >= pose.length || b >= pose.length) return;
      final pa = pose[a], pb = pose[b];
      if (pa.length < 4 ||
          pb.length < 4 ||
          pa[3] < _minVisibility ||
          pb[3] < _minVisibility ||
          !_puntoEnCuadro(pa) ||
          !_puntoEnCuadro(pb)) return;
      canvas.drawLine(_punto(pa, size), _punto(pb, size), paint);
    }

    line(hombro, codo);
    line(codo, muneca);
    if (hombro < pose.length) {
      _paintEtiqueta(canvas, pose[hombro], size, etiquetaHombro, color);
    }
    if (muneca < pose.length) {
      _paintEtiqueta(canvas, pose[muneca], size, etiquetaMuneca, color);
    }
  }

  void _paintEtiqueta(
      Canvas canvas, List<double> p, Size size, String texto, Color color) {
    if (!_puntoEnCuadro(p)) return;
    final painter = TextPainter(
      text: TextSpan(
        text: texto,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          backgroundColor: Colors.black54,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, _punto(p, size) + Offset(4, -painter.height - 2));
  }

  void _paintMano(
    Canvas canvas,
    List<List<double>> mano,
    Size size, {
    required Color color,
    required String etiqueta,
  }) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;

    final puntoPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    // MediaPipe Hand: conexiones entre dedos (ver el modelo oficial)
    // Palma: 0-5, 5-9, 9-13, 13-17, 17-0
    // Dedos: 1-2-3-4, 5-6-7-8, 9-10-11-12, 13-14-15-16, 17-18-19-20
    const conexiones = [
      (0, 1),
      (1, 2),
      (2, 3),
      (3, 4),
      (0, 5),
      (5, 6),
      (6, 7),
      (7, 8),
      (5, 9),
      (9, 10),
      (10, 11),
      (11, 12),
      (9, 13),
      (13, 14),
      (14, 15),
      (15, 16),
      (13, 17),
      (17, 18),
      (18, 19),
      (19, 20),
      (0, 17),
    ];

    for (final (a, b) in conexiones) {
      if (a >= mano.length || b >= mano.length) continue;
      final pa = mano[a];
      final pb = mano[b];
      if (pa.length < 3 || pb.length < 3) continue;
      if (!_puntoEnCuadro(pa) || !_puntoEnCuadro(pb)) continue;

      canvas.drawLine(
        _punto3d(pa, size),
        _punto3d(pb, size),
        paint,
      );
    }

    for (final p in mano) {
      if (p.length < 3) continue;
      if (!_puntoEnCuadro(p)) continue;
      canvas.drawCircle(_punto3d(p, size), 2, puntoPaint);
    }
    if (mano.isNotEmpty)
      _paintEtiqueta(canvas, mano.first, size, etiqueta, color);
  }

  bool _puntoEnCuadro(List<double> p) =>
      p.length >= 3 &&
      p[0].isFinite &&
      p[1].isFinite &&
      p[2].isFinite &&
      p[0] >= 0 &&
      p[0] <= 1 &&
      p[1] >= 0 &&
      p[1] <= 1;

  Offset _punto(List<double> p, Size size) {
    final x = espejo ? 1.0 - p[0] : p[0];
    return Offset(x * size.width, p[1] * size.height);
  }

  Offset _punto3d(List<double> p, Size size) => _punto(p, size);

  @override
  bool shouldRepaint(SkeletonPainter old) =>
      old.frame?.timestampMs != frame?.timestampMs || old.espejo != espejo;
}

/// Camara en vivo + reconocimiento contra el diccionario local. El avatar
/// muestra el movimiento con el mismo sistema del laboratorio web (visor en
/// WebView) y su quieto/movimiento adaptativo corta las senas en modo
/// automatico. El reconocimiento sigue sobre el vector crudo: las plantillas
/// se grabaron crudas.
/// Pre-roll de la grabacion automatica: el detector avisa el inicio cuando
/// la sena ya arranco (primer frame con movimiento).
const int kPreRollMs = 200;

/// Cola que se conserva despues del ultimo movimiento: el detector necesita
/// ~0.33 s quieto para declarar el fin y esa quietud no es parte de la sena.
const int kColaMs = 100;

class PantallaDeTranslacion extends StatefulWidget {
  const PantallaDeTranslacion({Key? key}) : super(key: key);

  @override
  State<PantallaDeTranslacion> createState() => _PantallaDeTranslacionState();
}

class _PantallaDeTranslacionState extends State<PantallaDeTranslacion>
    with WidgetsBindingObserver {
  final _ctrl = ControladorCaptura();
  final _almacen = AlmacenMuestras.instancia;
  final _voz = LectorVoz.instancia;
  final _backend = BackendApi();
  final _bridge = AvatarBridge();
  late final _alimentador = AlimentadorAvatar(
    enviar: _bridge.mostrarFrame,
  );
  StreamSubscription<LandmarkFrame>? _subAvatar;
  StreamSubscription<LandmarkFrame>? _subSinMano;
  final _detector = DetectorAutomatico(
    // Menos frames quietos para cortar = reconoce mas rapido despues de
    // terminar la sena, a costa de ser un poco mas sensible a una micro
    // pausa en medio de un movimiento largo. 10 frames a ~30fps son ~0.33s.
    framesQuietosParaCortar: 10,
  );

  /// De donde sale el movimiento del modo automatico: el visor cuando el
  /// avatar esta listo, los frames de preview cuando no.
  late final _fuente = FuenteMovimientoAuto(_detector);

  Diccionario? _dicc;
  String? _errorDiccionario;
  Prediction? _prediccion;
  List<MapEntry<double, Template>> _candidatas = const [];
  String? _aviso;

  /// Pista transitoria del modo automatico (ver [pistaParaResultado]).
  late final _pista = PistaTemporal(alCambiar: () {
    if (mounted) setState(() {});
  });
  BackendPrediction? _prediccionBackend;
  int _consultaBackend = 0;

  // ── Presentacion del resultado (no cambia el reconocimiento) ─────────────
  /// Sube con cada resultado: la tarjeta nueva entra animada y vibra.
  int _intento = 0;

  /// Alternativa que la persona eligio para corregir el resultado.
  Template? _elegida;

  /// "Ver en avatar": mientras el visor reproduce la plantilla no le llegan
  /// frames en vivo (lo cortarian) ni cuenta su movimiento para el modo
  /// automatico.
  bool _reproduciendoPlantilla = false;
  Timer? _finReproduccion;

  /// Guia de la primera vez (coach marks).
  final _guia = ControladorGuiaInicial();

  // ── Modo automático ──────────────────────────────────────────────────────
  bool _modoAuto = false;
  EstadoAuto _estadoAuto = EstadoAuto.quieto;

  // ── Volteo de cámara ─────────────────────────────────────────────────────
  bool _volteando = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ctrl.addListener(_alCambiar);
    _detector.onCambioEstado = (e) {
      if (mounted) setState(() => _estadoAuto = e);
    };
    _detector.onInicioDetectado = _autoIniciar;
    _detector.onFinDetectado = _autoFinalizar;
    _bridge.onPerf = (perf) => _ctrl.sesion?.evento('perf', perf);
    // Errores sueltos del visor (no tumban el avatar): a la sesion.
    _bridge.onErrorVisor = (detalle) {
      final sesion = _ctrl.sesion;
      if (sesion != null) {
        sesion.evento('error_visor', {'detalle': detalle});
      } else {
        debugPrint('visor avatar: $detalle');
      }
    };
    _bridge.onMovimiento = (m) {
      if (_modoAuto && !_reproduciendoPlantilla) {
        _fuente.alMovimientoVisor(
            hayMovimiento: m.hayMovimiento, timestampMs: m.timestampMs);
      }
    };
    _bridge.estado.addListener(_alCambiarEstadoVisor);
    _bridge.onTerminado = _alTerminarReproduccion;
    _arrancar();
  }

  Future<void> _arrancar() async {
    await _almacen.cargar();
    if (!mounted) return;
    await _ctrl.iniciar(
      frontal: _almacen.ajustes.camaraFrontal,
      cruzarManos: _almacen.ajustes.cruzarManos,
    );
    if (!mounted) return;
    if (_ctrl.lista) {
      final sesionActiva = await activarSesionConConsentimiento(
          context, _ctrl, _almacen,
          pantalla: 'traduccion');
      if (!mounted) return;
      await _iniciarAvatar(sesionActiva);
      if (!mounted) return;
      // Despues del consentimiento: nunca dos capas a la vez.
      await _guia.mostrarSiPrimeraVez();
      if (!mounted) return;
    }
    // Si ya estábamos en modo auto antes de que la cámara terminara de iniciar,
    // arrancamos el detector ahora que el stream está disponible.
    if (_modoAuto) _iniciarDetector();
    try {
      final d = await cargarDiccionario();
      if (!mounted) return;
      setState(() {
        _dicc = d;
        _errorDiccionario = d.resumen.vacio
            ? 'Aún no hay señas cargadas. '
                'Conéctate a internet y abre Sincronizar, o reinstala la app.'
            : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorDiccionario =
          'No se pudo cargar el diccionario local. Reintenta más tarde.');
    }
  }

  void _alCambiar() {
    if (mounted) setState(() {});
  }

  /// Cambia entre camara frontal y trasera sin salir de la pantalla, y deja
  /// el nuevo lado guardado en Ajustes para la proxima vez. No se permite en
  /// modo automatico ni mientras se esta grabando una seña: cortaria la
  /// captura a mitad de camino.
  Future<void> _voltearCamara() async {
    if (_volteando || _modoAuto || _ctrl.grabando || !_ctrl.lista) return;
    setState(() => _volteando = true);
    final frontal = !_almacen.ajustes.camaraFrontal;
    try {
      await _ctrl.reiniciar(
        frontal: frontal,
        cruzarManos: _almacen.ajustes.cruzarManos,
      );
      // Copia al guardar, no antes del await: un perfil corporal medido
      // mientras la camara reiniciaba se perderia.
      await _almacen.guardarAjustes(
          _almacen.ajustes.copiar()..camaraFrontal = frontal);
    } finally {
      if (mounted) setState(() => _volteando = false);
    }
  }

  // ── Modo automático: activar/desactivar ───────────────────────────────────

  Future<void> _toggleModoAuto() async {
    if (_modoAuto) {
      // Desactivar: si estaba grabando, cancelar sin reconocer.
      if (_ctrl.grabando) await _ctrl.terminar();
      await _fuente.detener();
      setState(() {
        _modoAuto = false;
        _estadoAuto = EstadoAuto.quieto;
      });
      _pista.limpiar();
    } else {
      setState(() {
        _modoAuto = true;
        _prediccion = null;
        _elegida = null;
        _candidatas = const [];
        _aviso = null;
      });
      _pista.limpiar();
      // Solo arrancamos el detector si la cámara ya está lista.
      if (_ctrl.lista) _iniciarDetector();
    }
  }

  /// Avatar en vista espejo (eres tú), con los frames fusionados como en
  /// Espejo, sin modo diagnóstico.
  Future<void> _iniciarAvatar(bool sesionActiva) async {
    if (!_bridge.disponible) return;
    try {
      await _bridge.configurarSesion(sesionActiva);
      await _bridge.configurarRig(_almacen.ajustes.rigCalibration);
      await _bridge.configurarVista(espejo: true);
      await _bridge.configurarDiagnostico(false);
      await _bridge.configurarMovimiento(true);
    } catch (_) {
      // El avatar es ayuda visual: si el visor no responde, reconocer sigue.
    }
    await _subAvatar?.cancel();
    _subAvatar =
        _ctrl.camara.frames.listen(_alimentador.alFrame, onError: _errorStream);
    _alimentador.iniciar();
    // Sin pose usable el visor no recibe frames y no manda motion: si la
    // persona sale de cuadro grabando, el preview sin mano o sin pose cuenta
    // como quieto para que la seña se corte como antes.
    await _subSinMano?.cancel();
    _subSinMano = _ctrl.camara.framesPreview.listen((f) {
      if (_modoAuto) _fuente.alPreviewSinMano(f);
    }, onError: _errorStream);
  }

  /// Error del stream nativo. El controlador lo clasifica, lo registra en la
  /// sesion y, si es grave, deja la camara en error (texto amable +
  /// Reintentar en [_contenido]); aqui solo se evita que llegue sin manejar.
  void _errorStream(Object error, StackTrace _) =>
      debugPrint('stream de landmarks: $error');

  bool get _visorListo =>
      _bridge.disponible && _bridge.estado.value == EstadoAvatar.listo;

  /// Con el avatar listo, el inicio y fin de la seña salen de su quieto/
  /// movimiento adaptativo (llega por onMovimiento); sin el (sin visor,
  /// cargando, con error o caido) del detector propio sobre el preview.
  Future<void> _iniciarDetector() =>
      _fuente.iniciar(_ctrl.camara.framesPreview, visorListo: _visorListo);

  /// El avatar cambio de estado (cargo, fallo, se reintento): cambia la
  /// fuente del modo automatico sin duplicar el conteo.
  void _alCambiarEstadoVisor() {
    if (!mounted || !_modoAuto || !_fuente.activa) return;
    _fuente.visorCambio(listo: _visorListo);
  }

  /// Callback: el detector detectó inicio de movimiento.
  void _autoIniciar() {
    if (!mounted || !_ctrl.lista || _ctrl.grabando) return;
    _pista.limpiar();
    _ctrl.empezar(preRollMs: kPreRollMs);
  }

  /// Callback: el detector detectó fin de movimiento → reconocer.
  void _autoFinalizar() {
    // Lanzamos el proceso asíncrono sin await porque este callback es síncrono.
    _procesarFinAuto();
  }

  Future<void> _procesarFinAuto() async {
    final ultimoMovimiento = _detector.ultimoMovimientoMs;
    final seq = await _ctrl.terminar(
        hastaMs: ultimoMovimiento == null ? null : ultimoMovimiento + kColaMs);
    if (!mounted) return;
    final nFrames = _ctrl.framesGrabados;

    // Secuencia demasiado corta, vacía o sin diccionario: no se clasifica;
    // se limpia el resultado anterior y se da una pista (y queda en la
    // sesion).
    final motivo = seq == null
        ? 'vacia'
        : nFrames < _detector.minFramesParaReconocer
            ? 'muy_corta'
            : _dicc == null
                ? 'sin_diccionario'
                : null;
    if (motivo != null) {
      // Invalida tambien la consulta al backend en vuelo: su respuesta tardia
      // no debe repoblar el resultado que se acaba de limpiar.
      _consultaBackend++;
      setState(() {
        _prediccion = null;
        _elegida = null;
        _prediccionBackend = null;
        _candidatas = const [];
      });
      _pista.mostrar(motivo);
      _registrarReconocimiento('auto', nFrames, motivo: motivo);
      _detector.entrarPausa(const Duration(milliseconds: 300), () {
        if (mounted) setState(() {});
      });
      return;
    }

    _pista.limpiar();
    _reconocer(seq!, modo: 'auto', frames: nFrames);

    // Pausa corta para encadenar senas seguidas en una conversacion, sin
    // dejar de darle un instante al usuario para ver/escuchar el resultado.
    _detector.entrarPausa(const Duration(milliseconds: 900), () {
      if (mounted) setState(() {});
    });
  }

  /// Un solo DTW por intento: el ranking da la decision y las candidatas
  /// que se muestran.
  void _reconocer(List<List<double>> seq,
      {required String modo, required int frames}) {
    final clasificador = _dicc!.clasificador;
    final reloj = Stopwatch()..start();
    final ranking = clasificador.rank(seq);
    final pred = clasificador.classifyRanking(ranking);
    reloj.stop();
    final dtwMs = reloj.elapsedMicroseconds / 1000;

    final vistas = <String>{};
    final unicas = <MapEntry<double, Template>>[];
    for (final e in ranking) {
      if (vistas.add(e.value.gloss)) unicas.add(e);
      if (unicas.length >= 4) break;
    }

    setState(() {
      _prediccion = pred;
      _elegida = null;
      _intento++;
      _prediccionBackend = null;
      _candidatas = unicas;
      _aviso = null;
    });
    _registrarReconocimiento(modo, frames,
        pred: pred, candidatas: unicas, dtwMs: dtwMs);
    _consultarBackend(seq);

    if (pred.aceptada && _almacen.ajustes.hablarResultado) {
      _hablar(pred.textoHablado);
    }
  }

  /// Evento de sesion por intento (tools/analizar_sesion.py lo resume).
  void _registrarReconocimiento(String modo, int frames,
      {Prediction? pred,
      List<MapEntry<double, Template>> candidatas = const [],
      String? motivo,
      double? dtwMs}) {
    double? finito(double v) => v.isFinite ? v : null;
    _ctrl.sesion?.evento('reconocimiento', {
      'modo': modo,
      'frames': frames,
      if (dtwMs != null) 'dtw_ms': double.parse(dtwMs.toStringAsFixed(2)),
      if (motivo != null) 'motivo': motivo,
      'aceptada': pred?.aceptada ?? false,
      if (pred != null) ...{
        'gloss': pred.gloss,
        'distancia': finito(pred.distance),
        'margen': finito(pred.margin),
      },
      if (candidatas.isNotEmpty)
        'top': [
          for (final e in candidatas)
            {'gloss': e.value.gloss, 'd': finito(e.key)},
        ],
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ctrl.removeListener(_alCambiar);
    _subAvatar?.cancel();
    _subSinMano?.cancel();
    _pista.dispose();
    _finReproduccion?.cancel();
    _guia.dispose();
    _alimentador.detener();
    _bridge.estado.removeListener(_alCambiarEstadoVisor);
    _bridge.dispose();
    _fuente.detener();
    _ctrl.dispose();
    _backend.cerrar();
    _voz.detener();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _ctrl.error != null) {
      _arrancar();
    }
  }

  // ── Modo manual: alternar grabación ──────────────────────────────────────

  Future<void> _alternar() async {
    if (!_ctrl.grabando) {
      setState(() {
        _prediccion = null;
        _elegida = null;
        _prediccionBackend = null;
        _candidatas = const [];
        _aviso = null;
      });
      _ctrl.empezar();
      return;
    }

    final seq = await _ctrl.terminar();
    if (!mounted) return;
    final nFrames = _ctrl.framesGrabados;

    if (_dicc == null) {
      setState(() => _aviso = pistaParaResultado('sin_diccionario'));
      _registrarReconocimiento('manual', nFrames, motivo: 'sin_diccionario');
      return;
    }
    if (seq == null) {
      setState(() => _aviso = pistaParaResultado('vacia'));
      _registrarReconocimiento('manual', nFrames, motivo: 'vacia');
      return;
    }
    // Mismo minimo que el modo automatico: con menos frames validos el DTW
    // compara casi un solo instante y responde cualquier cosa.
    if (nFrames < _detector.minFramesParaReconocer) {
      setState(() => _aviso = pistaParaResultado('muy_corta'));
      _registrarReconocimiento('manual', nFrames, motivo: 'muy_corta');
      return;
    }

    _reconocer(seq, modo: 'manual', frames: nFrames);
  }

  /// La persona toco una alternativa: se muestra esa y queda en la sesion
  /// (tools/analizar_sesion.py) para saber donde se equivoca el reconocedor.
  void _corregir(Template t) {
    final original = _prediccion;
    if (original == null) return;
    setState(() => _elegida = t);
    _ctrl.sesion?.evento('correccion_usuario', {
      'gloss': t.gloss,
      'original': original.gloss,
      'aceptada_original': original.aceptada,
    });
    if (_almacen.ajustes.hablarResultado) _hablar(textoDePlantilla(t));
  }

  /// Plantilla de lo que se muestra: la elegida o la ganadora aceptada (la
  /// primera del ranking).
  Template? get _plantillaMostrada {
    if (_elegida != null) return _elegida;
    final pred = _prediccion;
    if (pred == null || !pred.aceptada || _candidatas.isEmpty) return null;
    return _candidatas.first.value;
  }

  /// Reproduce en el avatar la plantilla de la sena mostrada. El espejo en
  /// vivo se pausa (cada frame cortaria la reproduccion) y vuelve cuando el
  /// visor avisa el fin, o a los 6 s si no avisa.
  Future<void> _verEnAvatar() async {
    final t = _plantillaMostrada;
    if (t == null || _reproduciendoPlantilla || _ctrl.grabando) return;
    setState(() => _reproduciendoPlantilla = true);
    _alimentador.detener();
    _finReproduccion?.cancel();
    _finReproduccion =
        Timer(const Duration(seconds: 6), _alTerminarReproduccion);
    try {
      await _bridge.reproducir(t.seq);
    } catch (_) {
      _alTerminarReproduccion();
    }
  }

  void _alTerminarReproduccion() {
    _finReproduccion?.cancel();
    _finReproduccion = null;
    if (!mounted || !_reproduciendoPlantilla) return;
    setState(() => _reproduciendoPlantilla = false);
    _alimentador.iniciar();
  }

  void _hablar(String texto) {
    _voz.decir(texto).then((error) {
      if (error == null || !mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo hablar el resultado: $error')),
      );
    });
  }

  Future<void> _consultarBackend(List<List<double>> seq) async {
    if (!_backend.configurado) return;
    final revision = ++_consultaBackend;
    try {
      final resultado = await _backend.clasificar(seq);
      if (!mounted || revision != _consultaBackend) return;
      setState(() => _prediccionBackend = resultado);
    } catch (_) {
      // DTW local ya entregó resultado; caída de red nunca bloquea voz ni UI.
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Los numeros de diagnostico aparecen y se van al cambiar el modo
    // desarrollador sin salir de la pantalla.
    return ValueListenableBuilder<bool>(
      valueListenable: ModoDesarrollador.notificador,
      builder: (context, dev, _) => Scaffold(
        appBar: AppBar(
          title: EncabezadoReconocer(
              resumen: _dicc?.resumen, desarrollador: dev),
          centerTitle: true,
          toolbarHeight: dev ? 92 : 64,
          actions: [
            IconButton(
              icon: const Icon(Icons.info_outline),
              tooltip: 'Cómo funciona',
              onPressed: _guia.abrir,
            ),
          ],
        ),
        body: CapaGuiaInicial(
          controlador: _guia,
          child: Column(
            children: [
              _franjaControles(),
              Expanded(child: _contenido(dev)),
              _barraAccion(dev),
            ],
          ),
        ),
      ),
    );
  }

  /// Modo y camara, fuera del AppBar para que Honor no la tape.
  Widget _franjaControles() {
    final colores = Theme.of(context).colorScheme;
    return Container(
      color: colores.surfaceContainerHigh,
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: SelectorModo(
                automatico: _modoAuto,
                onCambiar: (_) => _toggleModoAuto(),
              ),
            ),
          ),
          const SizedBox(width: 4),
          _botonVoltear(),
        ],
      ),
    );
  }

  /// Cambiar de camara; deshabilitado, el tooltip dice por que.
  Widget _botonVoltear() {
    final colores = Theme.of(context).colorScheme;
    final motivo = _modoAuto
        ? 'Pasa a Manual para cambiar de cámara'
        : _ctrl.grabando
            ? 'Termina de grabar para cambiar de cámara'
            : !_ctrl.lista
                ? 'Espera a que la cámara esté lista'
                : null;
    return IconButton(
      iconSize: 26,
      icon: _volteando
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(Icons.cameraswitch_outlined,
              color: motivo != null ? colores.outline : colores.primary),
      tooltip: motivo ??
          (_almacen.ajustes.camaraFrontal
              ? 'Cambiar a cámara trasera'
              : 'Cambiar a cámara frontal'),
      onPressed: motivo != null ? null : _voltearCamara,
    );
  }

  /// Avatar, camara y resultado: el acomodo vive en DisposicionReconocer
  /// (camara siempre junto al avatar, nunca encima: el WebView la taparia).
  Widget _contenido(bool dev) {
    if (_ctrl.error != null) return _errorCamara();
    return DisposicionReconocer(
      avatar: _bridge.disponible ? VistaAvatar(bridge: _bridge) : null,
      camara: (compacta) => _vistaCamara(dev, compacta: compacta),
      panel: _panelResultado(dev),
      aspectoCamara: _ctrl.iniciada?.relacionAspecto ?? 3 / 4,
    );
  }

  /// Error bloqueante de la camara (fatal, sin imagen o estancada) con su
  /// texto amable y Reintentar.
  Widget _errorCamara() {
    final tema = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.videocam_off_outlined,
                size: 48, color: tema.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(_ctrl.error!,
                textAlign: TextAlign.center,
                style: tema.textTheme.titleMedium),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _arrancar,
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      ),
    );
  }

  /// Camara con esqueleto, guia de encuadre e indicador de grabacion.
  /// [compacta]: la ventanita del telefono vertical (ya recortada).
  Widget _vistaCamara(bool dev, {bool compacta = false}) {
    final camara = _ctrl.iniciada;
    if (camara == null) return CargaCamara(compacta: compacta);
    final vista = AspectRatio(
      aspectRatio: camara.relacionAspecto,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Camara frontal = vista de espejo: se voltea la imagen y, con ella,
          // los puntos del esqueleto (solo presentacion; el reconocimiento
          // y el avatar siguen sin voltear).
          Transform.flip(
            flipX: camara.frontal,
            child: Texture(textureId: camara.textureId),
          ),
          ValueListenableBuilder<LandmarkFrame?>(
            valueListenable: _ctrl.frame,
            builder: (_, frame, __) => CustomPaint(
              painter:
                  SkeletonPainter(frame: frame, espejo: camara.frontal),
              size: Size.infinite,
            ),
          ),
          GuiaEncuadre(frame: _ctrl.frame),
          if (_ctrl.grabando)
            Positioned(left: 8, bottom: 8, child: _chipGrabando(dev)),
        ],
      ),
    );
    return compacta ? vista : Center(child: vista);
  }

  Widget _chipGrabando(bool dev) {
    final colores = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: colores.error,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.fiber_manual_record, size: 12, color: colores.onError),
          const SizedBox(width: 4),
          Text(dev ? '${_ctrl.framesGrabados} frames' : 'Grabando',
              style: TextStyle(color: colores.onError, fontSize: 12)),
        ],
      ),
    );
  }

  /// Resultado, avisos y pistas.
  Widget _panelResultado(bool dev) {
    final colores = Theme.of(context).colorScheme;
    final pred = _prediccion;
    final elegida = _elegida;
    final hayAlgo = pred != null ||
        _aviso != null ||
        _pista.texto != null ||
        _errorDiccionario != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (pred != null)
          TarjetaResultado(
            key: ValueKey('resultado_${_intento}_${elegida?.gloss}'),
            prediccion: pred,
            umbral: _dicc?.clasificador.maxDistance ??
                _almacen.ajustes.maxDistance,
            margenMin:
                _dicc?.clasificador.minMargin ?? _almacen.ajustes.minMargin,
            candidatas: _candidatas,
            elegida: elegida,
            desarrollador: dev,
            onAlternativa: _corregir,
            onHablar: () => _hablar(elegida != null
                ? textoDePlantilla(elegida)
                : pred.textoHablado),
            onVerEnAvatar: _bridge.disponible ? _verEnAvatar : null,
          ),
        // Línea del clasificador remoto: solo con el modo desarrollador.
        if (dev && _prediccionBackend?.label != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Backend: ${_prediccionBackend!.label} · '
              '${(_prediccionBackend!.confidence * 100).round()}% · '
              '${_prediccionBackend!.classifier}',
              style: TextStyle(fontSize: 11, color: colores.onSurfaceVariant),
            ),
          ),
        if (_aviso != null)
          _cinta(_aviso!, colores.tertiaryContainer,
              colores.onTertiaryContainer),
        _pistaTransitoria(),
        if (_errorDiccionario != null)
          _cinta(_errorDiccionario!, colores.inverseSurface,
              colores.onInverseSurface,
              chico: true),
        if (!hayAlgo)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              _modoAuto
                  ? 'Haz una seña frente a la cámara. La reconozco cuando '
                      'terminas.'
                  : 'Toca Grabar seña, haz la seña y luego toca Detener.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: colores.onSurfaceVariant),
            ),
          ),
      ],
    );
  }

  /// Abajo: en Manual el boton de grabar; en Automatico, el estado.
  Widget _barraAccion(bool dev) {
    final colores = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: SizedBox(
          width: double.infinity,
          child: _modoAuto
              ? _estadoAutomatico()
              : FilledButton.icon(
                  onPressed: _ctrl.lista ? _alternar : null,
                  icon: Icon(_ctrl.grabando
                      ? Icons.stop
                      : Icons.fiber_manual_record),
                  label: Text(_ctrl.grabando
                      ? 'Detener y reconocer'
                      : 'Grabar seña'),
                  style: FilledButton.styleFrom(
                    backgroundColor: _ctrl.grabando ? colores.error : null,
                    foregroundColor: _ctrl.grabando ? colores.onError : null,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
        ),
      ),
    );
  }

  /// Estado del modo automatico, con icono y texto (sin emojis).
  Widget _estadoAutomatico() {
    final colores = Theme.of(context).colorScheme;
    final (icono, texto, fondo, tinta) = switch (_estadoAuto) {
      EstadoAuto.quieto => (
          Icons.visibility_outlined,
          'Esperando seña…',
          colores.surfaceContainerHighest,
          colores.onSurfaceVariant
        ),
      EstadoAuto.grabando => (
          Icons.fiber_manual_record,
          'Grabando…',
          colores.error,
          colores.onError
        ),
      EstadoAuto.reconociendo => (
          Icons.search,
          'Reconociendo…',
          colores.primary,
          colores.onPrimary
        ),
      EstadoAuto.pausa => (
          Icons.check_circle_outline,
          'Listo',
          colores.secondaryContainer,
          colores.onSecondaryContainer
        ),
    };
    return Semantics(
      liveRegion: true,
      child: AnimatedContainer(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 200),
        constraints: const BoxConstraints(minHeight: 52),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: fondo,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icono, color: tinta, size: 20),
            const SizedBox(width: 8),
            Text(texto,
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(color: tinta)),
          ],
        ),
      ),
    );
  }

  /// Pista del modo automatico: aparece y se desvanece sola.
  Widget _pistaTransitoria() => AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: _pista.texto == null
            ? const SizedBox.shrink(key: ValueKey('sin_pista'))
            : Padding(
                key: ValueKey(_pista.texto),
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _pista.texto!,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
      );

  Widget _cinta(String texto, Color color, Color sobreColor,
          {bool chico = false}) =>
      Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration:
            BoxDecoration(color: color, borderRadius: BorderRadius.circular(12)),
        child: Text(texto,
            style: TextStyle(color: sobreColor, fontSize: chico ? 12 : 13)),
      );
}
