import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:senas_core/voz.dart' as senas;
import 'package:senas_core/tts_compartido.dart';
import 'package:univoz/services/voz.dart';

/// Un solo motor de voz: abrir el reconocedor (senas_core) antes del SOS ya
/// no le quita al botón "Leer en voz alta" el aviso de que terminó.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const canal = MethodChannel('flutter_tts');
  final llamadas = <String>[];

  Future<void> nativo(String evento) => messenger.handlePlatformMessage(
        'flutter_tts',
        const StandardMethodCodec().encodeMethodCall(MethodCall(evento, true)),
        (_) {},
      );

  setUp(() {
    llamadas.clear();
    LectorVozTts.usarMotorParaPruebas(null);
    TtsCompartido.reiniciarParaPruebas();
    messenger.setMockMethodCallHandler(canal, (call) async {
      llamadas.add(call.method);
      if (call.method == 'getLanguages') return ['es-MX'];
      if (call.method == 'isLanguageAvailable') return true;
      return 1;
    });
  });

  test('tras usar el reconocedor, el fin de la lectura llega al SOS',
      () async {
    // Recorrido real: Comunicarse -> leer en voz alta -> Reconocer -> volver.
    await senas.LectorVoz.instancia.decir('hola');
    var termino = 0;
    await LectorVozTts().hablar('Necesito ayuda', alTerminar: () => termino++);
    expect(termino, 0);
    await nativo('speak.onComplete');
    expect(termino, 1);
    // Y la siguiente lectura tambien termina.
    await LectorVozTts().hablar('Otra vez', alTerminar: () => termino++);
    await nativo('speak.onComplete');
    expect(termino, 2);
    expect(llamadas.where((m) => m == 'awaitSpeakCompletion'), isNotEmpty);
  });

  test('si el reconocedor habla encima, el boton de lectura se resetea',
      () async {
    var termino = 0;
    await LectorVozTts().hablar('Necesito ayuda', alTerminar: () => termino++);
    expect(termino, 0);
    await senas.LectorVoz.instancia.decir('casa');
    expect(termino, 1);
  });

  test('leer en voz alta corta al reconocedor en vez de no hacer nada',
      () async {
    await senas.LectorVoz.instancia.decir('casa');
    llamadas.clear();
    var termino = 0;
    await LectorVozTts().hablar('Necesito ayuda', alTerminar: () => termino++);
    // Primero se corta lo que sonaba y despues se habla.
    expect(llamadas.where((m) => m == 'stop' || m == 'speak').toList(),
        ['stop', 'speak']);
    expect(termino, 0);
  });

  test('el "se corto" tardio de la lectura cortada no cierra la nueva',
      () async {
    await senas.LectorVoz.instancia.decir('casa');
    var termino = 0;
    await LectorVozTts().hablar('Necesito ayuda', alTerminar: () => termino++);
    // El motor avisa del corte del reconocedor despues de tomar la ranura.
    await nativo('speak.onCancel');
    expect(termino, 0, reason: 'el cancel era de la lectura anterior');
    await nativo('speak.onStart');
    // Ya hablando la nueva: un corte de verdad si la cierra.
    await nativo('speak.onCancel');
    expect(termino, 1);
  });

  test('el aviso tardio del lector cortado no resetea al lector nuevo',
      () async {
    var terminoA = 0;
    var terminoB = 0;
    final a = LectorVozTts();
    final b = LectorVozTts();
    await a.hablar('uno', alTerminar: () => terminoA++);
    await b.hablar('dos', alTerminar: () => terminoB++);
    expect(terminoA, 1, reason: 'a se entera de que lo cortaron');
    await nativo('speak.onCancel'); // cancel de "uno", llega tarde
    expect(terminoB, 0);
    await nativo('speak.onStart');
    await nativo('speak.onComplete');
    expect(terminoB, 1);
    expect(terminoA, 1);
  });

  test('detener antes de que arranque la voz si cierra la lectura', () async {
    await senas.LectorVoz.instancia.decir('casa');
    var termino = 0;
    final r = LectorVozTts();
    await r.hablar('Necesito ayuda', alTerminar: () => termino++);
    await r.detener();
    await nativo('speak.onCancel');
    expect(termino, 1);
  });

  test('un fallo del motor cierra la lectura aunque no llegue el inicio',
      () async {
    await senas.LectorVoz.instancia.decir('casa');
    var termino = 0;
    await LectorVozTts().hablar('Necesito ayuda', alTerminar: () => termino++);
    await nativo('speak.onError');
    expect(termino, 1);
    // Y la siguiente lectura no hereda el "ignorar cancel".
    await LectorVozTts().hablar('Otra', alTerminar: () => termino++);
    await nativo('speak.onCancel');
    expect(termino, 2, reason: 'sin voz previa no hay cancel que ignorar');
  });
}
