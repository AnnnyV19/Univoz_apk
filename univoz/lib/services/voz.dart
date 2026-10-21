import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:senas_core/tts_compartido.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:url_launcher/url_launcher.dart';

/// Costuras pequeñas sobre los plugins de voz y de llamadas: las pantallas
/// hablan con estas interfaces y las pruebas ponen falsos, así nada toca
/// canales de plataforma.

/// Lee un texto en voz alta (texto a voz).
abstract class LectorVoz {
  /// Empieza a leer [texto]. [alTerminar] se llama cuando acaba, se
  /// detiene o falla; nunca antes de que haya empezado a hablar.
  Future<void> hablar(String texto, {required VoidCallback alTerminar});

  Future<void> detener();
}

/// El motor de texto a voz detrás de [LectorVozTts]. Existe para poder
/// probar la lógica de turnos sin el canal de plataforma.
abstract class MotorTts {
  /// Configura el idioma y avisa por [alTerminar] cuando la lectura
  /// termina, se corta o falla.
  Future<void> preparar({required VoidCallback alTerminar});

  /// true si el motor empezó a hablar.
  Future<bool> hablar(String texto);

  Future<void> detener();
}

class _MotorFlutterTts implements MotorTts {
  // El motor es uno para toda la app: el de senas_core y BlindNarrator
  // usan el mismo, así los avisos de fin no se pierden.
  final _compartido = TtsCompartido.instancia;

  @override
  Future<void> preparar({required VoidCallback alTerminar}) async {
    final tts = _compartido.tts;
    _alTerminar = alTerminar;
    try {
      final hayMx = await tts.isLanguageAvailable('es-MX');
      await tts.setLanguage(hayMx == true ? 'es-MX' : 'es-ES');
      await tts.setSpeechRate(0.45);
      await tts.setPitch(1.0);
    } catch (e) {
      // Sin idioma explícito el equipo usa el suyo, que es mejor que nada.
      debugPrint('[LectorVoz] no se pudo configurar el idioma: $e');
    }
    await _compartido.esperarFinDeVoz();
  }

  VoidCallback? _alTerminar;

  @override
  Future<bool> hablar(String texto) async {
    // Con el fin de voz esperado, speak() vuelve cuando acaba: 1 = habló,
    // 0 = ocupado o cortado. LectorVozTts cierra la lectura en ambos casos.
    _compartido.tomar(_alTerminar ?? () {});
    return await _compartido.tts.speak(texto) == 1;
  }

  @override
  Future<void> detener() async => _compartido.tts.stop();
}

/// [LectorVoz] real, con flutter_tts. La configuración es la misma que usa
/// BlindNarrator: es-MX y, si el equipo no lo trae, es-ES.
///
/// flutter_tts usa un solo canal de plataforma: cada `FlutterTts()` nuevo
/// le quita los avisos al anterior. Por eso todos los [LectorVozTts]
/// comparten un único motor y un único "quién está hablando": el aviso de
/// que terminó le llega solo a quien de verdad estaba leyendo.
class LectorVozTts implements LectorVoz {
  static MotorTts _motor = _MotorFlutterTts();
  static Future<void>? _preparado;
  static LectorVozTts? _activo;

  VoidCallback? _alTerminar;

  /// Solo para pruebas: cambia el motor compartido y reinicia el estado.
  @visibleForTesting
  static void usarMotorParaPruebas(MotorTts? motor) {
    _motor = motor ?? _MotorFlutterTts();
    _preparado = null;
    _activo = null;
  }

  static void _terminar() {
    final quien = _activo;
    _activo = null;
    final cb = quien?._alTerminar;
    quien?._alTerminar = null;
    cb?.call();
  }

  @override
  Future<void> hablar(String texto, {required VoidCallback alTerminar}) async {
    await (_preparado ??= _motor.preparar(alTerminar: _terminar));
    // Si otro lector estaba hablando, su lectura se corta: se le avisa
    // ahora para que no se quede mostrando "Detener".
    if (_activo != null) {
      _terminar();
      await _motor.detener();
    }
    _activo = this;
    _alTerminar = alTerminar;
    final empezo = await _motor.hablar(texto);
    // Si no empezó, nunca llegará el aviso de que terminó.
    if (!empezo && _activo == this) _terminar();
  }

  @override
  Future<void> detener() async {
    // Solo corta lo propio: cerrar una pantalla no debe callar a otra.
    if (_activo == this) await _motor.detener();
  }
}

/// Convierte lo que la persona dice en texto (dictado).
abstract class DictadoVoz {
  /// Prepara el reconocedor. false si este teléfono no puede dictar.
  /// Hay que tener el permiso del micrófono antes de llamarlo.
  Future<bool> preparar();

  /// Empieza a escuchar. [alTexto] recibe el texto reconocido hasta ahora
  /// (parcial o final), [alNivel] el volumen de la voz de 0 a 1 y
  /// [alTerminar] se llama una sola vez al acabar la sesión, con
  /// [huboError] si no se pudo entender nada.
  Future<void> escuchar({
    required void Function(String texto, bool esFinal) alTexto,
    required void Function(double nivel) alNivel,
    required void Function(bool huboError) alTerminar,
  });

  Future<void> detener();
}

