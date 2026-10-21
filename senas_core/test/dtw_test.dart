/// Golden test del clasificador DTW: valida que Dart calcule las mismas
/// distancias que Python sobre los mismos frames.
///
///   dart test
///
/// Dentro de un proyecto de Flutter: cambia el import de package:test por
/// package:flutter_test/flutter_test.dart y corre `flutter test`.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:test/test.dart';

import 'package:senas_core/dtw.dart';
import 'package:senas_core/sign_norm.dart';

const String kGoldenPath = 'test/golden/golden_cases.json';

List<double> _vec(dynamic raw) =>
    (raw as List).map<double>((v) => (v as num).toDouble()).toList();

List<List<double>> _seq(dynamic raw) =>
    (raw as List).map<List<double>>(_vec).toList();

void main() {
  final file = File(kGoldenPath);
  if (!file.existsSync()) {
    throw StateError('no encuentro $kGoldenPath — corre python3 tools/gen_golden.py');
  }
  final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final tol = (data['tolerance'] as num).toDouble();
  final dtwGolden = data['dtw'] as Map<String, dynamic>;

  final casos = data['cases'] as List;
  final a = _seq((casos[0] as Map)['expected_frames']);
  final b = _seq((casos[1] as Map)['expected_frames']);

  test('los pesos coinciden con los de Python', () {
    final p = dtwGolden['pesos'] as Map<String, dynamic>;
    expect(p['body'], kWBody);
    expect(p['loc'], kWLoc);
    expect(p['pres'], kWPres);
    expect(p['shape'], kWShape);
    expect(p['shape_penalty'], kShapePenalty);
    expect(p['band'], kBand);
  });

  test('los umbrales por defecto coinciden con los de Python', () {
    final u = dtwGolden['umbrales'] as Map<String, dynamic>;
    expect(u['max_distance'], kMaxDistanceDefault);
    expect(u['min_margin'], kMinMarginDefault);

    final clf = DtwClassifier();
    expect(clf.maxDistance, kMaxDistanceDefault);
    expect(clf.minMargin, kMinMarginDefault);
  });

  test('distancias entre frames', () {
    final esperado = (dtwGolden['frame_distances'] as List).map(_vec).toList();
    for (var i = 0; i < a.length; i++) {
      for (var j = 0; j < b.length; j++) {
        expect((frameDistance(a[i], b[j]) - esperado[i][j]).abs(), lessThan(tol),
            reason: 'frame_distance($i, $j)');
      }
    }
  });

  test('la distancia entre frames es simetrica y cero consigo misma', () {
    expect(frameDistance(a[0], a[0]), 0.0);
    expect((frameDistance(a[0], b[0]) - frameDistance(b[0], a[0])).abs(),
        lessThan(1e-12));
  });

  test('DTW coincide con Python', () {
    expect((dtwDistance(a, a) - (dtwGolden['dtw_a_a'] as num).toDouble()).abs(),
        lessThan(tol));
    expect((dtwDistance(a, b) - (dtwGolden['dtw_a_b'] as num).toDouble()).abs(),
        lessThan(tol));
    expect((dtwDistance(b, a) - (dtwGolden['dtw_b_a'] as num).toDouble()).abs(),
        lessThan(tol));
  });

  test('signature coincide con Python', () {
    final esperado = _vec(dtwGolden['signature_a']);
    final got = signature(a);
    expect(got.length, kFrameDim);
    for (var i = 0; i < kFrameDim; i++) {
      expect((got[i] - esperado[i]).abs(), lessThan(tol), reason: 'dim $i');
    }
  });

  test('el ceiling corta sin cambiar el resultado cuando no aplica', () {
    final d = dtwDistance(a, b);
    expect(dtwDistance(a, b, ceiling: d * 2), closeTo(d, 1e-12));
    expect(dtwDistance(a, b, ceiling: d * 0.1), double.infinity);
  });

  test('el clasificador elige la plantilla correcta', () {
    final clf = DtwClassifier(prefilter: 0);
    clf.add('1', 'CASA', a);
    clf.add('2', 'AGUA', b);

    final p = clf.classify(a);
    expect(p.gloss, 'CASA');
    expect(p.distance, lessThan(1e-9));
    expect(p.aceptada, isTrue);

    final q = clf.classify(b);
    expect(q.gloss, 'AGUA');
  });

  test('classifyRanking decide igual que classify con un solo DTW', () {
    final clf = DtwClassifier(prefilter: 0);
    clf.add('1', 'CASA', a);
    clf.add('2', 'AGUA', b);
    for (final q in [a, b]) {
      final ranking = clf.rank(q);
      final p = clf.classifyRanking(ranking);
      final r = clf.classify(q);
      expect(p.gloss, r.gloss);
      expect(p.distance, r.distance);
      expect(p.margin, r.margin);
      expect(p.aceptada, r.aceptada);
    }
    expect(clf.classifyRanking(const []).aceptada, isFalse);
  });

  test('el abandono temprano no altera el margen', () {
    // Secuencias constantes con la mano izquierda presente y UNA dimension de
    // su forma desplazada: el DTW entre dos es exactamente la distancia entre
    // sus frames. Distancia de frame = delta * sqrt(kWShape / kNShape). La
    // mejor plantilla queda a 0.100 y la de otra glosa a 0.160: margen 0.375.
    // Con un minimo de 0.45 hay que RECHAZAR (con factor fijo 1.5 daba 1.0).
    List<List<double>> constante(double delta) => List.generate(32, (_) {
          final f = List<double>.filled(kFrameDim, 0.0);
          f[kOffPresL] = 1.0;
          f[kOffShapeL] = delta;
          return f;
        });
    final k = math.sqrt(kWShape / kNShape);

    final clf = DtwClassifier(maxDistance: 1.0, minMargin: 0.45, prefilter: 0);
    clf.add('1', 'A', constante(0.100 / k));
    clf.add('2', 'B', constante(0.160 / k));

    final p = clf.classify(constante(0.0));
    expect(p.gloss, 'A');
    expect(p.distance, closeTo(0.100, 1e-9));
    expect(p.margin, closeTo(0.375, 1e-9));
    expect(p.aceptada, isFalse);
  });

  group('ubicacion sin posicion absoluta, prefiltro por tramos', () {
    final bloque = dtwGolden['clasificador'] as Map<String, dynamic>;

    test('centrarUbicacion coincide con Python y no toca el original', () {
      final copia = a.map((f) => List<double>.from(f)).toList();
      final got = centrarUbicacion(a);
      final esperado = _seq(dtwGolden['centrado_a']);
      for (var i = 0; i < a.length; i++) {
        for (var d = 0; d < kFrameDim; d++) {
          expect((got[i][d] - esperado[i][d]).abs(), lessThan(tol),
              reason: 'frame $i dim $d');
          expect(a[i][d], copia[i][d], reason: 'el original cambio');
        }
      }
    });

    test('firmaSegmentos coincide con Python', () {
      expect(dtwGolden['n_segmentos'], kNSegmentos);
      final got = firmaSegmentos(a);
      final esperado = _seq(dtwGolden['firma_segmentos_a']);
      expect(got.length, esperado.length);
      for (var s = 0; s < got.length; s++) {
        for (var d = 0; d < kFrameDim; d++) {
          expect((got[s][d] - esperado[s][d]).abs(), lessThan(tol),
              reason: 'segmento $s dim $d');
        }
      }
    });

    test('la misma sena hecha a otra altura se reconoce igual que en Python',
        () {
      final clf = DtwClassifier(prefilter: 0);
      clf.add('1', 'CASA', a);
      clf.add('2', 'AGUA', b);

      final p = clf.classify(_seq(bloque['consulta_a_desplazada']));
      expect(p.gloss, bloque['gloss']);
      expect((p.distance - (bloque['distance'] as num)).abs(), lessThan(tol));
      expect((p.margin - (bloque['margin'] as num)).abs(), lessThan(tol));
      expect(p.aceptada, bloque['aceptada']);

      final q = clf.classify(_seq(bloque['consulta_b_desplazada']));
      expect(q.gloss, bloque['gloss_b']);
      expect((q.distance - (bloque['distance_b'] as num)).abs(), lessThan(tol));
      expect((q.margin - (bloque['margin_b'] as num)).abs(), lessThan(tol));
    });

    test('el prefiltro por tramos da el mismo resultado que sin prefiltro', () {
      final completo = DtwClassifier(prefilter: 0);
      final filtrado = DtwClassifier(prefilter: 1);
      for (final g in ['CASA', 'AGUA']) {
        final s = g == 'CASA' ? a : b;
        completo.add(g, g, s);
        filtrado.add(g, g, s);
      }
      expect(filtrado.classify(a).gloss, completo.classify(a).gloss);
      expect(filtrado.classify(b).gloss, completo.classify(b).gloss);
    });
  });

  test('rechaza cuando nada se parece', () {
    final clf = DtwClassifier(prefilter: 0);
    clf.add('1', 'CASA', a);

    final lejos = a
        .map((f) => List<double>.generate(kFrameDim, (i) => f[i] + 3.0))
        .toList();
    expect(clf.classify(lejos).aceptada, isFalse);
  });
}
