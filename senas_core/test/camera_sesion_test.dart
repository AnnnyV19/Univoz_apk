import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:senas_core/camera_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('una pantalla nueva no hereda un numero de sesion viejo', () async {
    // Misma regla que LandmarkPlugin.kt: el token solo crece y una sesion
    // distinta del token se cancela.
    var token = 0;
    final canal = TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger;
    canal.setMockMethodCallHandler(const MethodChannel(kCanalMetodos),
        (llamada) async {
      final sesion = (llamada.arguments as Map)['session'] as int;
      if (sesion > token) token = sesion;
      if (llamada.method == 'detener') return null;
      if (sesion != token) {
        throw PlatformException(code: 'camera_start_cancelled');
      }
      return {'textureId': 1, 'espejo': false, 'ancho': 480, 'alto': 640};
    });
    addTearDown(() => canal.setMockMethodCallHandler(
        const MethodChannel(kCanalMetodos), null));

    final primera = CameraBridge();
    await primera.iniciar();
    await primera.detener();

    final segunda = CameraBridge();
    final c = await segunda.iniciar();
    expect(c.textureId, 1);
  });
}
