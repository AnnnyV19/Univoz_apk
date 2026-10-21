import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:univoz/services/curriculo.dart';

void main() {
  test('todas las glosas del camino existen en plantillas.json', () {
    final j = jsonDecode(File('assets/plantillas.json').readAsStringSync())
        as Map<String, dynamic>;
    final enDiccionario = <String>{
      for (final p in (j['plantillas'] as List)) (p as Map)['gloss'] as String,
    };
    final faltan =
        todasLasGlosas.where((g) => !enDiccionario.contains(g)).toList();
    expect(faltan, isEmpty);
  });

  test('cada glosa aparece una sola vez en el camino', () {
    final todas = [for (final l in leccionesEnOrden) ...l.glosas];
    expect(todas.length, todas.toSet().length);
    expect(todas.length, 44);
  });

  test('ids de lección únicos', () {
    final ids = leccionesEnOrden.map((l) => l.id).toList();
    expect(ids.length, ids.toSet().length);
  });

  test('letrasDeNombre', () {
    expect(letrasDeNombre('Lani'), ['L', 'A', 'N', 'I']);
    expect(letrasDeNombre('Ñandú'), ['NN', 'A', 'N', 'D', 'U']);
    expect(letrasDeNombre(null), isEmpty);
  });

  test('cada ejercicio de reconocimiento tiene 4 opciones distintas con la respuesta',
      () {
    final rng = Random(1);
    for (final l in leccionesEnOrden) {
      for (final e in generarLeccion(l, nombre: 'Lani', azar: rng)) {
        if (e.tipo == TipoEjercicio.deletrea) continue;
        expect(e.opciones.length, 4, reason: l.id);
        expect(e.opciones.toSet().length, 4, reason: l.id);
        expect(e.opciones, contains(e.esperado.first), reason: l.id);
      }
    }
  });

  test('la lección de nombre termina deletreando', () {
    final l = leccionesEnOrden.firstWhere((x) => x.deletrea);
    final ej = generarLeccion(l, nombre: 'Lani', azar: Random(2));
    expect(ej.last.tipo, TipoEjercicio.deletrea);
    expect(ej.last.esperado, ['L', 'A', 'N', 'I']);
  });

  test('un ejercicio fallado vuelve al final y no cuenta como a la primera', () {
    final l = leccionesEnOrden.first;
    final ej = generarLeccion(l, azar: Random(3));
    final s = SesionLeccion(ej);
    final total = s.totalInicial;
    final primero = s.actual!;
    expect(s.responder(['__mal__']), isFalse);
    expect(s.hechos, 0);
    var guardia = 0;
    while (!s.terminada && guardia++ < 200) {
      s.responder(s.actual!.esperado);
    }
    expect(s.terminada, isTrue);
    expect(s.hechos, total);
    expect(s.aciertosPrimera, total - 1);
    expect(s.glosasFalladas, containsAll(primero.esperado));
    expect(s.progreso, 1.0);
  });
}
