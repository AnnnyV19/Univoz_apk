/// Puente hacia el visor 3D del avatar (assets/avatar_viewer/index.html).
///
/// El visor corre dentro de un WebView con three.js + three-vrm. Esta clase
/// solo se encarga de:
///   1. Cargar esa pagina.
///   2. Mandarle una secuencia de frames normalizados (el mismo formato de
///      dtw.dart / sign_norm.dart) para que la anime.
///   3. Avisar cuando termina de reproducir, via un JavaScriptChannel.
///
/// Nota sobre el formato de los frames: sign_norm.dart guarda 152 valores por
/// frame. El bloque de cuerpo usa worldLandmarks de MediaPipe proyectados en
/// una base ortonormal 3D; el bloque de manos combina posicion metrica y
/// forma relativa. El visor convierte ese espacio a huesos VRM con IK de dos
/// huesos y orientacion de muneca, sin inventar profundidad fija por brazo.
/// La Z sigue siendo calibrable porque su signo depende de la convención del
/// modelo y de la camara.
///
/// Tambien por construccion de sign_norm.dart: el origen (0,0) es el punto
/// medio entre hombros, el eje X va del hombro izquierdo al derecho, y todo
/// esta escalado para que esa distancia entre hombros mida 1 unidad. Eso
/// quiere decir que, en este espacio normalizado, el hombro izquierdo cae
/// siempre cerca de (-0.5, 0) y el derecho cerca de (0.5, 0) -- son los
/// anclas que usa el IK del lado JavaScript, no hace falta mandarlas.
library avatar_bridge;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show ValueNotifier, debugPrint, kIsWeb, visibleForTesting;
import 'package:flutter/material.dart' show Color;
import 'package:flutter/services.dart' show ByteData, rootBundle;
import 'package:webview_flutter/webview_flutter.dart';

import 'frase_a_senas.dart' show SegmentoFrase;
import 'motion_contract.dart';
import 'sign_norm.dart' show kNormVersion, kTFrames, kFrameDim;
import 'sign_space.dart' show SignSpaceFrame;
import 'avatar_web_bridge.dart';

// Modelo del avatar: MODELO_UNIVOZ_v0.vrm (el de la dueña), con el visor de
// Karim (decisión de la dueña, 2026-10-28: univozM se ve poco).
const String _kRutaAvatar = 'assets/avatar/MODELO_UNIVOZ_v0.vrm';

/// Evento `perf` del visor embebido ('perf:<json>', ver rig_embedded_perf).
/// null si el mensaje no es un objeto JSON: un perf roto no debe tirar nada.
Map<String, dynamic>? decodificarPerf(String mensaje) {
  if (!mensaje.startsWith('perf:')) return null;
  try {
    final valor = jsonDecode(mensaje.substring(5));
    return valor is Map<String, dynamic> ? valor : null;
  } catch (_) {
    return null;
  }
}

/// Quieto/movimiento que calcula el visor por frame en vivo (filtro
/// adaptativo de rig_math.mjs, el mismo del laboratorio web).
class MovimientoVisor {
  final int timestampMs;
  final bool hayMovimiento;

  /// motionScore (cuerpo/muneca) y fingerMotionScore, 0-1.
  final double puntaje;
  final double dedos;
  final bool conMano;

  const MovimientoVisor({
    required this.timestampMs,
    required this.hayMovimiento,
    this.puntaje = 0,
    this.dedos = 0,
    this.conMano = false,
  });
}

/// 'motion:{"t":..,"m":0|1,"s":..,"f":..,"h":bool}'; null si no se entiende.
MovimientoVisor? decodificarMovimiento(String mensaje) {
  if (!mensaje.startsWith('motion:')) return null;
  try {
    final valor = jsonDecode(mensaje.substring(7));
    if (valor is! Map<String, dynamic> || valor['t'] is! num) return null;
    return MovimientoVisor(
      timestampMs: (valor['t'] as num).toInt(),
      hayMovimiento: valor['m'] == 1 || valor['m'] == true,
      puntaje: (valor['s'] as num?)?.toDouble() ?? 0,
      dedos: (valor['f'] as num?)?.toDouble() ?? 0,
      conMano: valor['h'] == true,
    );
  } catch (_) {
    return null;
  }
}

