import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('todas las pantallas con camara activan la sesion automatica', () {
    for (final (archivo, pantalla) in const [
      ('lib/pantalla_espejo.dart', 'espejo'),
      ('lib/skeleton_painter.dart', 'traduccion'),
      ('lib/pantalla_captura.dart', 'captura'),
    ]) {
      final src = File(archivo).readAsStringSync();
      expect(src, contains('activarSesionConConsentimiento('), reason: archivo);
      expect(src, contains("pantalla: '$pantalla'"), reason: archivo);
    }
    // el consentimiento vive en un solo lugar
    final helper = File('lib/sesion_automatica.dart').readAsStringSync();
    expect(helper, contains('consentimientoSesion = true'));
    expect(File('lib/pantalla_espejo.dart').readAsStringSync(),
        isNot(contains('showDialog<bool>')));
  });

  test('guardar una muestra queda registrado en la sesion', () {
    final src = File('lib/pantalla_captura.dart').readAsStringSync();
    expect(src, contains("evento('sample_saved'"));
  });
}
