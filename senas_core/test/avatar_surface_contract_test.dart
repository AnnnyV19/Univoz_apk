import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('pantallas visibles usan avatar real, no placeholder de persona', () {
    final aprender =
        File('../univoz/lib/screens/aprender_screen.dart').readAsStringSync();
    final comunicarse = File('../univoz/lib/screens/comunicarse_screen.dart')
        .readAsStringSync();

    expect(aprender, contains('AvatarViewport'));
    expect(comunicarse, contains('AvatarViewport'));
    expect(aprender, isNot(contains('Icons.person')));
    expect(comunicarse, isNot(contains('Icons.person')));
  });

  test('visor y contrato usan profundidad frontal corregida por defecto', () {
    final contrato = File('lib/motion_contract.dart').readAsStringSync();
    final visor = File('assets/avatar_viewer/index.html').readAsStringSync();

    // +Z de sign_norm = frente de la persona = frente del avatar.
    expect(contrato, contains('this.invertZ = false'));
    expect(contrato, contains("json['invert_z'] as bool? ?? false"));
    expect(visor, contains('invertZ: false'));
  });

  test('mapeo anatómico conserva izquierda y derecha del avatar', () {
    final visor = File('assets/avatar_viewer/index.html').readAsStringSync();

    expect(visor, contains('avDerecha.subVectors(pR, pL).normalize()'));
    expect(visor, contains('leftShoulder: hombroI'));
    expect(visor, contains('rightShoulder: hombroD'));
    expect(visor, contains("resolverBrazo('left'"));
    expect(visor, contains("resolverBrazo('right'"));
  });
}
