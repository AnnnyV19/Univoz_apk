import 'package:test/test.dart';

import 'package:senas_core/camera_bridge.dart';
import 'package:senas_core/continuidad_deteccion.dart';

List<List<double>> _mano() => List.generate(21, (_) => [.5, .5, 0.0]);

List<List<double>> _pose({double visMuneca = .9}) => List.generate(
    33, (i) => [.5, .5, 0.0, (i == 15 || i == 16) ? visMuneca : .9]);

LandmarkFrame _f(int t,
        {bool izq = false,
        bool der = false,
        bool pose = true,
        bool cara = false,
        double visMuneca = .9,
        double? infer,
        String modo = 'holistic'}) =>
    LandmarkFrame(
      timestampMs: t,
      pose: pose ? _pose(visMuneca: visMuneca) : null,
      left: izq ? _mano() : null,
      right: der ? _mano() : null,
      face: cara ? List.generate(17, (_) => [.5, .5, 0.0]) : null,
      inferMs: infer,
      captureMode: modo,
    );

void main() {
  test('no emite hasta cerrar la ventana', () {
    final r = ResumenContinuidad(ventanaMs: 1000);
    expect(r.alFrame(_f(0)), isNull);
    expect(r.alFrame(_f(500)), isNull);
    expect(r.alFrame(_f(999)), isNull);
  });

  test('porcentajes por ventana, fps y huecos de mano', () {
    final r = ResumenContinuidad(ventanaMs: 1000);
    // 10 frames a 100 ms; izquierda en 4, derecha en 1; hueco maximo de 6.
    String? linea;
    for (var i = 0; i < 10; i++) {
      linea = r.alFrame(_f(i * 100,
              izq: i < 4, der: i == 9, cara: i.isEven, infer: 70.0 + i)) ??
          linea;
    }
    linea = r.alFrame(_f(1000)) ?? linea;
    expect(linea, isNotNull);
    expect(linea, startsWith('UNIVOZ_TRK '));
    expect(linea, contains('n=10'));
    expect(linea, contains('fps=10.0'));
    expect(linea, contains('izq=40'));
    expect(linea, contains('der=10'));
    expect(linea, contains('alguna=50'));
    expect(linea, contains('pose=100'));
    expect(linea, contains('cara=50'));
    expect(linea, contains('hueco_max=5'));
    expect(linea, contains('modo=holistic'));
    expect(linea, contains('infer_p50=74'));
  });

  test('visibilidad media de munecas y frames sin pose', () {
    final r = ResumenContinuidad(ventanaMs: 1000);
    String? linea;
    for (var i = 0; i < 4; i++) {
      linea = r.alFrame(_f(i * 250,
              pose: i != 3, visMuneca: .4)) ??
          linea;
    }
    linea = r.alFrame(_f(1000)) ?? linea;
    expect(linea, contains('pose=75'));
    expect(linea, contains('vis_mun=0.40'));
  });

  test('la ventana siguiente empieza limpia', () {
    final r = ResumenContinuidad(ventanaMs: 1000);
    for (var i = 0; i < 10; i++) {
      r.alFrame(_f(i * 100, izq: true));
    }
    final l1 = r.alFrame(_f(1000))!;
    expect(l1, contains('izq=100'));
    for (var i = 1; i < 10; i++) {
      r.alFrame(_f(1000 + i * 100));
    }
    final l2 = r.alFrame(_f(2000))!;
    expect(l2, contains('izq=0'));
  });
}
