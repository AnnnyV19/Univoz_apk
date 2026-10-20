import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:senas_core/plantillas.dart';
import 'package:senas_core/sign_norm.dart';

List<List<double>> _seq() {
  final data = jsonDecode(File('test/golden/golden_cases.json').readAsStringSync())
      as Map<String, dynamic>;
  final v = (((data['cases'] as List).first as Map)['expected_frames'] as List)
      .first as List;
  final frame = v.map((x) => (x as num).toDouble()).toList();
  return List.generate(kTFrames, (_) => List<double>.from(frame));
}

void main() {
  test('armarClasificador espeja paquete y locales sin duplicar espejos', () {
    final seq = _seq();
    final d = armarClasificador(
      base: [
        PlantillaFuente('s1', 'HOLA', 'hola', seq),
        // El paquete ya trae el espejo de s1: no se agrega otro.
        PlantillaFuente('s1#espejo', 'HOLA', 'hola', seq.map(mirrorFrame).toList()),
        PlantillaFuente('s2', 'AGUA', '', seq),
      ],
      origenBase: OrigenPlantillas.paquete,
      locales: [PlantillaFuente('local:ADIOS', 'ADIOS', '', seq)],
      espejar: true,
    );
    final ids = d.clasificador.templates.map((t) => t.signId).toList();
    expect(ids, [
      's1', 's1#espejo', 's2', 's2#espejo', 'local:ADIOS', 'local-espejo:ADIOS',
    ]);
    expect(d.resumen.delPaquete, 3);
    expect(d.resumen.sincronizadas, 0);
    expect(d.resumen.locales, 1);
    expect(d.resumen.espejadas, 2);
    expect(d.resumen.senasDistintas, 3);
  });

  test('sin espejo automatico solo entran las plantillas tal cual', () {
    final seq = _seq();
    final d = armarClasificador(
      base: [PlantillaFuente('s1', 'HOLA', 'hola', seq)],
      origenBase: OrigenPlantillas.sincronizadas,
      locales: const [],
      espejar: false,
      maxDistance: .4,
      minMargin: .2,
    );
    expect(d.clasificador.templates.map((t) => t.signId), ['s1']);
    expect(d.resumen.sincronizadas, 1);
    expect(d.resumen.espejadas, 0);
    expect(d.clasificador.maxDistance, .4);
    expect(d.clasificador.minMargin, .2);
  });
}
