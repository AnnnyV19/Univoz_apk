/// Medicion de latencia del espejo del avatar y toggles de prueba, solo para
/// quien desarrolla (modo desarrollador). Todo vive en memoria: nada se
/// guarda, y con el modo apagado se comporta como siempre.
///
/// - Resumen de latencia a logcat una vez por segundo con la etiqueta
///   `UnivozLat` (Kotlin: Log.i; Dart: print, que si llega a logcat en
///   release; el visor manda su resumen `lat:` y Dart lo imprime). Tres
///   lineas por segundo: `nat`, `dart` y `js`.
///     adb logcat -s UnivozLat flutter
/// - Toggles de prueba: suavizado del avatar, delegado y modelo de MediaPipe,
///   FPS y tamano de la vista previa de la camara.
library diagnostico_latencia;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'modo_desarrollador.dart';

/// Etiqueta de las lineas de logcat (la misma en Kotlin y en Dart).
const String kEtiquetaLatencia = 'UnivozLat';

/// Suavizado del avatar (visor, window.configurarSuavizado).
enum SuavizadoAvatar {
  /// El unico suavizado en vivo: por hueso, a ritmo de render.
  normal('normal', 'Normal'),

  /// Sin suavizado de salida ni filtro de dedos: pose cruda del tracking.
  apagado('off', 'Apagado');

  const SuavizadoAvatar(this.wire, this.etiqueta);

  /// Valor que entiende window.configurarSuavizado.
  final String wire;
  final String etiqueta;
}

/// Delegado de inferencia de MediaPipe (LandmarkEngine.kt).
enum DelegadoMediaPipe {
  /// Lo de siempre: GPU y, si no carga, CPU.
  gpu('gpu', 'GPU'),

  /// Solo CPU. Aplica al abrir la camara de nuevo.
  cpu('cpu', 'CPU');

  const DelegadoMediaPipe(this.wire, this.etiqueta);

  /// Valor que entiende LandmarkPlugin.kt (argumento `delegado`).
  final String wire;
  final String etiqueta;
}

/// Modelo de captura (LandmarkEngine.kt).
enum ModeloMediaPipe {
  /// Producto: Holistic (cuerpo, manos y cara en una pasada).
  holistic('holistic', 'Holistic'),

  /// Pose lite + Hand por separado (el respaldo de siempre). No trae cara
  /// (ni manos en metros), asi que el avatar pierde la cara.
  separado('separado', 'Separado');

  const ModeloMediaPipe(this.wire, this.etiqueta);

  /// Valor que entiende LandmarkPlugin.kt (argumento `modelo`).
  final String wire;
  final String etiqueta;
}

/// Rango de FPS de la camara (AE). Aplica al abrir la camara de nuevo.
enum FpsCamara {
  /// Fijo y lo mas alto que soporte (hasta 60): menos exposicion y cola.
  maximo('max', 'Máx fijo'),

  /// Fijo en 30.
  fijo30('30', '30 fijo'),

  /// Lo que decida CameraX / el HAL (rango variable).
  auto('auto', 'Auto');

  const FpsCamara(this.wire, this.etiqueta);

  /// Valor que entiende LandmarkPlugin.kt (argumento `fps`).
  final String wire;
  final String etiqueta;
}

/// Tamano de la vista previa de la camara (el analisis no cambia).
enum VistaPreviaCamara {
  /// Tope 640x480.
  chica('chica', 'Chica 640×480'),

  /// Lo que elija CameraX (suele ser ~1080p).
  auto('auto', 'Auto');

  const VistaPreviaCamara(this.wire, this.etiqueta);

  /// Valor que entiende LandmarkPlugin.kt (argumento `preview`).
  final String wire;
  final String etiqueta;
}

class DiagnosticoLatencia {
  DiagnosticoLatencia._();

  /// Elegido en Ajustes (solo con el modo desarrollador). En memoria.
  static final ValueNotifier<SuavizadoAvatar> suavizado =
      ValueNotifier<SuavizadoAvatar>(SuavizadoAvatar.normal);
  static final ValueNotifier<DelegadoMediaPipe> delegado =
      ValueNotifier<DelegadoMediaPipe>(DelegadoMediaPipe.gpu);
  static final ValueNotifier<ModeloMediaPipe> modelo =
      ValueNotifier<ModeloMediaPipe>(ModeloMediaPipe.holistic);
  static final ValueNotifier<FpsCamara> fps =
      ValueNotifier<FpsCamara>(FpsCamara.maximo);
  static final ValueNotifier<VistaPreviaCamara> vistaPrevia =
      ValueNotifier<VistaPreviaCamara>(VistaPreviaCamara.chica);

