import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Comandos de voz que reconocemos en el onboarding de accesibilidad.
enum VoiceCommand { start, yes, no, exit, unknown }

/// Asistente de voz para personas ciegas.
///
/// Si el celular tiene TalkBack (u otro lector de pantalla) activo,
/// asumimos que la persona es ciega y conducimos todo el onboarding con
/// preguntas habladas (texto a voz) y respuestas habladas (reconocimiento
/// de voz) — en vez de depender de que TalkBack lea la pantalla tal cual
/// está, decidimos nosotros qué se dice y qué se escucha.
///
/// Si TalkBack NO está activo, este asistente permanece en silencio (no
/// dice nada) hasta que alguien confirme manualmente el perfil "ciego" en
/// la cuadrícula táctil de selección de perfil; a partir de ahí solo
/// narra (sin pedir respuestas por voz), porque seguimos sin tener la
/// confirmación de que hay un lector de pantalla real operando el
/// teléfono.
class BlindNarrator {
  BlindNarrator._();

  static final FlutterTts _tts = FlutterTts();
  static final stt.SpeechToText _stt = stt.SpeechToText();
  static bool _ttsConfigured = false;
  static bool _sttAvailable = false;

  /// `false` en cuanto sabemos que no hay permiso de micrófono (lo
  /// negaron, o quedó en "no volver a preguntar"). Las pantallas lo usan
  /// para dejar de insistir con preguntas por voz que nunca van a poder
  /// escuchar nada, en vez de repetir "no entendí" sin parar (ver
  /// [ensureMicrophoneReady]).
  static bool _microphonePermanentlyDenied = false;

  /// `true` si ya se hizo la calibración de voz de inicio de sesión (ver
  /// [calibrateIfNeeded]): evita repetirla cada vez que arranca una
  /// pantalla nueva de preguntas por voz.
  static bool _calibrated = false;

  /// LocaleId que en verdad soporta este dispositivo para reconocimiento
  /// de voz, resuelto una sola vez (ver [_resolveLocaleId]). Muchos
  /// equipos Android no traen instalado el paquete de idioma "es_MX"
  /// aunque el sistema esté en español de México, y pedirle a
  /// `speech_to_text` un localeId que no existe puede hacer que el
  /// reconocimiento falle en silencio (nunca llama a onResult) en vez de
  /// avisar con un error claro.
  static String? _resolvedLocaleId;
  static bool _localeResolved = false;

  /// `true` si la app puede hablar (narración pasiva o preguntas por voz).
  /// Empieza en `false`: no decimos nada hasta detectar TalkBack o hasta
  /// que se confirme manualmente el perfil "ciego".
  static bool enabled = false;

  /// Confianza mínima (0.0 a 1.0) para aceptar un mensaje largo como bien
  /// reconocido en vez de pedir que se repita (ver [askMessage]). El
  /// paquete de reconocimiento no filtra el ruido de fondo por sí solo;
  /// algunos dispositivos no reportan confianza real y devuelven -1.0
  /// ("no disponible"), así que solo rechazamos cuando el valor es
  /// válido (>= 0) y bajo, nunca cuando no viene el dato.
  static const double _minConfidence = 0.35;

  /// `true` si se detectó TalkBack al abrir la app. Mientras sea `true`,
  /// las pantallas de onboarding usan preguntas y respuestas por voz en
  /// vez de narración pasiva + toque.
  static bool talkBackFlow = false;

  /// TalkBack / lector de pantalla activo. No depende de BuildContext, así
  /// que es seguro llamarlo desde initState.
  static bool get isTalkBackOn => WidgetsBinding
      .instance.platformDispatcher.accessibilityFeatures.accessibleNavigation;

