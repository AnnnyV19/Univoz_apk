import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:senas_core/camera_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('en iPhone, sin plugin nativo, dice que llegara pronto', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    // Sin handler registrado el canal responde MissingPluginException.
    Object? error;
    try {
      await CameraBridge().iniciar();
    } catch (e) {
      error = e;
    }
    expect(error, isA<UnsupportedFeatureException>());
    expect(
      mensajeErrorCamara(error!),
      'El reconocimiento de señas llegará pronto a iPhone.',
    );
  });

  test('en Android un plugin ausente sigue siendo el error generico', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(CameraBridge().iniciar(), throwsA(isA<MissingPluginException>()));
  });
}