/// Llamada JS defensiva: si el visor todavia no definio la funcion (pagina a
/// medio cargar, recarga en curso) no pasa nada. Sin esto Android devuelve
/// un "Script error." saneado que el visor pintaba como fallo fatal.
String llamadaSegura(String funcion, [String argumentos = '']) =>
    'window.$funcion && window.$funcion($argumentos)';

/// Lo que Dart pidio al visor mientras no estaba listo. Guarda solo el
/// ultimo valor de vista y manos y lo reaplica cuando carga el avatar; los
/// frames en vivo antes de tiempo se descartan (llega otro en 33 ms).
/// Es puro (sin WebView) para poder probarlo.
class ColaPuenteAvatar {
  bool _listo = false;
  String? _vista;
  String? _manos;
  String? _encuadre;

  bool get listo => _listo;
  bool get aceptaFrames => _listo;

  /// JS a correr ya, o null si hay que esperar a js_listo.
  String? vista({required bool espejo}) {
    _vista = llamadaSegura(
        'configurarVista', espejo ? "'espejo'" : "'interlocutor'");
    return _listo ? _vista : null;
  }

  String? manos({required bool izquierda, required bool derecha}) {
    _manos = llamadaSegura('configurarManos', '$izquierda, $derecha');
    return _listo ? _manos : null;
  }

  String? encuadre(String modo) {
    _encuadre = llamadaSegura('encuadrarCamara', "'$modo'");
    return _listo ? _encuadre : null;
  }

  void marcarListo() => _listo = true;

  /// Recarga de la pagina: se vuelve a esperar js_listo sin perder valores.
  void reiniciar() => _listo = false;

  /// Lo pedido antes de js_listo (el mas nuevo de cada uno), en orden.
  List<String> llamadasAlCargar() =>
      [
        if (_vista != null) _vista!,
        if (_manos != null) _manos!,
        if (_encuadre != null) _encuadre!,
      ];
}

/// Estado visible del avatar para la UI (avatar_vista.dart).
enum EstadoAvatar { cargando, listo, error }

/// Motivo corto para la persona; el detalle tecnico va a onErrorVisor.
String motivoErrorAvatar(String detalle) {
  final d = detalle.toLowerCase();
  if (d.contains('tiempo_agotado')) {
    return 'El avatar tardó demasiado en cargar.';
  }
  // El visor va completo dentro de la app (sin CDN): ningun fallo es de red,
  // asi que no se le pide a la persona que revise su internet.
  return 'Ocurrió un problema al preparar el avatar. Toca Reintentar.';
}

class AvatarBridge {
  /// Encuadres de la camara del visor (ver encuadrar()).
  static const String encuadreCintura = 'cintura';
  static const String encuadreCodos = 'codos';

  late final WebViewController? controller;

  bool get disponible => controller != null;
  bool get compatible => disponible || kIsWeb || _ejecutarPrueba != null;

  /// Se llama cuando el visor termina de reproducir la ultima secuencia
  /// mandada. Util para encadenar varias palabras (una frase completa).
  void Function()? onTerminado;

  /// Se llama cuando se captura una pose desde el editor del visor. El texto
  /// que llega es el volcado completo de los huesos movidos, listo para
  /// pegar. La pantalla que lo reciba se encarga de copiarlo al portapapeles.
  void Function(String)? onPoseCapturada;
  void Function(String)? onDiagnosticReport;
  void Function(RigCalibration)? onCalibrationChanged;

  /// Un evento perf por segundo mientras haya sesion (configurarSesion).
  void Function(Map<String, dynamic>)? onPerf;
  bool _sesion = false;

