import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
// Transitiva de speech_to_text; solo la usa esta prueba para simular la
// plataforma (no se toca el pubspec por esto).
// ignore: depend_on_referenced_packages
import 'package:speech_to_text_platform_interface/speech_to_text_platform_interface.dart'
    as stt;
import 'package:univoz/services/voz.dart';

class _MotorFalso implements MotorTts {
  VoidCallback? alTerminar;
  final List<String> dichos = [];
  int detenciones = 0;
  int preparaciones = 0;

  @override
  Future<void> preparar({required VoidCallback alTerminar}) async {
    preparaciones++;
    this.alTerminar = alTerminar;
  }

  @override
  Future<bool> hablar(String texto) async {
    dichos.add(texto);
    return true;
  }

  @override
  Future<void> detener() async => detenciones++;
}

/// Plataforma de speech_to_text falsa: la prueba dispara a mano los avisos
/// en el orden en que los manda Android.
class _PlataformaSttFalsa extends stt.SpeechToTextPlatform {
  @override
  Future<bool> initialize(
          {debugLogging = false,
          List<stt.SpeechConfigOption>? options}) async =>
      true;
  int escuchas = 0;

  @override
  Future<bool> listen(
      {String? localeId,
      partialResults = true,
      onDevice = false,
      int listenMode = 0,
      sampleRate = 0,
      stt.SpeechListenOptions? options}) async {
    escuchas++;
    return true;
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> cancel() async {}
  @override
  Future<List<dynamic>> locales() async => [];
}

void main() {
  group('LectorVozTts compartido', () {
    late _MotorFalso motor;

    setUp(() {
      motor = _MotorFalso();
      LectorVozTts.usarMotorParaPruebas(motor);
    });
    tearDown(() => LectorVozTts.usarMotorParaPruebas(null));

    test('el aviso de fin llega solo al lector que estaba hablando', () async {
      final a = LectorVozTts();
      final b = LectorVozTts();
      var terminoA = 0, terminoB = 0;

      await a.hablar('uno', alTerminar: () => terminoA++);
      await b.hablar('dos', alTerminar: () => terminoB++);
      // B le quitó la voz a A: A ya sabe que se cortó.
      expect(terminoA, 1);
      expect(terminoB, 0);
      expect(motor.preparaciones, 1);

      motor.alTerminar!();
      expect(terminoA, 1);
      expect(terminoB, 1);

      // Y A puede volver a leer y recibir su propio aviso.
      await a.hablar('tres', alTerminar: () => terminoA++);
      motor.alTerminar!();
      expect(terminoA, 2);
      expect(terminoB, 1);
    });

    test('detener() de un lector inactivo no calla al que habla', () async {
      final a = LectorVozTts();
      final b = LectorVozTts();
      await b.hablar('dos', alTerminar: () {});
      await a.detener();
      expect(motor.detenciones, 0);
      await b.detener();
      expect(motor.detenciones, 1);
    });
  });

  group('DictadoVozStt', () {
    // SpeechToText es un singleton que se engancha a la plataforma en su
    // primer initialize(): una sola falsa para todo el archivo.
    final plataforma = _PlataformaSttFalsa();
    late DictadoVozStt dictado;
    final fines = <bool>[];

    setUpAll(() => stt.SpeechToTextPlatform.instance = plataforma);

    setUp(() async {
      dictado = DictadoVozStt();
      fines.clear();
      expect(await dictado.preparar(), isTrue);
    });

    Future<void> empezar() => dictado.escuchar(
          alTexto: (_, __) {},
          alNivel: (_) {},
          alTerminar: fines.add,
        );

    const errorRed = '{"errorMsg":"error_network","permanent":true}';

    testWidgets('el error que llega DESPUÉS del estado se reporta',
        (tester) async {
      await empezar();
      plataforma.onStatus!('listening');
      plataforma.onStatus!('notListening');
      plataforma.onStatus!('doneNoResult');
      await tester.pump(const Duration(milliseconds: 100));
      expect(fines, isEmpty);
      plataforma.onError!(errorRed);
      await tester.pump();
      expect(fines, [true]);
      await dictado.detener();
      // Los temporizadores propios del plugin (listenFor, pauseFor).
      await tester.pump(const Duration(seconds: 40));
    });

    testWidgets('un error sin estado previo termina de inmediato',
        (tester) async {
      await empezar();
      plataforma.onStatus!('listening');
      plataforma.onError!(errorRed);
      await tester.pump();
      expect(fines, [true]);
      await dictado.detener();
      // Los temporizadores propios del plugin (listenFor, pauseFor).
      await tester.pump(const Duration(seconds: 40));
    });

    testWidgets('sin error, el estado termina tras la espera sin avisar',
        (tester) async {
      await empezar();
      plataforma.onStatus!('listening');
      plataforma.onStatus!('notListening');
      plataforma.onStatus!('done');
      await tester
          .pump(DictadoVozStt.kEsperaError + const Duration(milliseconds: 50));
      expect(fines, [false]);
      await dictado.detener();
      // Los temporizadores propios del plugin (listenFor, pauseFor).
      await tester.pump(const Duration(seconds: 40));
    });

    testWidgets('los avisos de fin de la sesión anterior se ignoran',
        (tester) async {
      await empezar();
      // Rezago de la sesión anterior, antes del "listening" de esta.
      plataforma.onStatus!('notListening');
      plataforma.onStatus!('done');
      await tester.pump(const Duration(seconds: 1));
      expect(fines, isEmpty);
      plataforma.onStatus!('listening');
      await tester.pump(const Duration(seconds: 1));
      expect(fines, isEmpty);
      await dictado.detener();
      expect(fines, [false]);
      await tester.pump(const Duration(seconds: 40));
    });

    testWidgets('detener() durante la resolución del idioma no abre el micro',
        (tester) async {
      final antes = plataforma.escuchas;
      final f = dictado.escuchar(
          alTexto: (_, __) {}, alNivel: (_) {}, alTerminar: (_) {});
      await dictado.detener();
      await f;
      expect(plataforma.escuchas, antes);
      await tester.pump(const Duration(seconds: 40));
    });
  });
}