/// [DictadoVoz] real, con speech_to_text. Busca español de México y, si no
/// está instalado, cualquier otro español.
class DictadoVozStt implements DictadoVoz {
  // SpeechToText es un singleton: BlindNarrator usa la misma instancia.
  final stt.SpeechToText _stt = stt.SpeechToText();
  String? _localeId;
  bool _localeResuelto = false;

  /// Cuánto se espera, tras el aviso de "dejó de escuchar", a que llegue
  /// un error. En Android el plugin manda primero el estado y después el
  /// error; si se terminara al instante, el error ya no tendría a quién
  /// avisarle y la persona se quedaría sin saber por qué no funcionó.
  static const Duration kEsperaError = Duration(milliseconds: 300);

  void Function(bool huboError)? _alTerminar;
  bool _huboError = false;
  bool _huboTexto = false;
  // Los avisos de fin solo valen después de "listening" de ESTA sesión:
  // uno que llegue antes es el rezago de la sesión anterior.
  bool _vistoListening = false;
  int _sesion = 0;
  Timer? _seguro;
  Timer? _finPendiente;

  @override
  Future<bool> preparar() async {
    try {
      final ok = await _stt.initialize();
      if (!ok) return false;
      // initialize() solo guarda los avisos la primera vez (puede haber
      // inicializado antes BlindNarrator), así que se reponen aquí.
      _stt.errorListener = (e) {
        debugPrint('[DictadoVoz] error: ${e.errorMsg} (${e.permanent})');
        _huboError = true;
        // Sin nada oído no hay más que esperar: se avisa ya.
        if (!_huboTexto) _terminar();
      };
      _stt.statusListener = (estado) {
        if (estado == 'listening') {
          _vistoListening = true;
          _finPendiente?.cancel();
          _finPendiente = null;
        } else if ((estado == 'done' || estado == 'notListening') &&
            _vistoListening &&
            _alTerminar != null) {
          _finPendiente ??= Timer(kEsperaError, _terminar);
        }
      };
      return true;
    } catch (e) {
      debugPrint('[DictadoVoz] no se pudo iniciar: $e');
      return false;
    }
  }

  Future<String?> _resolverLocale() async {
    if (_localeResuelto) return _localeId;
    _localeResuelto = true;
    try {
      final locales = await _stt.locales();
      String? buscar(bool Function(String id) test) {
        for (final l in locales) {
          if (test(l.localeId.toLowerCase().replaceAll('-', '_'))) {
            return l.localeId;
          }
        }
        return null;
      }

      _localeId = buscar((id) => id == 'es_mx') ??
          buscar((id) => id == 'es_es') ??
          buscar((id) => id.startsWith('es'));
    } catch (_) {
      _localeId = null;
    }
    return _localeId;
  }

  void _terminar() {
    _seguro?.cancel();
    _seguro = null;
    _finPendiente?.cancel();
    _finPendiente = null;
    final cb = _alTerminar;
    _alTerminar = null;
    // Sin texto y con error (nada que entender, sin red, motor ocupado...)
    // la persona tiene que enterarse; si ya se alcanzó a oír algo, no.
    cb?.call(_huboError && !_huboTexto);
  }

  @override
  Future<void> escuchar({
    required void Function(String texto, bool esFinal) alTexto,
    required void Function(double nivel) alNivel,
    required void Function(bool huboError) alTerminar,
  }) async {
    final sesion = ++_sesion;
    _alTerminar = alTerminar;
    _huboError = false;
    _huboTexto = false;
    _vistoListening = false;
    _finPendiente?.cancel();
    _finPendiente = null;
    const maximo = Duration(seconds: 30);
    // Red de seguridad: si por lo que sea nunca llega el aviso de que el
    // reconocedor paró, el botón no se queda "escuchando" para siempre.
    _seguro?.cancel();
    _seguro = Timer(maximo + const Duration(seconds: 3), _terminar);
    final locale = await _resolverLocale();
    // Si mientras tanto se pidió parar (o se cerró la pantalla), no se
    // abre el micrófono: nadie lo vería encendido.
    if (sesion != _sesion) return;
    try {
      await _stt.listen(
        onResult: (r) {
          if (sesion != _sesion) return;
          if (r.recognizedWords.isNotEmpty) _huboTexto = true;
          alTexto(r.recognizedWords, r.finalResult);
          if (r.finalResult) {
            unawaited(_stt.stop());
            _terminar();
          }
        },
        onSoundLevelChange: (db) {
          // En Android llega más o menos de -2 a 10.
          alNivel(((db + 2) / 12).clamp(0.0, 1.0).toDouble());
        },
        listenOptions: stt.SpeechListenOptions(
          partialResults: true,
          listenMode: stt.ListenMode.dictation,
          localeId: locale,
          listenFor: maximo,
          pauseFor: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      debugPrint('[DictadoVoz] listen() falló: $e');
      _huboError = true;
      _terminar();
    }
  }

  @override
  Future<void> detener() async {
    _sesion++;
    try {
      await _stt.stop();
    } catch (_) {}
    _terminar();
  }
}

/// Abre una dirección del teléfono (llamada, SMS) en la app que
/// corresponda.
abstract class LanzadorUrl {
  /// true si se pudo abrir.
  Future<bool> abrir(Uri uri);
}

class LanzadorUrlReal implements LanzadorUrl {
  const LanzadorUrlReal();

  @override
  Future<bool> abrir(Uri uri) async {
    try {
      return await launchUrl(uri);
    } catch (_) {
      return false;
    }
  }
}
