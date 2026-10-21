import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('pantallas visibles usan avatar real, no placeholder de persona', () {
    final comunicarse = File('../univoz/lib/screens/comunicarse_screen.dart')
        .readAsStringSync();
    final avatar = File('lib/pantalla_avatar.dart').readAsStringSync();

    // VistaAvatar envuelve AvatarViewport con estado de carga/error. La
    // seccion "Aprender" es PantallaAvatar (aprender_screen.dart ya no existe).
    expect(avatar, contains('VistaAvatar'));
    expect(comunicarse, contains('VistaAvatar'));
    expect(avatar, isNot(contains('Icons.person')));
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
    // Cadena de brazo con el hombro anatomico (rig_hand_capture.mjs).
    expect(visor, contains('const leftShoulder = coord(pose?.[11]);'));
    expect(visor, contains('const rightShoulder = coord(pose?.[12]);'));
    expect(visor, contains("resolverBrazo('left'"));
    expect(visor, contains("resolverBrazo('right'"));
  });
}
