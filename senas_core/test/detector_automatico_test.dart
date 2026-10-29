import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:senas_core/camera_bridge.dart';
import 'package:senas_core/controlador_captura.dart';

LandmarkFrame _mano(int t, double x) => LandmarkFrame.fromMap({
      't': t,
      'left': List.generate(21, (i) => [x + i * .001, .5, 0.0]),
    });

/// Mano que se mueve a [velocidad] (unidades de imagen por segundo) durante
/// [msMovimiento] y luego queda quieta, entregada a [fps]. Devuelve cuando
/// arranco la grabacion y cuantos ms despues de quedarse quieta se corto.
({bool inicio, int? corteMs}) _simular(int fps,
    {double velocidad = 1.8, int msMovimiento = 600, int msTotal = 2000}) {
  final entrada = StreamController<LandmarkFrame>(sync: true);
  final detector = DetectorAutomatico(framesQuietosParaCortar: 10);
  var inicio = false;
  int? corte;
  var t = 0;
  detector.onInicioDetectado = () => inicio = true;
  detector.onFinDetectado = () => corte = t - msMovimiento;
  detector.iniciar(entrada.stream);
  final paso = 1000 / fps;
  for (var i = 0; i * paso <= msTotal; i++) {
    t = (i * paso).round();
    final enMovimiento = t <= msMovimiento;
    final x = .3 + velocidad * (enMovimiento ? t : msMovimiento) / 1000;
    entrada.add(_mano(t, x));
    if (corte != null) break;
  }
  detector.detener();
  entrada.close();
  return (inicio: inicio, corteMs: corte);
}