  /// Quieto/movimiento por frame mientras este activo (configurarMovimiento).
  void Function(MovimientoVisor)? onMovimiento;
  bool _movimiento = false;
  RigCalibration _calibracion = const RigCalibration();
  final _cola = ColaPuenteAvatar();
  bool get _jsListo => _cola.listo;
  bool _diagnostico = false;
  bool _calibracionPendiente = false;

  /// cargando hasta que el visor confirma el VRM en escena (avatar_listo);
  /// error solo en fallos reales (pagina, modelo). En web el iframe maneja
  /// su propio aviso, asi que arranca listo.
  final ValueNotifier<EstadoAvatar> estado = ValueNotifier<EstadoAvatar>(
      kIsWeb ? EstadoAvatar.listo : EstadoAvatar.cargando);
  String? _motivoError;
  bool _cerrado = false;
  int _recargas = 0;

  /// Motivo corto del ultimo error, para mostrar debajo del titulo.
  String? get mensajeError => _motivoError;

  /// Errores que NO tumban el avatar (recurso secundario, excepcion JS ya
  /// arrancado). Las pantallas lo guardan como evento de sesion.
  void Function(String)? onErrorVisor;

  /// Sin WebView (pruebas de widget y de la cola). [ejecutar] recibe el JS
  /// que iria al visor y [modelo] reemplaza la lectura del .vrm.
  @visibleForTesting
  AvatarBridge.sinVisor({
    Future<void> Function(String js)? ejecutar,
    Future<ByteData> Function()? modelo,
  })  : _ejecutarPrueba = ejecutar,
        _modeloPrueba = modelo {
    controller = null;
    _armarLimiteCarga();
  }

  /// Sin visor para una pantalla que no muestra el avatar (Traducir una
  /// seña en univoz): no crea el WebView, así no carga three.js de fondo.
  AvatarBridge.apagado()
      : _ejecutarPrueba = null,
        _modeloPrueba = null {
    controller = null;
  }