  /// Identifica la corrida de preguntas-por-voz "activa" en este momento.
  /// Cada pantalla pide un token nuevo con [beginFlow] al arrancar su
  /// propio ciclo de preguntas; si el usuario avanza tocando la pantalla
  /// en vez de contestar por voz (por ejemplo, elige un perfil a mano
  /// mientras la pregunta por voz seguía esperando respuesta), se llama
  /// [interruptFlow] y cualquier `ask`/`askUntil` de la corrida vieja que
  /// siga esperando se entera —al comparar su token contra
  /// [isCurrentFlow]— de que ya no debe seguir hablando ni navegar a
  /// ningún lado con lo que llegue a reconocer tarde.
  static int _flowToken = 0;

  /// Pide un token nuevo para una corrida de preguntas por voz que
  /// empieza ahora (ver [_flowToken]).
  static int beginFlow() => ++_flowToken;

  /// `true` si [token] sigue siendo la corrida activa (ver [beginFlow]).
  static bool isCurrentFlow(int token) => token == _flowToken;

  /// Corta en seco cualquier narración o escucha en curso e invalida la
  /// corrida de voz activa (ver [beginFlow]/[isCurrentFlow]), sin apagar
  /// el modo por voz en sí (a diferencia de [disable]). Las pantallas lo
  /// llaman apenas el usuario avanza tocando la pantalla, para que una
  /// pregunta por voz vieja no se siga escuchando ni hablando encima de
  /// la pantalla nueva (por ejemplo, seguir preguntando "¿con quién te
  /// vas a comunicar?" en voz alta cuando ya se eligió a mano y se pasó
  /// a la siguiente pantalla).
  static Future<void> interruptFlow() async {
    beginFlow();
    await stop();
    await cancelListening();
  }

  static Future<void> _ensureTts() async {
    if (_ttsConfigured) return;
    _ttsConfigured = true;
    await _tts.setLanguage('es-MX');
    await _tts.setSpeechRate(0.45);
    await _tts.setPitch(1.0);
    await _tts.awaitSpeakCompletion(true);
  }

  /// Pide (si hace falta) el permiso de micrófono y prepara el
  /// reconocimiento de voz. A diferencia de dejar que
  /// `speech_to_text` maneje el permiso por su cuenta, lo pedimos
  /// explícitamente con `permission_handler` (el mismo paquete que ya
  /// usa la app para la cámara) para poder distinguir "todavía no se
  /// preguntó" de "lo negaron" y avisar con voz en vez de quedarnos
  /// preguntando algo que nunca vamos a poder escuchar.
  ///
  /// Si ya falló antes (por ejemplo, porque el permiso aún no se había
  /// concedido cuando se pidió), lo reintenta en cada llamada en vez de
  /// darlo por perdido para el resto de la sesión — salvo que el
  /// permiso haya quedado denegado permanentemente, en cuyo caso ya no
  /// tiene caso seguir preguntando al sistema operativo.
  static Future<bool> ensureMicrophoneReady() async {
    if (_sttAvailable) return true;
    if (_microphonePermanentlyDenied) return false;
    try {
      var status = await Permission.microphone.status;
      if (!status.isGranted) {
        status = await Permission.microphone.request();
      }
      if (status.isPermanentlyDenied) {
        _microphonePermanentlyDenied = true;
        return false;
      }
      if (!status.isGranted) {
        // Denegado por ahora (no "para siempre"): puede que la próxima
        // pregunta sí lo consiga, así que no lo marcamos como
        // permanente.
        return false;
      }
      _sttAvailable = await _stt.initialize(
        // Sin estos dos callbacks, cuando el reconocedor de voz falla
        // internamente (motor ocupado, sin conexión si el equipo usa
        // reconocimiento en la nube, idioma no soportado, etc.) no nos
        // enteramos: `listen` no lanza excepción y `onResult` nunca se
        // llama, así que la pregunta simplemente se queda "sin
        // escuchar" hasta el timeout sin ninguna pista de por qué.
        // Estos logs aparecen en la consola de `flutter run`.
        onError: (error) => debugPrint(
          '[BlindNarrator] error de reconocimiento de voz: '
          '${error.errorMsg} (permanente: ${error.permanent})',
        ),
        onStatus: (status) =>
            debugPrint('[BlindNarrator] estado del reconocedor: $status'),
      );
    } catch (_) {
      _sttAvailable = false;
    }
    return _sttAvailable;
  }

