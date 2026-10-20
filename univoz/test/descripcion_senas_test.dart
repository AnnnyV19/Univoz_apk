import 'package:flutter_test/flutter_test.dart';
import 'package:univoz/services/curriculo.dart';
import 'package:univoz/services/descripcion_senas.dart';

void main() {
  test('las 29 letras del abecedario tienen descripción', () {
    final letras = [
      for (var c = 65; c <= 90; c++) String.fromCharCode(c),
      'LL',
      'NN',
      'RR',
    ];
    for (final l in letras) {
      final d = descripcionDe(l);
      expect(d, isNotNull, reason: 'falta la descripción de $l');
      expect(d!.trim().length, greaterThan(15), reason: 'muy corta: $l');
    }
  });

  test('toda glosa con descripción existe en el camino de aprendizaje', () {
    for (final g in glosasConDescripcion()) {
      expect(todasLasGlosas.contains(g), isTrue, reason: '$g no está en el camino');
    }
  });

  test('una seña sin descripción devuelve null', () {
    expect(descripcionDe('HOLA'), isNull);
  });
}
