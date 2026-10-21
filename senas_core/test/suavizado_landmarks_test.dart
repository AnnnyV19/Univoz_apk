import 'dart:math' as math;

import 'package:senas_core/camera_bridge.dart';
import 'package:senas_core/suavizado_landmarks.dart';
import 'package:test/test.dart';

const double _dt = 1.0 / 30.0;

List<List<double>> _mano(double x, double y) =>
    List.generate(21, (i) => <double>[x + i * 0.001, y, 0.1]);

List<List<double>> _pose(double x, double y) =>
    List.generate(33, (i) => <double>[x, y + i * 0.001, 0.0, 0.9]);

LandmarkFrame _frame(int t,
        {List<List<double>>? pose,
        List<List<double>>? left,
        List<List<double>>? right}) =>
    LandmarkFrame(timestampMs: t, pose: pose, left: left, right: right);

void main() {
  group('FiltroOneEuro', () {
    test('una entrada constante sale igual', () {
      final f = FiltroOneEuro();
      for (var i = 0; i < 30; i++) {
        expect(f.filtrar(0.42, _dt), closeTo(0.42, 1e-12));
      }
    });

    test('el temblor con el punto quieto baja a menos de la mitad', () {
      // Referencia (Python, mismo algoritmo): +-0.005 alternando -> ~0.0012
      // pico a pico, o sea ~0.12 del temblor de entrada.
      final f = FiltroOneEuro();
      final salida = <double>[];
      for (var i = 0; i < 60; i++) {
        final x = 0.5 + (i.isEven ? 0.005 : -0.005);
        salida.add(f.filtrar(x, _dt));
      }
      final cola = salida.sublist(30);
      final pico = cola.reduce(math.max) - cola.reduce(math.min);
      expect(pico, lessThan(0.005)); // la entrada tenia 0.010 pico a pico
      expect(pico, closeTo(0.00119, 0.0004));
    });

    test('un salto rapido se sigue casi al instante', () {
      // Referencia: 0.2 -> 0.8 da 0.7225, 0.7883, 0.7979 en los 3 primeros
      // cuadros tras el salto.
      final f = FiltroOneEuro();
      for (var i = 0; i < 10; i++) {
        f.filtrar(0.2, _dt);
      }
      expect(f.filtrar(0.8, _dt), closeTo(0.7225, 0.01));
      expect(f.filtrar(0.8, _dt), closeTo(0.7883, 0.01));
      expect(f.filtrar(0.8, _dt), closeTo(0.7979, 0.01));
    });

    test('una rampa lenta se sigue con retraso pequeno', () {
      final f = FiltroOneEuro();
      double x = 0, y = 0;
      for (var i = 0; i < 90; i++) {
        x = 0.2 + 0.3 * i * _dt;
        y = f.filtrar(x, _dt);
      }
      expect(x - y, inInclusiveRange(0.0, 0.03));
    });
  });

  group('SuavizadorLandmarks', () {
    test('conserva todo lo que no es pose ni manos', () {
      final s = SuavizadorLandmarks();
      final entrada = LandmarkFrame(
        timestampMs: 100,
        pose: _pose(0.5, 0.4),
        poseMundo: [
          [0.1, 0.2, 0.3]
        ],
        left: _mano(0.3, 0.6),
        renderLeft: _mano(0.31, 0.6),
        poseTimestampMs: 90,
        handsTimestampMs: 100,
        sourceSkewMs: 10,
        association: const {'left_state': 'TRACKING'},
      );
      final salida = s.filtrar(entrada);
      expect(salida.timestampMs, 100);
      expect(salida.poseMundo, entrada.poseMundo);
      expect(salida.renderLeft, entrada.renderLeft);
      expect(salida.poseTimestampMs, 90);
      expect(salida.handsTimestampMs, 100);
      expect(salida.sourceSkewMs, 10);
      expect(salida.association['left_state'], 'TRACKING');
      expect(salida.right, isNull);
      // El primer cuadro sale igual: no hay historia que mezclar.
      expect(salida.pose![5][0], closeTo(0.5, 1e-12));
      expect(salida.left![3][2], 0.1); // z pasa sin tocar
      expect(salida.pose![5][3], 0.9); // visibilidad pasa sin tocar
    });

    test('suaviza el temblor de la mano y de la pose', () {
      final s = SuavizadorLandmarks();
      double maxEntrada = 0, maxSalida = 0;
      for (var i = 0; i < 80; i++) {
        final ruido = i.isEven ? 0.005 : -0.005;
        final f = _frame(i * 33,
            pose: _pose(0.5 + ruido, 0.4), left: _mano(0.3 + ruido, 0.6));
        final out = s.filtrar(f);
        if (i >= 40) {
          maxEntrada = math.max(maxEntrada, (f.left![0][0] - 0.3).abs());
          maxSalida = math.max(maxSalida, (out.left![0][0] - 0.3).abs());
          expect((out.pose![0][0] - 0.5).abs(), lessThan(0.002));
        }
      }
      expect(maxSalida, lessThan(maxEntrada * 0.5));
    });

    test('si la mano desaparece y vuelve, arranca desde su posicion real', () {
      final s = SuavizadorLandmarks();
      for (var i = 0; i < 20; i++) {
        s.filtrar(_frame(i * 33, pose: _pose(0.5, 0.4), left: _mano(0.2, 0.6)));
      }
      final sinMano = s.filtrar(_frame(20 * 33, pose: _pose(0.5, 0.4)));
      expect(sinMano.left, isNull);
      final vuelve =
          s.filtrar(_frame(21 * 33, pose: _pose(0.5, 0.4), left: _mano(0.8, 0.3)));
      expect(vuelve.left![0][0], closeTo(0.8, 1e-12));
      expect(vuelve.left![0][1], closeTo(0.3, 1e-12));
    });

    test('un cuadro con el mismo instante no vuelve a filtrar', () {
      final s = SuavizadorLandmarks();
      s.filtrar(_frame(0, left: _mano(0.2, 0.6)));
      final a = s.filtrar(_frame(33, left: _mano(0.25, 0.6)));
      final b = s.filtrar(_frame(33, left: _mano(0.25, 0.6)));
      expect(b.left![0][0], a.left![0][0]);
      // y la siguiente muestra real sigue avanzando normalmente
      final c = s.filtrar(_frame(66, left: _mano(0.30, 0.6)));
      expect(c.left![0][0], greaterThan(a.left![0][0]));
    });

    test('un hueco largo sin muestras reinicia en vez de arrastrar', () {
      final s = SuavizadorLandmarks();
      for (var i = 0; i < 10; i++) {
        s.filtrar(_frame(i * 33, left: _mano(0.2, 0.6)));
      }
      final tarde = s.filtrar(_frame(10 * 33 + 2000, left: _mano(0.7, 0.2)));
      expect(tarde.left![0][0], closeTo(0.7, 1e-12));
    });

    test('un punto no finito pasa tal cual y no rompe a los demas', () {
      final s = SuavizadorLandmarks();
      final mano = _mano(0.4, 0.4);
      mano[7] = <double>[double.nan, 0.4, 0.0];
      final out = s.filtrar(_frame(0, left: mano));
      expect(out.left![7][0].isNaN, isTrue);
      expect(out.left![8][0], closeTo(0.408, 1e-12));
    });
  });
}
