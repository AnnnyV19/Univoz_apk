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
  static void reiniciarParaPruebas() => instancia._alTerminar = null;

  TtsCompartido._() {
    tts.setCompletionHandler(_fin);
    tts.setCancelHandler(_fin);
    tts.setErrorHandler((_) => _fin());
  }

  /// El único FlutterTts de la app.
  final FlutterTts tts = FlutterTts();

  VoidCallback? _alTerminar;
  Future<void>? _esperaFin;

  /// Quien va a hablar toma la ranura. Si otro estaba leyendo, su lectura
  /// se corta: se le avisa ya para que no siga mostrando "Detener".
  /// [alTerminar] se llama una vez, al terminar, cortarse o fallar.
  void tomar(VoidCallback alTerminar) {
    final previo = _alTerminar;
    _alTerminar = alTerminar;
    // El mismo lector retomando la ranura no se avisa a si mismo.
    if (previo != null && previo != alTerminar) previo();
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
