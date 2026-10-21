import 'package:flutter/services.dart';
import 'package:test/test.dart';

import 'package:senas_core/camera_bridge.dart';
import 'package:senas_core/controlador_captura.dart';

void main() {
  _erroresNativos();
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

  test('native model init failure has its own message', () {
    final message = mensajeErrorCamara(
      PlatformException(
        code: 'mediapipe_init',
        message: 'java.lang.ExceptionInInitializerError',
      ),
    );

    expect(message, contains('reconocimiento de señas'));
    expect(message, isNot(contains('ExceptionInInitializerError')));
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

void _erroresNativos() {
  test('errores del stream nativo se traducen a un texto amable', () {
    for (final code in ['mediapipe', 'analisis']) {
      final message = mensajeErrorCamara(
        PlatformException(code: code, message: 'IllegalStateException: x'),
      );
      expect(message, 'Hubo un problema con la cámara.');
    }
  });

  test('cada codigo conocido tiene su texto y ninguno filtra detalles', () {
    const codigos = [
      'camera_permission',
      'camera_busy',
      'camera_unavailable',
      'camera_start_cancelled',
      'camera_start_failed',
      'mediapipe',
      'analisis',
    ];
    final textos = {
      for (final c in codigos)
        c: mensajeErrorCamara(PlatformException(code: c, message: 'secreto')),
    };
    for (final t in textos.values) {
      expect(t, isNot(contains('secreto')));
    }
    expect(textos['camera_permission'], contains('permiso'));
    expect(textos['camera_busy'], contains('otra aplicación'));
  });
}
