/// Un solo motor de texto a voz para todo el proceso (senas_core y univoz).
///
/// flutter_tts usa UN canal de plataforma: cada `FlutterTts()` nuevo le quita
/// los avisos (terminó, se cortó, falló) al anterior. Con varios motores, el
/// último en crearse recibía todos los avisos y el botón "Leer en voz alta"
/// se quedaba en "Detener". Aquí hay una sola instancia, con los avisos
/// puestos una vez, y una sola ranura de "quién está leyendo": el aviso de
/// fin le llega a quien de verdad estaba hablando.
library tts_compartido;

import 'package:flutter/foundation.dart' show VoidCallback, visibleForTesting;
import 'package:flutter_tts/flutter_tts.dart';

class TtsCompartido {
  static TtsCompartido instancia = TtsCompartido._();

  /// Solo para pruebas: reinicia el estado (el motor sigue siendo uno).
  @visibleForTesting
  static void reiniciarParaPruebas() {
    instancia._alTerminar = null;
    instancia._generacion = 0;
    instancia._inicioEsperado = 0;
  }

  TtsCompartido._() {
    tts.setStartHandler(_inicio);
    tts.setCompletionHandler(_terminoVoz);
    tts.setCancelHandler(_cancelado);
    tts.setErrorHandler((_) => _terminoVoz());
  }

  /// El único FlutterTts de la app.
  final FlutterTts tts = FlutterTts();

  VoidCallback? _alTerminar;
  Future<void>? _esperaFin;

  /// Número de la lectura que tiene la ranura. Cada [tomar] lo sube: un
  /// aviso tardío de la lectura anterior no puede cerrar la nueva.
  int _generacion = 0;

  /// Generación cuyo arranque se espera tras haber cortado a otra lectura
  /// (0 = ninguna). Mientras tanto, un "se cortó" que llegue es de la
  /// lectura anterior (el motor lo manda después del stop) y se ignora.
  int _inicioEsperado = 0;

  /// Quien va a hablar toma la ranura. Si otro estaba leyendo, su lectura
  /// se corta: se le avisa ya para que no siga mostrando "Detener".
  /// [alTerminar] se llama una vez, al terminar, cortarse o fallar.
  /// Devuelve la generación de esta lectura.
  int tomar(VoidCallback alTerminar) {
    final previo = _alTerminar;
    _alTerminar = alTerminar;
    final gen = ++_generacion;
    if (previo != null) {
      // Habia voz en curso: su "se cortó" llegará tarde, ya con esta
      // lectura dueña de la ranura.
      _inicioEsperado = gen;
      // El mismo lector retomando la ranura no se avisa a si mismo.
      if (previo != alTerminar) previo();
    }
    return gen;
  }

  /// Habla [texto] como dueño de la ranura. Si algo estaba hablando (el
  /// narrador, el reconocedor u otro botón de lectura) lo corta primero:
  /// con el fin de voz esperado, `speak()` devuelve 0 sin hablar mientras
  /// el motor está ocupado. Devuelve lo que `speak()` (1 = habló) o 0 si
  /// otra lectura tomó la ranura mientras tanto.
  Future<dynamic> hablar(String texto, VoidCallback alTerminar) async {
    final habiaVoz = _alTerminar != null;
    final gen = tomar(alTerminar);
    if (habiaVoz) {
      try {
        await tts.stop();
      } catch (_) {}
    }
    if (gen != _generacion) return 0;
    return tts.speak(texto);
  }

  /// Corta la voz a petición de quien la tiene: el "se cortó" que llegue
  /// cierra su lectura.
  Future<void> detener() async {
    _inicioEsperado = 0;
    await tts.stop();
  }

  void _inicio() {
    if (_inicioEsperado == _generacion) _inicioEsperado = 0;
  }

  void _cancelado() {
    if (_inicioEsperado != 0 && _inicioEsperado == _generacion) return;
    _fin();
  }

  void _terminoVoz() {
    _inicioEsperado = 0;
    _fin();
  }

  void _fin() {
    final cb = _alTerminar;
    _alTerminar = null;
    cb?.call();
  }

  /// Hace que `speak()` termine cuando acaba la voz. Es una bandera global
  /// del lado nativo: se pone una sola vez para todos los usuarios del motor.
  Future<void> esperarFinDeVoz() => _esperaFin ??= () async {
        try {
          await tts.awaitSpeakCompletion(true);
        } catch (_) {}
      }();
}
