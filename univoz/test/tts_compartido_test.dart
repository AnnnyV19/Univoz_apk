import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:senas_core/voz.dart' as senas;
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
}