  AvatarBridge()
      : _ejecutarPrueba = null,
        _modeloPrueba = null {
    if (kIsWeb) {
      controller = null;
      return;
    }
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) => _alPaginaIniciada(),
        onWebResourceError: (error) {
          final detalle = '${error.errorCode} ${error.description}'
              '${error.url == null ? '' : ' ${error.url}'}';
          // Solo la pagina principal es fatal; un recurso secundario roto
          // (una fuente, un modelo opcional) no debe tapar el avatar.
          if (error.isForMainFrame ?? true) {
            _fallar(detalle);
          } else {
            _avisarErrorVisor('recurso: $detalle');
          }
        },
      ))
      ..addJavaScriptChannel(
        'SenasChannel',
        onMessageReceived: (msg) => _alMensaje(msg.message),
      )
      ..loadFlutterAsset('assets/avatar_viewer/index.html');
    _armarLimiteCarga();
  }

  final Future<void> Function(String js)? _ejecutarPrueba;
  final Future<ByteData> Function()? _modeloPrueba;

  /// Si el visor no confirma ni falla en este tiempo, se da por caido (red
  /// colgada, error de arranque saneado). Generoso: el VRM viaja como ~20 MB
  /// de base64 por runJavaScript y un telefono de gama baja tarda.
  static const limiteCarga = Duration(seconds: 45);
  Timer? _limite;

  /// Entre "Reintentar" y el onPageStarted de la recarga, los mensajes de
  /// carga que lleguen son de la pagina vieja.
  bool _esperandoPagina = false;

  @visibleForTesting
  void simularMensaje(String m) => _alMensaje(m);

  @visibleForTesting
  void simularPaginaIniciada() => _alPaginaIniciada();

  void _alPaginaIniciada() => _esperandoPagina = false;

  void _alMensaje(String m) {
    if (m == 'fin') {
      // Dentro de una frase, el 'fin' de cada seña (menos la última) solo
      // da paso a la siguiente; ver reproducirFrase.
      final siguiente = _finSenaDeFrase;
      if (siguiente != null && !siguiente.isCompleted) {
        siguiente.complete();
        return;
      }
      onTerminado?.call();
    } else if (m.startsWith('pose:')) {
      onPoseCapturada?.call(m.substring(5));
    } else if (m.startsWith('diagnostic_report:')) {
      onDiagnosticReport?.call(m.substring(18));
    } else if (m.startsWith('thumb_calibration:')) {
      try {
        final thumbs = jsonDecode(m.substring(18));
        if (thumbs is Map) {
          final left = (thumbs['left'] as Map?)?.cast<String, dynamic>();
          final right = (thumbs['right'] as Map?)?.cast<String, dynamic>();
          if (left != null && right != null) {
            _calibracion = _calibracion.copyWith(
              leftThumb: ThumbCalibration.fromJson(left),
              rightThumb: ThumbCalibration.fromJson(right),
            );
            onCalibrationChanged?.call(_calibracion);
          }
        }
      } catch (_) {
        // Mensaje de diagnóstico corrupto no debe detener avatar.
      }
    } else if (m.startsWith('motion:')) {
      final mov = decodificarMovimiento(m);
      if (mov != null) onMovimiento?.call(mov);
    } else if (m.startsWith('perf:')) {
      final perf = decodificarPerf(m);
      if (perf != null) onPerf?.call(perf);
    } else if (_esperandoPagina &&
        (m == 'js_listo' ||
            m == 'avatar_listo' ||
            m.startsWith('avatar_error:'))) {
      // Restos de la pagina anterior a "Reintentar": la nueva todavia no
      // arranco (onPageStarted), asi que no son de esta carga.
      return;
    } else if (m == 'js_listo') {
      // La pagina ya importo three.js/three-vrm y esta lista para
      // recibir el modelo. Se lo mandamos nosotros en vez de que lo
      // pida por fetch(): mas confiable dentro de un WebView cargado
      // con loadFlutterAsset (ver la nota grande en index.html).
      _cola.marcarListo();
      _cargarAvatar();
    } else if (m == 'avatar_listo') {
      if (!_jsListo) return;
      _motivoError = null;
      _ponerEstado(EstadoAvatar.listo);
    } else if (m.startsWith('avatar_error:')) {
      _fallar(m.substring(13));
    } else if (m.startsWith('js_error:')) {
      _avisarErrorVisor(m.substring(9));
    }
  }

  void _armarLimiteCarga() {
    _limite?.cancel();
    _limite = Timer(limiteCarga, () {
      if (!_cerrado && estado.value == EstadoAvatar.cargando) {
        _fallar('tiempo_agotado');
      }
    });
  }

  Future<void> _js(String codigo) async {
    final webView = controller;
    if (webView != null) {
      await webView.runJavaScript(codigo);
    } else {
      await _ejecutarPrueba?.call(codigo);
    }
  }

  Future<void> _cargarAvatar() async {
    if (controller == null && _ejecutarPrueba == null) return;
    final recarga = _recargas;
    // Si se pidio "Reintentar" a mitad de la carga, la pagina nueva manda su
    // propio js_listo: esta carga se abandona para no meter dos VRM.
    bool vigente() => recarga == _recargas && !_cerrado;
    try {
      final modelo = _modeloPrueba;
      final datos =
          await (modelo != null ? modelo() : rootBundle.load(_kRutaAvatar));
      if (!vigente()) return;
      final b64 = base64Encode(
          datos.buffer.asUint8List(datos.offsetInBytes, datos.lengthInBytes));
      await _js(llamadaSegura('cargarAvatarBase64', "'$b64'"));
      // Cada valor se lee al momento de mandarlo: un configurarX que llegue
      // durante la carga no queda pisado por uno viejo.
      final llamadas = <String Function()>[
        () => llamadaSegura('configurarRig',
            "'${_escapar(jsonEncode(_calibracion.toJson()))}'"),
        () => llamadaSegura('configurarDiagnostico', '$_diagnostico'),
        () => llamadaSegura('configurarSesion', '$_sesion'),
        () => llamadaSegura('configurarMovimiento', '$_movimiento'),
      ];
      for (final llamada in llamadas) {
        if (!vigente()) return;
        await _js(llamada());
      }
      // Vista y manos pedidas antes de que el visor estuviera listo.
      if (!vigente()) return;
      for (var i = 0; i < _cola.llamadasAlCargar().length; i++) {
        await _js(_cola.llamadasAlCargar()[i]);
      }
      if (!vigente()) return;
      if (_calibracionPendiente) {
        _calibracionPendiente = false;
        await _js(llamadaSegura('iniciarCalibracionPulgares'));
      }
    } catch (e) {
      if (vigente()) _fallar('carga: $e');
    }
  }

  void _fallar(String detalle) {
    _avisarErrorVisor(detalle);
    _motivoError = motivoErrorAvatar(detalle);
    _ponerEstado(EstadoAvatar.error);
  }

  // Los mensajes del WebView y la carga async pueden llegar despues de
  // dispose(): un ValueNotifier cerrado no se toca.
  void _ponerEstado(EstadoAvatar nuevo) {
    if (_cerrado) return;
    if (nuevo != EstadoAvatar.cargando) _limite?.cancel();
    estado.value = nuevo;
  }

  void _avisarErrorVisor(String detalle) {
    final cb = onErrorVisor;
    if (cb != null) {
      cb(detalle);
    } else {
      debugPrint('visor avatar: $detalle');
    }
  }

  /// Vuelve a cargar el visor desde cero (boton "Reintentar").
  Future<void> reintentar() async {
    if (_cerrado) return;
    _motivoError = null;
    _cola.reiniciar();
    _recargas++;
    if (kIsWeb) {
      _ponerEstado(EstadoAvatar.listo);
      return;
    }
    _esperandoPagina = controller != null || _ejecutarPrueba != null;
    _ponerEstado(EstadoAvatar.cargando);
    _armarLimiteCarga();
    await controller?.reload();
  }

  /// Elige el encuadre de la camara del visor:
  ///   [encuadreCintura] -- el de siempre (espejo y pantalla del avatar).
  ///   [encuadreCodos]   -- de los codos para arriba y mas cerca; es el de
  ///                        Aprender, que muestra al avatar en una tarjeta chica.
  /// Se puede llamar antes de que el visor este listo: queda en la cola y se
  /// aplica al cargar (igual que configurarVista / configurarManos).
  Future<void> encuadrar(String modo) async {
    final encuadre = modo == encuadreCodos ? encuadreCodos : encuadreCintura;
    if (kIsWeb) {
      postAvatarCommand({'action': 'encuadrar', 'modo': encuadre});
      return;
    }
    final js = _cola.encuadre(encuadre);
    if (js == null) return;
    await _js(js);
  }

  /// Configura adaptación del espacio normalizado al esqueleto VRM.
  Future<void> configurarRig(RigCalibration calibracion) async {
    _calibracion = calibracion;
    if (kIsWeb) {
      postAvatarCommand({
        'action': 'configurarRig',
        'calibration': calibracion.toJson(),
      });
      return;
    }
    if (!_jsListo) return;
    final webView = controller;
    if (webView == null) return;
    await webView.runJavaScript(llamadaSegura(
        'configurarRig', "'${_escapar(jsonEncode(calibracion.toJson()))}'"));
  }

  /// Con movimiento activo el visor manda quieto/movimiento por frame.
  Future<void> configurarMovimiento(bool activo) async {
    _movimiento = activo;
    if (kIsWeb || !_jsListo) return;
    await controller
        ?.runJavaScript(llamadaSegura('configurarMovimiento', '$activo'));
  }

  /// Con sesion activa el visor manda perf cada segundo (onPerf).
  Future<void> configurarSesion(bool activa) async {
    _sesion = activa;
    if (kIsWeb || !_jsListo) return;
    await controller
        ?.runJavaScript(llamadaSegura('configurarSesion', '$activa'));
  }

  Future<void> configurarDiagnostico(bool activo) async {
    _diagnostico = activo;
    if (!_jsListo) return;
    final webView = controller;
    if (webView == null) return;
    await webView
        .runJavaScript(llamadaSegura('configurarDiagnostico', '$activo'));
  }

  Future<void> iniciarCalibracionPulgares() async {
    _calibracionPendiente = true;
    _diagnostico = true;
    if (!_jsListo) return;
    final webView = controller;
    if (webView == null) return;
    _calibracionPendiente = false;
    await webView.runJavaScript(llamadaSegura('configurarDiagnostico', 'true'));
    await webView.runJavaScript(llamadaSegura('iniciarCalibracionPulgares'));
  }

  /// Elige que brazos anima el avatar. Muchas senas de LSM son de una sola
  /// mano, y forzar la otra a seguir landmarks que no estan presentes la hace
  /// temblar sin sentido. El brazo desactivado se queda en reposo.
  ///
  /// Izquierda y derecha son las del AVATAR, no las de quien mira.
  Future<void> configurarManos(
      {bool izquierda = true, bool derecha = true}) async {
    if (kIsWeb) {
      postAvatarCommand({
        'action': 'configurarManos',
        'izquierda': izquierda,
        'derecha': derecha,
      });
      return;
    }
    // Antes de js_listo solo se guarda: _cargarAvatar lo reaplica.
    final js = _cola.manos(izquierda: izquierda, derecha: derecha);
    if (js == null) return;
    await _js(js);
  }

  /// Vista del avatar en vivo. `espejo: true` lo mueve como tu reflejo (para
  /// practicar o verte a ti mismo); `false` (defecto) como una persona frente
  /// a ti, que es lo correcto al traducir para otra persona.
  Future<void> configurarVista({required bool espejo}) async {
    final vista = espejo ? 'espejo' : 'interlocutor';
    if (kIsWeb) {
      postAvatarCommand({'action': 'configurarVista', 'vista': vista});
      return;
    }
    final js = _cola.vista(espejo: espejo);
    if (js == null) return;
    await _js(js);
  }

  /// Reproduce una secuencia completa (lista de frames de 152 dimensiones
  /// cada uno, tal cual Template.seq en dtw.dart / plantillas.dart).
  ///
  /// [signSpace] es la pista opcional de la biblioteca (un SignSpaceFrame o
  /// null por frame): con ella el visor adapta los brazos a las proporciones
  /// del avatar en modo de retarget 'anchors'.
  Future<void> reproducir(List<List<double>> seq,
      {int fps = 30, List<SignSpaceFrame?>? signSpace}) {
    _turnoFrase++;
    _finSenaDeFrase = null;
    return _reproducirInterno(seq, fps: fps, signSpace: signSpace);
  }

  Future<void> _reproducirInterno(List<List<double>> seq,
      {int fps = 30, List<SignSpaceFrame?>? signSpace}) async {
    if (signSpace != null && signSpace.length != seq.length) {
      throw ArgumentError('signSpace debe tener un frame por frame de seq');
    }
    final pista = signSpace?.map((f) => f?.toJson()).toList();
    if (kIsWeb) {
      MotionSequenceV2.fromFrames(seq, fps: fps);
      postAvatarCommand({
        'action': 'reproducir',
        'seq': seq,
        'fps': fps,
        'normVersion': kNormVersion,
        if (pista != null) 'signSpace': pista,
      });
      return;
    }
    if (controller == null && _ejecutarPrueba == null) return;
    final contrato = MotionSequenceV2.fromFrames(seq, fps: fps);
    final json = jsonEncode(seq);
    final pistaJs = pista == null ? 'null' : "'${_escapar(jsonEncode(pista))}'";
    await _js(llamadaSegura('reproducirSecuencia',
        "'${_escapar(json)}',$fps,'$kNormVersion',$pistaJs"));
    // Validación ocurre antes de cruzar WebView; evita mezclar formatos legacy.
    assert(contrato.tFrames == kTFrames &&
        contrato.frames.first.length == kFrameDim);
  }

  /// Reproduce varias señas SEGUIDAS (una frase). El visor de Karim no tiene
  /// frases propias, así que se mandan una por una: cada seña espera el
  /// 'fin' de la anterior. Al acabar la última avisa con [onTerminado], como
  /// una seña sola. Si mientras tanto llega otra frase u otra seña, esta se
  /// deja de mandar.
  Future<void> reproducirFrase(List<SegmentoFrase> segmentos) async {
    if (segmentos.isEmpty) return;
    for (final s in segmentos) {
      // Misma validacion que reproducir(): 32 cuadros de 152 valores.
      final contrato = MotionSequenceV2.fromFrames(s.frames, fps: s.fps);
      if (contrato.tFrames != kTFrames ||
          contrato.frames.first.length != kFrameDim) {
        throw ArgumentError('Cada seña de la frase debe tener $kTFrames '
            'cuadros de $kFrameDim valores.');
      }
    }
    final turno = ++_turnoFrase;
    for (var i = 0; i < segmentos.length; i++) {
      if (turno != _turnoFrase) return;
      final ultima = i == segmentos.length - 1;
      // La última seña avisa con onTerminado como una seña sola.
      final fin = ultima ? null : Completer<void>();
      _finSenaDeFrase = fin;
      await _reproducirInterno(segmentos[i].frames, fps: segmentos[i].fps);
      if (fin == null) return;
      // Una seña dura ~1 s; si el visor no avisa (sin WebView, recarga), no
      // nos quedamos colgados.
      await fin.future.timeout(const Duration(seconds: 6), onTimeout: () {});
    }
  }

  /// Fin de la seña en curso de una frase (null fuera de una frase).
  Completer<void>? _finSenaDeFrase;

  /// Sube con cada frase o seña nueva: la frase anterior deja de mandar.
  int _turnoFrase = 0;

  /// Aplica UN frame al instante, sin cola ni interpolacion. Es lo que usa
  /// el modo espejo (pantalla_espejo.dart) para que el avatar siga a la
  /// camara en vivo. Corta cualquier reproduccion en curso.
  ///
  /// Devuelve cuando el WebView termino de procesarlo, para poder saltar
  /// frames en vez de encolarlos si el telefono no da abasto.
  Future<void> mostrarFrame(
    List<double> v, {
    List<double>? renderFrame,
    int? timestampMs,
    double quality = 1.0,
    Map<String, dynamic>? sourceMeta,
  }) async {
    final webView = controller;
    if (webView == null) return;
    // Antes de js_listo aplicarFrameVivo no existe: el frame se descarta.
    if (!_cola.aceptaFrames) return;
    MotionFrameV2(v);
    if (renderFrame != null) MotionFrameV2(renderFrame);
    final timestamp = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
    final calidad = quality.clamp(0.0, 1.0);
    final renderJson = jsonEncode(renderFrame ?? v);
    final metaJson = jsonEncode(sourceMeta ?? const <String, dynamic>{});
    await webView.runJavaScript(llamadaSegura(
        'aplicarFrameVivo',
        "'${jsonEncode(v)}',$timestamp,$calidad,"
            "'${_escapar(renderJson)}','${_escapar(metaJson)}'"));
  }

  // Los frames son puramente numericos (nunca llevan comillas ni barras),
  // asi que esto es mas una red de seguridad que algo que vaya a activarse
  // en la practica.
  String _escapar(String s) =>
      s.replaceAll('\\', '\\\\').replaceAll("'", "\\'");

  void dispose() {
    onTerminado = null;
    onPoseCapturada = null;
    onDiagnosticReport = null;
    onCalibrationChanged = null;
    onPerf = null;
    onMovimiento = null;
    onErrorVisor = null;
    _limite?.cancel();
    if (!_cerrado) {
      _cerrado = true;
      estado.dispose();
    }
  }
}
