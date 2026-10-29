import 'package:flutter_test/flutter_test.dart';
import 'package:univoz/widgets/visor_sena.dart';

void main() {
  List<List<double>> seq(double v) => [
        [v]
      ];

  test('no pasa del tope y suelta la menos usada', () {
    final c = CacheSecuenciasLru(capacidad: 3);
    c.guardar('a', seq(1));
    c.guardar('b', seq(2));
    c.guardar('c', seq(3));
    expect(c.obtener('a'), seq(1)); // a pasa a ser la mas reciente
    c.guardar('d', seq(4)); // sale b
    expect(c.length, 3);
    expect(c.obtener('b'), isNull);
    expect(c.obtener('a'), isNotNull);
    expect(c.obtener('c'), isNotNull);
    expect(c.obtener('d'), isNotNull);
  });

  test('guardar de nuevo la misma glosa no duplica', () {
    final c = CacheSecuenciasLru(capacidad: 2);
    c.guardar('a', seq(1));
    c.guardar('a', seq(9));
    expect(c.length, 1);
    expect(c.obtener('a'), seq(9));
  });

  test('el tope por defecto es 64', () {
    final c = CacheSecuenciasLru();
    for (var i = 0; i < 200; i++) {
      c.guardar('g$i', seq(i.toDouble()));
    }
    expect(c.length, 64);
    expect(c.obtener('g199'), isNotNull);
    expect(c.obtener('g0'), isNull);
  });
}
