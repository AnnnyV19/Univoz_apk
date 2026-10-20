import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:senas_core/camera_bridge.dart';
import 'package:senas_core/controlador_captura.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Canal nativo de la camara simulado: detener() responde al instante.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel(kCanalMetodos), (call) async => null);
  });

  test('salir de la pantalla no usa el frame despues de liberarlo', () async {
    // dispose() lanza apagar() sin esperarlo: apagar() termina despues y no
    // debe tocar el ValueNotifier ya liberado (Galaxy S22+, 2026-10-19:
    // "A ValueNotifier<LandmarkFrame?> was used after being disposed").
    final ctrl = ControladorCaptura();
    // Como en el telefono: la camara venia mandando frames.
    ctrl.frame.value = LandmarkFrame.fromMap({'t': 1});
    ctrl.dispose();
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(ctrl.estado, EstadoCamara.detenida);
  });
}
