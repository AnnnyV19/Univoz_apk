import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:senas_core/avatar_vivo.dart';
import 'package:senas_core/camera_bridge.dart';

/// Frame real (golden de sign_norm) con un timestamp dado.
LandmarkFrame _frame(int t, {Map<String, Object?> extra = const {}}) {
  final data = jsonDecode(File('test/golden/golden_cases.json').readAsStringSync())
      as Map<String, dynamic>;
  final f = ((data['cases'] as List).first as Map)['frames'][0] as Map;
  return LandmarkFrame.fromMap({
    't': t,
    'pose': f['pose'],
    'poseMundo': f['pose_mundo'],
    'left': f['left'],
    'right': f['right'],
    ...extra,
  });
}

void main() {
  test('último frame gana y nunca hay dos envíos en vuelo', () async {
    var enVuelo = 0;
    var maxEnVuelo = 0;
    final enviados = <int?>[];
    final alimentador = AlimentadorAvatar(
      enviar: (v, {renderFrame, timestampMs, quality = 1.0, sourceMeta}) async {
        enVuelo++;
        if (enVuelo > maxEnVuelo) maxEnVuelo = enVuelo;
        await Future<void>.delayed(const Duration(milliseconds: 40));
        enviados.add(timestampMs);
        enVuelo--;
      },
    );
    alimentador.iniciar();
    for (var i = 1; i <= 10; i++) {
      alimentador.alFrame(_frame(i));
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(maxEnVuelo, 1);
    expect(enviados.first, 1);
    // Los 9 frames que llegaron durante el primer envío colapsan en el último.
    expect(enviados.last, 10);
    expect(enviados.length, lessThanOrEqualTo(3));
    expect(alimentador.framesEnviados, enviados.length);
  });

  test('detener descarta lo pendiente y no envía más', () async {
    final enviados = <int?>[];
    final alimentador = AlimentadorAvatar(
      enviar: (v, {renderFrame, timestampMs, quality = 1.0, sourceMeta}) async {
        enviados.add(timestampMs);
      },
    );
    alimentador.iniciar();
    alimentador.alFrame(_frame(1));
    alimentador.alFrame(_frame(2)); // espera el intervalo de 33 ms
    alimentador.detener();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    alimentador.alFrame(_frame(3));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(enviados, [1]);
  });

  test('la calidad enviada al visor es la de la web, no el hombro minimo',
      () async {
    final calidades = <double>[];
    final alimentador = AlimentadorAvatar(
      enviar: (v, {renderFrame, timestampMs, quality = 1.0, sourceMeta}) async {
        calidades.add(quality);
      },
    );
    alimentador.iniciar();
    final f = _frame(1);
    alimentador.alFrame(f);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calidades.single, closeTo(f.calidad, 1e-12));
    expect(calidades.single, isNot(closeTo(f.visibilidadMin!, 1e-6)));
  });

  test('sourceMeta lleva nivel, mano y asociación del frame', () {
    final meta = sourceMetaDeFrame(_frame(5, extra: {
      'tier': 'medio',
      'infer_ms': 42.0,
      'thermal': 1,
    }));
    expect(meta['tier'], 'medio');
    expect(meta['infer_ms'], 42.0);
    expect(meta['thermal'], 1);
    expect(meta['has_hand'], isTrue);
    expect(meta.containsKey('association'), isTrue);
    expect(meta.containsKey('tracks'), isTrue);
    expect(meta.containsKey('errors'), isTrue);
  });

  test('sourceMeta lleva el seguimiento nativo para los contadores del visor',
      () {
    final meta = sourceMetaDeFrame(_frame(5, extra: {
      'track': {
        'left': {'state': 'TRACKING', 'recovery_frames': 2, 'surface_changes': 1},
        'right': {'state': 'LOST', 'recovery_frames': 0, 'surface_changes': 0},
      },
    }));
    expect((meta['hand_track'] as Map)['left']['recovery_frames'], 2);
  });
}