void main() {
  test('el corte tras quedarse quieto dura lo mismo a 15, 24 y 30 FPS', () {
    // Nivel por dispositivo (DeviceTier.kt): la camara entrega 15/24/30 FPS.
    for (final fps in [15, 24, 30]) {
      final r = _simular(fps);
      expect(r.inicio, isTrue, reason: '$fps FPS');
      expect(r.corteMs, isNotNull, reason: '$fps FPS');
      // 10 frames de referencia a 30 FPS = 333 ms, con un frame de holgura.
      expect((r.corteMs! - 333).abs(), lessThanOrEqualTo(1000 ~/ fps),
          reason: '$fps FPS cortó a ${r.corteMs} ms');
    }
  });

  test('el umbral de movimiento no depende de los FPS', () {
    // El detector promedia |dx| y |dy|: 0.6 unidades/s en x da 0.01 por
    // frame a 30 FPS (deriva, no arranca) pero 0.02 a 15 FPS si se mide
    // por frame. Por tiempo no debe arrancar en ninguno.
    for (final fps in [15, 24, 30]) {
      expect(_simular(fps, velocidad: .6).inicio, isFalse, reason: '$fps FPS');
    }
    // 1.8 unidades/s es una seña: arranca en todos.
    for (final fps in [15, 24, 30]) {
      expect(_simular(fps, velocidad: 1.8).inicio, isTrue, reason: '$fps FPS');
    }
  });

  test('el visor puede alimentar el detector con su movimiento adaptativo', () {
    // Traducir usa el quieto/movimiento del visor web (mismo codigo que el
    // laboratorio). La maquina de estados y el corte por tiempo son los mismos.
    for (final fps in [15, 24, 30]) {
      final d = DetectorAutomatico(framesQuietosParaCortar: 10);
      var inicio = false;
      int? corte;
      var ultimoT = 0;
      d.onInicioDetectado = () => inicio = true;
      d.onFinDetectado = () => corte ??= ultimoT - 600;
      final paso = 1000 / fps;
      for (var i = 0; i * paso <= 2000; i++) {
        ultimoT = (i * paso).round();
        d.alimentarMovimiento(hayMovimiento: ultimoT <= 600, timestampMs: ultimoT);
      }
      expect(inicio, isTrue, reason: '$fps FPS');
      expect((corte! - 333).abs(), lessThanOrEqualTo(1000 ~/ fps),
          reason: '$fps FPS cortó a $corte ms');
      expect(d.estado, EstadoAuto.reconociendo);
    }
  });

  test('sin movimiento del visor no arranca y en pausa ignora eventos', () {
    final d = DetectorAutomatico();
    var inicios = 0;
    d.onInicioDetectado = () => inicios++;
    for (var t = 0; t < 1000; t += 33) {
      d.alimentarMovimiento(hayMovimiento: false, timestampMs: t);
    }
    expect(inicios, 0);
    d.entrarPausa(const Duration(hours: 1), () {});
    d.alimentarMovimiento(hayMovimiento: true, timestampMs: 1100);
    expect(inicios, 0);
    expect(d.estado, EstadoAuto.pausa);
  });

  test('timestamps repetidos no inflan el movimiento', () {
    final entrada = StreamController<LandmarkFrame>(sync: true);
    final detector = DetectorAutomatico();
    var inicio = false;
    detector.onInicioDetectado = () => inicio = true;
    detector.iniciar(entrada.stream);
    // Mismo instante, deriva minima: no es movimiento.
    for (var i = 0; i < 20; i++) {
      entrada.add(_mano(100, .3 + i * .005));
    }
    expect(inicio, isFalse);
    detector.detener();
    entrada.close();
  });

  test('recuerda el ultimo instante con movimiento para recortar la cola', () {
    final d = DetectorAutomatico(framesQuietosParaCortar: 10);
    var fin = false;
    d.onFinDetectado = () => fin = true;
    for (var t = 0; t <= 300; t += 33) {
      d.alimentarMovimiento(hayMovimiento: true, timestampMs: t);
    }
    for (var t = 330; !fin && t < 2000; t += 33) {
      d.alimentarMovimiento(hayMovimiento: false, timestampMs: t);
    }
    expect(fin, isTrue);
    expect(d.ultimoMovimientoMs, 297);
  });

  test('frames del preview que alternan manos y solo pose siguen contando', () {
    // El preview sale cuando termina cualquiera de los dos modelos: uno trae
    // las manos y el siguiente solo la pose. Una seña así debe arrancar y
    // cortarse igual.
    final entrada = StreamController<LandmarkFrame>(sync: true);
    final detector = DetectorAutomatico(framesQuietosParaCortar: 10);
    var inicio = false;
    var fin = false;
    detector.onInicioDetectado = () => inicio = true;
    detector.onFinDetectado = () => fin = true;
    detector.iniciar(entrada.stream);
    for (var i = 0; i < 120 && !fin; i++) {
      final t = i * 17;
      if (i.isEven) {
        final x = .3 + 1.8 * (t <= 600 ? t : 600) / 1000;
        entrada.add(_mano(t, x));
      } else {
        entrada.add(LandmarkFrame.fromMap({'t': t}));
      }
    }
    expect(inicio, isTrue);
    expect(fin, isTrue);
    detector.detener();
    entrada.close();
  });

  group('MovimientoTipoVisor (el quieto/movimiento del visor, sin avatar)', () {
    List<double> frame({double muneca = 0, double dedo = 0, bool mano = true}) {
      final v = List<double>.filled(152, 0);
      v[30] = mano ? 1 : 0;
      v[24] = muneca;
      v[40] = dedo;
      return v;
    }

    test('quieto no es movimiento; muñeca o dedos que se mueven sí', () {
      final m = MovimientoTipoVisor();
      expect(m.alFrame(frame(), 0), isFalse); // primero: referencia
      expect(m.alFrame(frame(muneca: .001), 40), isFalse);
      expect(m.alFrame(frame(muneca: .1), 80), isTrue);
      expect(m.alFrame(frame(muneca: .1, dedo: .2), 120), isTrue);
      expect(m.alFrame(frame(muneca: .1, dedo: .2), 160), isFalse);
    });

    test('sin mano no cuenta, aunque se mueva el cuerpo', () {
      final m = MovimientoTipoVisor();
      m.alFrame(frame(mano: false), 0);
      final v = frame(mano: false)..[0] = .5;
      expect(m.alFrame(v, 40), isFalse);
    });

    test('una mano que aparece y desaparece no es movimiento', () {
      final m = MovimientoTipoVisor();
      List<double> dos({required bool otra}) {
        final v = frame(muneca: .3, dedo: .2);
        if (otra) {
          v[31] = 1;
          v[27] = -.4;
          v[100] = .5;
        }
        return v;
      }

      var t = 0;
      m.alFrame(dos(otra: false), t);
      for (var i = 0; i < 12; i++) {
        t += 34;
        expect(m.alFrame(dos(otra: i.isEven), t), isFalse, reason: 'frame $i');
      }
    });

    test('frames más espaciados se miden por 33 ms', () {
      final m = MovimientoTipoVisor();
      m.alFrame(frame(), 0);
      // .1 en 100 ms equivale a .033 por frame: por debajo de .06.
      expect(m.alFrame(frame(muneca: .1), 100), isFalse);
    });

    test('respeta el ritmo del visor (33 ms)', () {
      final m = MovimientoTipoVisor();
      m.alFrame(frame(), 0);
      expect(m.alFrame(frame(muneca: .1), 10), isNull);
      expect(m.alFrame(frame(muneca: .1), 40), isTrue);
    });
  });
}