  /// Solo para pruebas: ignora ModoDesarrollador.
  @visibleForTesting
  static bool? desarrolladorParaPruebas;

  static bool get _desarrollador =>
      desarrolladorParaPruebas ?? ModoDesarrollador.activo;

  /// Cambia con el modo desarrollador; para reaccionar al encenderlo.
  static final Listenable cambios = Listenable.merge(
      [ModoDesarrollador.notificador, suavizado, delegado, modelo, fps, vistaPrevia]);

  /// Medicion encendida: sigue al modo desarrollador.
  static bool get activo => _desarrollador;

  /// Lo que de verdad se aplica: fuera del modo desarrollador, siempre el
  /// comportamiento de siempre aunque haya quedado un valor elegido.
  static SuavizadoAvatar get suavizadoEfectivo =>
      _desarrollador ? suavizado.value : SuavizadoAvatar.normal;
  static DelegadoMediaPipe get delegadoEfectivo =>
      _desarrollador ? delegado.value : DelegadoMediaPipe.gpu;
  static ModeloMediaPipe get modeloEfectivo =>
      _desarrollador ? modelo.value : ModeloMediaPipe.holistic;
  // Fuera del modo desarrollador rigen los valores por defecto del producto.
  static FpsCamara get fpsEfectivo =>
      _desarrollador ? fps.value : FpsCamara.maximo;
  static VistaPreviaCamara get vistaPreviaEfectiva =>
      _desarrollador ? vistaPrevia.value : VistaPreviaCamara.chica;

  @visibleForTesting
  static void restablecerParaPruebas() {
    suavizado.value = SuavizadoAvatar.normal;
    delegado.value = DelegadoMediaPipe.gpu;
    modelo.value = ModeloMediaPipe.holistic;
    fps.value = FpsCamara.maximo;
    vistaPrevia.value = VistaPreviaCamara.chica;
    desarrolladorParaPruebas = null;
    salida = _imprimir;
    _capSendP50 = null;
  }

  // -- Salida a logcat ----------------------------------------------------

  static void _imprimir(String linea) {
    // ignore: avoid_print
    print(linea); // print si llega a logcat en release; debugPrint no.
  }

  /// Destino de las lineas (se cambia en pruebas).
  static void Function(String) salida = _imprimir;

  static void emitir(String fuente, String campos) =>
      salida('$kEtiquetaLatencia $fuente $campos');

  // -- Lado visor (mensaje `lat:<json>` del WebView) ----------------------

  static double? _capSendP50;

  /// Imprime el resumen del visor. [json] es lo que sigue a `lat:`. Un
  /// mensaje roto se ignora.
  static void alResumenVisor(String json) {
    final Object? valor;
    try {
      valor = jsonDecode(json);
    } catch (_) {
      return;
    }
    if (valor is! Map) return;
    emitir('js', formatearResumenVisor(valor, capSendP50: _capSendP50));
  }

  /// Campos de la linea `js`. Pura (probada).
  static String formatearResumenVisor(Map resumen, {double? capSendP50}) {
    final ventana = (resumen['window_ms'] as num?)?.toDouble() ?? 0;
    final entrada = (resumen['frames_in'] as num?)?.toDouble() ?? 0;
    final ticks = (resumen['ticks'] as num?)?.toDouble() ?? 0;
    String tasa(double n) =>
        ventana > 0 ? (n * 1000 / ventana).toStringAsFixed(1) : '-';
    String serie(Object? s) {
      if (s is! Map || s['p50'] == null) return '-';
      String f(Object? x) => (x as num).toStringAsFixed(1);
      return '${f(s['p50'])}/${f(s['p95'])}/${f(s['max'])}';
    }

    final shown = resumen['shown_ms'];
    final shownP50 = shown is Map ? (shown['p50'] as num?)?.toDouble() : null;
    // Suma de medianas de dos ventanas distintas: orientativo, no una medicion
    // por frame.
    final estimado = capSendP50 != null && shownP50 != null
        ? (capSendP50 + shownP50).toStringAsFixed(1)
        : '-';
    return 'win=${ventana.round()}ms in=${tasa(entrada)}/s '
        'render=${tasa(ticks)}/s '
        'superseded=${resumen['superseded'] ?? 0} '
        'smooth=${resumen['suavizado'] ?? '-'} '
        'apply=${serie(resumen['apply_ms'])} '
        'tick=${serie(resumen['tick_ms'])} '
        'shown=${serie(shown)} '
        'e2e_est_p50=$estimado';
  }

  /// Lo publica MedidorEnvio al cerrar cada ventana (cap_send p50), para el
  /// estimado de punta a punta de la linea `js`.
  static void registrarCapSend(double? p50) => _capSendP50 = p50;
}

