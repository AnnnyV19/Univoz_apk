import 'package:flutter/services.dart';
import 'package:test/test.dart';

import 'package:senas_core/camera_bridge.dart';
import 'package:senas_core/controlador_captura.dart';

void main() {
  test('camera startup exposes every observable lifecycle phase', () {
    expect(
        EstadoCamara.values,
        containsAll(<EstadoCamara>[
          EstadoCamara.detenida,
          EstadoCamara.inicializando,
          EstadoCamara.enlazada,
          EstadoCamara.lista,
          EstadoCamara.error,
        ]));
  });

  test('unsupported native camera has a user-facing message', () {
    expect(
      mensajeErrorCamara(const UnsupportedFeatureException.camara()),
      contains('Android'),
    );
  });

  test('camera platform errors do not expose raw plugin details', () {
    final message = mensajeErrorCamara(
      PlatformException(
        code: 'camera_start_failed',
        message: 'IllegalStateException: internal camera details',
      ),
    );

    expect(message, contains('No se pudo iniciar'));
    expect(message, isNot(contains('IllegalStateException')));
  });

  test('preview watchdog has an actionable message', () {
    expect(
      mensajeErrorCamara(
        StateError('La cámara se conectó pero no envió imagen.'),
      ),
      contains('Revisa el encuadre'),
    );
  });
}