  /// Averigua qué localeId de español soporta de verdad este equipo para
  /// reconocimiento de voz (ver [_resolvedLocaleId]) y lo recuerda para
  /// el resto de la sesión. Si no encuentra ninguno, devuelve `null`
  /// para que `speech_to_text` use el idioma que tenga configurado el
  /// sistema en vez de forzar uno que tal vez no esté instalado.
  static Future<String?> _resolveLocaleId() async {
    if (_localeResolved) return _resolvedLocaleId;
    _localeResolved = true;
    try {
      final locales = await _stt.locales();
      String? buscar(bool Function(String idMinuscula) test) {
        for (final locale in locales) {
          if (test(locale.localeId.toLowerCase())) return locale.localeId;
        }
        return null;
      }

      _resolvedLocaleId = buscar((id) => id == 'es_mx') ??
          buscar((id) => id.startsWith('es_')) ??
          buscar((id) => id.startsWith('es'));
      final elegido = _resolvedLocaleId ??
          '(idioma del sistema; no se encontró ningún español instalado)';
      debugPrint('[BlindNarrator] localeId de voz elegido: $elegido');
    } catch (e) {
      debugPrint('[BlindNarrator] no se pudo consultar locales: $e');
      _resolvedLocaleId = null;
    }
    return _resolvedLocaleId;
  }

  /// `true` en cuanto sabemos que el micrófono no está disponible (el
  /// permiso quedó denegado permanentemente). Las pantallas lo usan para
  /// avisar una sola vez y dejar de insistir con preguntas por voz.
  static bool get microphonePermanentlyDenied => _microphonePermanentlyDenied;

  /// Marca que se detectó TalkBack (o que se confirmó manualmente el
  /// perfil "ciego"): activa el modo de preguntas y respuestas por voz
  /// para el resto de la sesión.
  static void activateTalkBackFlow() {
    talkBackFlow = true;
    enabled = true;
  }

  /// Marca que se confirmó manualmente el perfil "ciego" (sin TalkBack).
  /// Usa exactamente el mismo modo de preguntas y respuestas por voz que
  /// TalkBack: si alguien elige "soy ciego/a" por tacto (por ejemplo,
  /// alguien más le configura el teléfono), a partir de la siguiente
  /// pantalla la app también le habla y escucha su voz, no solo narra.
  static void activateManualBlindMode() => activateTalkBackFlow();

  /// Lee [text] en voz alta si [enabled]. No espera respuesta.
  static Future<void> speak(String text) async {
    if (!enabled) return;
    await _ensureTts();
    await _tts.stop();
    await _tts.speak(text);
  }

  /// Detiene la narración en curso (sin deshabilitarla).
  static Future<void> stop() => _tts.stop();

  /// Interrumpe de inmediato una escucha en curso (por ejemplo, si la
  /// persona cambia de pestaña a mitad de una pregunta) sin procesar lo
  /// que se llevaba reconocido, a diferencia de detener normalmente al
  /// terminar de escuchar. Es "mejor esfuerzo": no falla si no había
  /// nada escuchando.
  static Future<void> cancelListening() async {
    try {
      await _stt.cancel();
    } catch (_) {
      // No había una sesión de escucha activa, o el paquete no pudo
      // cancelarla; no es un error que debamos propagar.
    }
  }

  /// Apaga la narración/preguntas por voz. A diferencia de solo poner
  /// [enabled] en `false`, también apaga [talkBackFlow]: se usa cuando
  /// alguien activó el modo ciego a mano (por ejemplo, en
  /// ProfileSelectionScreen) y luego, regresando con el botón "atrás",
  /// elige un perfil distinto de "ciego" — sin este reinicio, el modo
  /// por voz se quedaría encendido para el resto de la sesión aunque ya
  /// no aplique.
  static Future<void> disable() async {
    enabled = false;
    talkBackFlow = false;
    await _tts.stop();
    await _stt.stop();
  }

