import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:senas_core/camera_bridge.dart';
import 'package:senas_core/frame_derivados.dart';
import 'package:senas_core/sign_norm.dart' show calidadFrame;

/// Frames reales (golden de sign_norm); cada llamada devuelve instancias nuevas.
List<LandmarkFrame> _frames() {
  final data = jsonDecode(File('test/golden/golden_cases.json').readAsStringSync())
      as Map<String, dynamic>;
  final out = <LandmarkFrame>[];
  for (final c in data['cases'] as List) {
    for (final f in (c as Map)['frames'] as List) {
      out.add(LandmarkFrame.fromMap({
        't': out.length,
        'pose': f['pose'],
        'poseMundo': f['pose_mundo'],
        'left': f['left'],
        'right': f['right'],
      }));
    }
  }
  return out;
}

void main() {
  test('normalizarCacheado == normalize() y la 2a llamada devuelve la misma instancia',
      () {
    final frames = _frames();
    expect(frames, isNotEmpty);
    for (final f in frames) {
      final directo = f.normalize();
      final a = normalizarCacheado(f);
      expect(a, directo);
      expect(identical(normalizarCacheado(f), a), isTrue);
    }
  });

  test('normalizarRenderCacheado == normalizeForRender() y se memoiza', () {
    for (final f in _frames()) {
      final directo = f.normalizeForRender();
      final a = normalizarRenderCacheado(f);
      expect(a, directo);
      expect(identical(normalizarRenderCacheado(f), a), isTrue);
    }
  });

  test('calidadCacheada coincide con calidadFrame y 0 si no hay vector', () {
    for (final f in _frames()) {
      expect(calidadCacheada(f),
          calidadFrame(f.pose, f.poseMundo, f.left, f.right));
    }
    const sinPose = LandmarkFrame(timestampMs: 1);
    expect(calidadCacheada(sinPose), 0.0);
  });

  test('un frame no normalizable cachea null sin recalcular', () {
    final f = LandmarkFrame(timestampMs: 1, sourceSkewMs: 500);
    expect(normalizarCacheado(f), isNull);
    expect(normalizarCacheado(f), isNull);
    expect(normalizarRenderCacheado(f), isNull);
    expect(signSpaceCacheado(f), isNull);
  });

  test('frames distintos no comparten cache', () {
    final f = _frames();
    final a = normalizarCacheado(f[0]);
    final b = normalizarCacheado(f[1]);
    expect(identical(a, b), isFalse);
    expect(a, f[0].normalize());
    expect(b, f[1].normalize());
  });

  test('signSpaceCacheado se memoiza por perfil y recalcula si cambia', () {
    final f = _frames().first;
    final a = signSpaceCacheado(f);
    expect(a, isNotNull);
    expect(identical(signSpaceCacheado(f), a), isTrue);
    expect(a!.toJson(), f.signSpace()!.toJson());

    final perfil = <String, double?>{'upperArm': 0.3, 'forearm': 0.25};
    final b = signSpaceCacheado(f, profileMeasures: perfil);
    expect(b!.toJson(),
        f.signSpace(profileMeasures: perfil)!.toJson());
    expect(identical(signSpaceCacheado(f, profileMeasures: perfil), b), isTrue);
    // Cambiar de perfil no devuelve el resultado del anterior.
    expect(identical(signSpaceCacheado(f), b), isFalse);
  });
}