/// Muestras de una ventana (anillo de doubles, sin crear listas por frame)
/// con resumen p50/p95/max.
class VentanaMs {
  VentanaMs([int capacidad = 256]) : _v = List<double>.filled(capacidad, 0);

  final List<double> _v;
  int _n = 0;
  int _sig = 0;

  int get n => _n;

  void agregar(double ms) {
    if (!ms.isFinite) return;
    _v[_sig] = ms;
    _sig = (_sig + 1) % _v.length;
    if (_n < _v.length) _n++;
  }

  void limpiar() {
    _n = 0;
    _sig = 0;
  }

  /// Percentil q (0..1) por rango superior; null sin muestras.
  double? percentil(double q) {
    if (_n == 0) return null;
    final orden = _v.sublist(0, _n)..sort();
    final i = (_n * q).ceil().clamp(1, _n) - 1;
    return orden[i];
  }

  double? get max => percentil(1);

  /// `p50/p95/max` con un decimal, o `-` sin muestras.
  String resumen() {
    final p50 = percentil(.5);
    if (p50 == null) return '-';
    return '${p50.toStringAsFixed(1)}/${percentil(.95)!.toStringAsFixed(1)}/'
        '${max!.toStringAsFixed(1)}';
  }
}

/// Contadores y ventanas del envio al WebView (AlimentadorAvatar). Un
/// resumen por segundo; quien llama pasa el reloj en microsegundos
/// (relojDiagnosticoUs de camera_bridge.dart), asi se prueba sin reloj real.
class MedidorEnvio {
  MedidorEnvio({this.ventanaUs = 1000000});

  final int ventanaUs;

  int _inicioUs = -1;
  int _llegados = 0;
  int _enviados = 0;
  int _reemplazados = 0;
  int _sinPose = 0;
  int _errores = 0;

  /// Llegada a Dart -> inicio del envio (espera por intervalo y por un envio
  /// anterior en vuelo, mas normalizar).
  final VentanaMs espera = VentanaMs();

  /// Duracion de mostrarFrame (jsonEncode + runJavaScript hasta que el
  /// WebView confirma).
  final VentanaMs viaje = VentanaMs();

  /// Edad de captura (Kotlin al emitir) + espera en Dart: captura -> se manda
  /// al WebView.
  final VentanaMs capEnvio = VentanaMs();

  /// Lo anterior + viaje: captura -> aplicarFrameVivo terminado en el visor
  /// (cota superior de cuando el visor ya tiene el frame).
  final VentanaMs capConfirmado = VentanaMs();

  void frameLlegado(int ahoraUs) {
    if (_inicioUs < 0) _inicioUs = ahoraUs;
    _llegados++;
  }

  void reemplazado() => _reemplazados++;
  void sinPose() => _sinPose++;
  void fallo() => _errores++;

  /// [esperaMs]: llegada -> inicio del envio. [viajeMs]: duracion del envio.
  /// [capAgeMs]: edad de captura al emitir en Kotlin (null si no vino).
  void enviado(
      {required double esperaMs,
      required double viajeMs,
      double? capAgeMs}) {
    _enviados++;
    espera.agregar(esperaMs);
    viaje.agregar(viajeMs);
    if (capAgeMs != null) {
      capEnvio.agregar(capAgeMs + esperaMs);
      capConfirmado.agregar(capAgeMs + esperaMs + viajeMs);
    }
  }

  /// Si ya paso la ventana, devuelve los campos de la linea `dart` y reinicia;
  /// si no, null. Barato: una resta por frame.
  String? cerrarSiToca(int ahoraUs) {
    if (_inicioUs < 0 || ahoraUs - _inicioUs < ventanaUs) return null;
    final seg = (ahoraUs - _inicioUs) / 1e6;
    String tasa(int n) => (n / seg).toStringAsFixed(1);
    final linea = 'win=${(seg * 1000).round()}ms in=${tasa(_llegados)}/s '
        'sent=${tasa(_enviados)}/s replaced=$_reemplazados '
        'nopose=$_sinPose err=$_errores '
        'wait=${espera.resumen()} rtt=${viaje.resumen()} '
        'cap_send=${capEnvio.resumen()} cap_ack=${capConfirmado.resumen()}';
    DiagnosticoLatencia.registrarCapSend(capEnvio.percentil(.5));
    _llegados = _enviados = _reemplazados = _sinPose = _errores = 0;
    espera.limpiar();
    viaje.limpiar();
    capEnvio.limpiar();
    capConfirmado.limpiar();
    _inicioUs = ahoraUs;
    return linea;
  }
}