  /// Habla [prompt] y luego escucha una respuesta por voz. Devuelve el
  /// texto reconocido en minúsculas, o cadena vacía si no se reconoció
  /// nada, el micrófono no está disponible, o [isCancelled] se vuelve
  /// verdadero mientras tanto (ver el parámetro).
  ///
  /// [isCancelled], si se da, se revisa antes de hablar y antes de
  /// escuchar: la pantalla que llama lo usa para decir "ya no estoy en
  /// pantalla" (por ejemplo, comparando contra su propio token de
  /// corrida) y así esta función deja de hablar o escuchar de inmediato
  /// en vez de completar el ciclo entero primero. Sin esto, salir de la
  /// pantalla a mitad de un `ask` no lo interrumpe: sigue hablando y
  /// escuchando de fondo hasta que termina por su cuenta.
  ///
  /// [onPartialResult], si se da, se llama con cada resultado parcial
  /// que reconoce el motor de voz MIENTRAS escucha (no solo el final),
  /// para que la pantalla pueda mostrar en vivo lo que va entendiendo
  /// (por ejemplo, "Escuchando: hola" mientras la persona sigue
  /// hablando), en vez de que el texto solo aparezca hasta que termina.
  static Future<String> ask(
    String prompt, {
    bool Function()? isCancelled,
    void Function(String partial)? onPartialResult,
  }) async {
    if (isCancelled != null && isCancelled()) return '';
    await _ensureTts();
    await _tts.stop();
    await _tts.speak(prompt);
    if (isCancelled != null && isCancelled()) return '';
    final bool micReady = await ensureMicrophoneReady();
    if (!micReady) return '';
    if (isCancelled != null && isCancelled()) return '';

    final completer = Completer<String>();
    var heard = '';
    try {
      await _stt.listen(
        onResult: (result) {
          heard = result.recognizedWords;
          onPartialResult?.call(heard);
          if (result.finalResult && !completer.isCompleted) {
            completer.complete(heard);
          }
        },
        localeId: await _resolveLocaleId(),
        listenFor: const Duration(seconds: 6),
        pauseFor: const Duration(seconds: 2),
      );
    } catch (e) {
      debugPrint('[BlindNarrator] listen() falló en ask(): $e');
      return '';
    }
    final result = await completer.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () => heard,
    );
    await _stt.stop();
    if (isCancelled != null && isCancelled()) return '';
    return result.trim().toLowerCase();
  }

  /// Habla [prompt] y luego escucha un mensaje largo (a diferencia de
  /// [ask], pensado para una sola palabra como "sí" o "comenzar"). Da más
  /// tiempo para hablar y para pausas breves entre frases, y usa un
  /// umbral de confianza para reintentarlo cuando el reconocimiento no
  /// fue confiable — por ejemplo, por ruido de fondo o una voz muy
  /// baja — en vez de aceptar cualquier cosa y mandar un mensaje
  /// probablemente equivocado. Devuelve el texto reconocido (respetando
  /// mayúsculas/minúsculas tal como se dictó), o cadena vacía si tras
  /// [maxAttempts] intentos no se reconoció nada confiable, o si
  /// [isCancelled] se vuelve verdadero mientras tanto.
  ///
  /// [isCancelled] se revisa entre cada paso (antes de hablar, antes de
  /// escuchar, y después de escuchar) para cortar el ciclo en seco
  /// apenas la pantalla que llama deja de estar activa, en vez de que
  /// este método siga solo con su propio ciclo de reintentos (hasta
  /// [maxAttempts] veces) sin enterarse de nada — que es justo lo que
  /// hacía que la app siguiera diciendo "No escuché nada, dime el
  /// mensaje..." después de haber salido de la pantalla de Comunicarse.
  ///
  /// [onPartialResult], si se da, se llama con cada resultado parcial
  /// mientras se escucha (ver el mismo parámetro en [ask]) para que la
  /// pantalla pueda mostrar en vivo lo que se va reconociendo.
  static Future<String> askMessage(
    String prompt, {
    int maxAttempts = 3,
    String lowConfidenceRetryPrompt =
        'No te escuché bien. Habla un poco más fuerte y despacio, cerca '
        'del micrófono, y dime tu mensaje otra vez.',
    String silenceRetryPrompt =
        'No escuché nada. Dime el mensaje que quieres comunicar.',
    bool Function()? isCancelled,
    void Function(String partial)? onPartialResult,
  }) async {
    var currentPrompt = prompt;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (isCancelled != null && isCancelled()) return '';
      await _ensureTts();
      await _tts.stop();
      await _tts.speak(currentPrompt);
      if (isCancelled != null && isCancelled()) return '';
      final bool micReady = await ensureMicrophoneReady();
      if (!micReady) return '';
      if (isCancelled != null && isCancelled()) return '';

      final completer = Completer<String>();
      var heard = '';
      var confidence = 1.0;
      try {
        await _stt.listen(
          onResult: (result) {
            heard = result.recognizedWords;
            confidence = result.confidence;
            onPartialResult?.call(heard);
            if (result.finalResult && !completer.isCompleted) {
              completer.complete(heard);
            }
          },
          localeId: await _resolveLocaleId(),
          // Componer un mensaje toma más tiempo que decir "sí" o
          // "comenzar", así que le damos más margen para hablar y para
          // pausas breves (por ejemplo, para pensar a mitad de frase)
          // sin que el reconocimiento se corte solo.
          listenFor: const Duration(seconds: 20),
          pauseFor: const Duration(seconds: 3),
        );
      } catch (e) {
        debugPrint('[BlindNarrator] listen() falló en askMessage(): $e');
        return '';
      }
      final result = await completer.future.timeout(
        const Duration(seconds: 22),
        onTimeout: () => heard,
      );
      await _stt.stop();
      if (isCancelled != null && isCancelled()) return '';
      final text = result.trim();
      final bool lowConfidence =
          confidence >= 0 && confidence < _minConfidence;
      if (text.isNotEmpty && !lowConfidence) {
        return text;
      }
      currentPrompt =
          text.isEmpty ? silenceRetryPrompt : lowConfidenceRetryPrompt;
    }
    return '';
  }

  /// Pregunta [prompt] por voz hasta obtener un comando de la lista
  /// [accepted] (o "salir", que siempre se acepta), reintentando hasta
  /// [maxAttempts] veces con [retryPrompt]. Si el micrófono no está
  /// disponible (permiso denegado), no insiste con reintentos que nunca
  /// van a poder escuchar nada: avisa una vez y devuelve
  /// [VoiceCommand.unknown] de inmediato para que la pantalla siga con
  /// el camino táctil.
  ///
  /// [isCancelled], si se da, se pasa a cada [ask] interno (ver ese
  /// parámetro) para que dejar de estar en pantalla corte de inmediato
  /// cualquier pregunta o reintento en curso, en vez de esperar a que
  /// termine por su cuenta.
  static Future<VoiceCommand> askUntil(
    String prompt, {
    required List<VoiceCommand> accepted,
    String retryPrompt =
        'No entendí. ¿Puedes repetirlo? Di sal para cerrar la app.',
    int maxAttempts = 4,
    bool Function()? isCancelled,
  }) async {
    if (isCancelled != null && isCancelled()) return VoiceCommand.unknown;
    var command =
        parseCommand(await ask(prompt, isCancelled: isCancelled));
    if (isCancelled != null && isCancelled()) return command;
    if (_microphonePermanentlyDenied) {
      await speak('No tengo permiso para usar el micrófono. Usa los '
          'botones en pantalla para continuar.');
      return command;
    }
    var attempts = 1;
    while (command != VoiceCommand.exit &&
        !accepted.contains(command) &&
        attempts < maxAttempts) {
      if (isCancelled != null && isCancelled()) return command;
      command = parseCommand(await ask(retryPrompt, isCancelled: isCancelled));
      if (isCancelled != null && isCancelled()) return command;
      if (_microphonePermanentlyDenied) {
        await speak('No tengo permiso para usar el micrófono. Usa los '
            'botones en pantalla para continuar.');
        return command;
      }
      attempts++;
    }
    return command;
  }

  /// Antes de la primera pregunta real por voz de toda la sesión, le
  /// pedimos a la persona que diga una frase fija para "calentar" el
  /// reconocedor con su voz y con el ruido de fondo del lugar donde
  /// está, en vez de que la primera vez que el micrófono escuche algo
  /// sea ya una pregunta real (por ejemplo "¿con quién te vas a
  /// comunicar?"). No importa si lo que reconoce coincide con la frase
  /// exacta: solo sirve para confirmar, con una respuesta hablada, si el
  /// micrófono en verdad está captando la voz de la persona. Se hace
  /// como máximo una vez por sesión (ver [_calibrated]) y nunca bloquea
  /// el resto del flujo: si no se escucha nada, solo avisa y sigue.
  static Future<void> calibrateIfNeeded() async {
    if (_calibrated) return;
    _calibrated = true;

    final bool micReady = await ensureMicrophoneReady();
    if (!micReady) return;

    await _ensureTts();
    await _tts.stop();
    await _tts.speak(
      'Antes de empezar, vamos a ajustar el micrófono a tu voz y al '
      'ruido de este lugar. Cuando te lo pida, di claro y sin prisa: '
      'Univoz, actívate.',
    );
    await _tts.speak('Di: Univoz, actívate.');

    final completer = Completer<String>();
    var heard = '';
    try {
      await _stt.listen(
        onResult: (result) {
          heard = result.recognizedWords;
          if (result.finalResult && !completer.isCompleted) {
            completer.complete(heard);
          }
        },
        localeId: await _resolveLocaleId(),
        listenFor: const Duration(seconds: 6),
        pauseFor: const Duration(seconds: 2),
      );
    } catch (e) {
      debugPrint('[BlindNarrator] listen() falló en calibrateIfNeeded(): $e');
      return;
    }
    final result = await completer.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () => heard,
    );
    await _stt.stop();
    debugPrint('[BlindNarrator] calibración escuchó: "$result"');

    if (result.trim().isNotEmpty) {
      await speak('Perfecto, ya te escucho.');
    } else {
      // No escuchó nada: probablemente el problema es de volumen o de
      // ruido, no del código. Avisamos y seguimos de todas formas (las
      // preguntas reales insisten varias veces por su cuenta, ver
      // askUntil), en vez de bloquear el flujo esperando algo que quizás
      // nunca llegue.
      await speak(
        'No escuché nada. Acércate más al micrófono, habla fuerte y '
        'despacio, y si puedes reduce el ruido de alrededor. Vamos a '
        'seguir de todas formas.',
      );
    }
  }

  /// Interpreta un texto reconocido como uno de los comandos de voz que
  /// usamos en el onboarding.
  static VoiceCommand parseCommand(String text) {
    if (text.isEmpty) return VoiceCommand.unknown;
    if (text.contains('sal')) return VoiceCommand.exit; // "salir"
    if (text.contains('comenz') ||
        text.contains('empez') ||
        text.contains('inicia')) {
      return VoiceCommand.start;
    }
    if (text.contains('sí') || text.contains('si') || text.contains('claro')) {
      return VoiceCommand.yes;
    }
    if (text.contains('no')) return VoiceCommand.no;
    return VoiceCommand.unknown;
  }

  /// Cierra la app (se usa cuando el usuario dice "salir").
  static Future<void> exitApp() => SystemNavigator.pop();
}
