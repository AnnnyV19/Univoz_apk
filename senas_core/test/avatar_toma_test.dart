import 'package:test/test.dart';

import 'package:senas_core/avatar_toma.dart';
import 'package:senas_core/sign_norm.dart';

/// Un cuadro con los hombros en su sitio y, si [mano], la mano derecha
/// presente en (x, y) con una forma que depende de [t].
List<double> _cuadro({bool mano = false, double x = 0, double y = 0, double t = 0}) {
  final f = List<double>.filled(kFrameDim, 0.0);
  f[0] = -0.5; // hombro izquierdo
  f[3] = 0.5; // hombro derecho
  f[9] = 0.8; // codo derecho
  f[10] = -0.6;
  if (mano) {
    f[kOffPresR] = 1.0;
    f[kOffLocR] = x;
    f[kOffLocR + 1] = y;
    for (var k = 0; k < 60; k++) {
      f[kOffShapeR + k] = 0.1 * (k % 5) + 0.05 * t;
    }
  }
  return f;
}

List<List<double>> _seq({required int desde, required int hasta}) => [
      for (var i = 0; i < kTFrames; i++)
        _cuadro(
          mano: i >= desde && i <= hasta,
          x: 0.1 * i,
          y: 0.2 + 0.01 * i,
          t: i.toDouble(),
        ),
    ];

bool _hayMano(List<double> f) => f[kOffPresR] >= 0.5 || f[kOffPresL] >= 0.5;

void main() {
  test('una seña con mano ausente al principio y al final se recorta y se estira', () {
    final seq = _seq(desde: 8, hasta: 22); // 15 cuadros con mano, 17 sin
    final out = prepararParaAvatar(seq);

    expect(out.length, kTFrames);
    expect(out.every((f) => f.length == kFrameDim), isTrue);
    expect(out.every(_hayMano), isTrue);
    // Los extremos son los cuadros reales de la ventana, sin tocar.
    expect(out.first[kOffLocR + 1], closeTo(seq[8][kOffLocR + 1], 1e-9));
    expect(out.last[kOffLocR + 1], closeTo(seq[22][kOffLocR + 1], 1e-9));
  });

  test('no mueve ni normaliza la altura de la muñeca', () {
    final seq = _seq(desde: 6, hasta: 24);
    final ys = [for (final f in seq.where(_hayMano)) f[kOffLocR + 1]];
    final out = prepararParaAvatar(seq);
    final ysOut = [for (final f in out) f[kOffLocR + 1]];

    final minIn = ys.reduce((a, b) => a < b ? a : b);
    final maxIn = ys.reduce((a, b) => a > b ? a : b);
    final minOut = ysOut.reduce((a, b) => a < b ? a : b);
    final maxOut = ysOut.reduce((a, b) => a > b ? a : b);
    expect(minOut, closeTo(minIn, 1e-9));
    expect(maxOut, closeTo(maxIn, 1e-9));
    // Y los hombros siguen donde estaban.
    expect(out.every((f) => f[0] == -0.5 && f[3] == 0.5), isTrue);
  });

  test('la altura sube de forma monótona: la interpolación no inventa vaivenes', () {
    final out = prepararParaAvatar(_seq(desde: 8, hasta: 22));
    for (var i = 1; i < out.length; i++) {
      expect(out[i][kOffLocR + 1], greaterThanOrEqualTo(out[i - 1][kOffLocR + 1] - 1e-12));
    }
  });

  test('si casi no sobra tiempo muerto, devuelve la misma secuencia', () {
    final seq = _seq(desde: 2, hasta: 29);
    expect(identical(prepararParaAvatar(seq), seq), isTrue);
  });

  test('con muy pocos cuadros con mano no estira (no hay datos)', () {
    final seq = _seq(desde: 12, hasta: 16); // 5 cuadros
    expect(identical(prepararParaAvatar(seq), seq), isTrue);
  });

  test('sin ninguna mano devuelve la misma secuencia', () {
    final seq = List.generate(kTFrames, (_) => _cuadro());
    expect(ventanaConMano(seq), isNull);
    expect(identical(prepararParaAvatar(seq), seq), isTrue);
  });

  test('una secuencia con otro largo o dimensión se deja como viene', () {
    final corta = [for (var i = 0; i < 10; i++) _cuadro(mano: true)];
    expect(identical(prepararParaAvatar(corta), corta), isTrue);
  });

  test('ventanaConMano encuentra el primer y el último cuadro con mano', () {
    final v = ventanaConMano(_seq(desde: 5, hasta: 20))!;
    expect(v.inicio, 5);
    expect(v.fin, 20);
    expect(v.largo, 16);
  });

  test('una pose fija se muestra más despacio; una seña con movimiento, no', () {
    final fija = List.generate(kTFrames, (_) => _cuadro(mano: true, x: 0.3, y: 0.4));
    expect(movimientoDe(fija), lessThan(kMovimientoPoseFija));
    expect(factorVelocidadSena(fija), 0.7);

    final movida = List.generate(
      kTFrames,
      (i) => _cuadro(mano: true, x: 0.3, y: 0.4, t: i.toDouble()),
    );
    for (var i = 0; i < movida.length; i++) {
      movida[i][12] = 0.1 * i; // la muñeca del cuerpo recorre ~3 anchos de hombro
    }
    expect(movimientoDe(movida), greaterThan(kMovimientoPoseFija));
    expect(factorVelocidadSena(movida), 1.0);
  });

  test('manosUsadas distingue una mano de la otra', () {
    final soloDerecha = List.generate(kTFrames, (_) => _cuadro(mano: true));
    final u = manosUsadas(soloDerecha);
    expect(u.derecha, isTrue);
    expect(u.izquierda, isFalse);

    final ninguna = List.generate(kTFrames, (_) => _cuadro());
    expect(manosUsadas(ninguna).derecha, isFalse);
    expect(manosUsadas(ninguna).izquierda, isFalse);
  });
}
