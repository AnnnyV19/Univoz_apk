import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:senas_core/camera_bridge.dart';
import 'package:senas_core/controlador_captura.dart';

LandmarkFrame _mano(int t, double x) => LandmarkFrame.fromMap({
      't': t,
      'left': List.generate(21, (i) => [x + i * .001, .5, 0.0]),
    });

void main() {
  late StreamController<LandmarkFrame> preview;
  late DetectorAutomatico detector;
  late FuenteMovimientoAuto fuente;
  late int inicios;

  setUp(() {
    preview = StreamController<LandmarkFrame>.broadcast(sync: true);
    detector = DetectorAutomatico(framesQuietosParaCortar: 10);
    fuente = FuenteMovimientoAuto(detector);
    inicios = 0;
    detector.onInicioDetectado = () => inicios++;
  });

  tearDown(() async {
    await fuente.detener();
    await preview.close();
  });

  /// Frames de preview con la mano en movimiento claro.
  void moverPreview() {
    for (var i = 0; i < 6; i++) {
      preview.add(_mano(i * 33, .2 + i * .06));
    }
  }

  void moverVisor() {
    for (var i = 0; i < 6; i++) {
      fuente.alMovimientoVisor(hayMovimiento: true, timestampMs: i * 33);
    }
  }

  test('visor no listo: los frames de preview alimentan al detector', () async {
    await fuente.iniciar(preview.stream, visorListo: false);
    expect(fuente.usaVisor, isFalse);
    // El motion del visor (si llegara tarde) no cuenta.
    moverVisor();
    expect(inicios, 0);
    moverPreview();
    expect(inicios, 1);
    expect(detector.estado, EstadoAuto.grabando);
  });

  test('visor listo: solo cuenta su motion, los frames no se escuchan',
      () async {
    await fuente.iniciar(preview.stream, visorListo: true);
    expect(fuente.usaVisor, isTrue);
    expect(preview.hasListener, isFalse);
    moverPreview();
    expect(inicios, 0);
    moverVisor();
    expect(inicios, 1);
  });

  test('cambia a la fuente del visor al quedar listo, sin doble conteo',
      () async {
    await fuente.iniciar(preview.stream, visorListo: false);
    expect(preview.hasListener, isTrue);
    await fuente.visorCambio(listo: true);
    expect(preview.hasListener, isFalse);
    expect(fuente.usaVisor, isTrue);
    moverPreview();
    expect(inicios, 0);
    moverVisor();
    expect(inicios, 1);
  });

  test('si el avatar falla vuelve a los frames de preview', () async {
    await fuente.iniciar(preview.stream, visorListo: true);
    await fuente.visorCambio(listo: false);
    expect(preview.hasListener, isTrue);
    moverVisor();
    expect(inicios, 0);
    moverPreview();
    expect(inicios, 1);
  });

  test('el mismo estado no reinicia el detector', () async {
    await fuente.iniciar(preview.stream, visorListo: false);
    moverPreview();
    expect(detector.estado, EstadoAuto.grabando);
    await fuente.visorCambio(listo: false);
    expect(detector.estado, EstadoAuto.grabando);
  });

  test('preview sin mano cuenta como quieto solo con el visor como fuente',
      () async {
    await fuente.iniciar(preview.stream, visorListo: true);
    moverVisor();
    expect(detector.estado, EstadoAuto.grabando);
    var cortes = 0;
    detector.onFinDetectado = () => cortes++;
    // Persona fuera de cuadro: sin mano ni pose, 400 ms.
    for (var i = 6; i < 20; i++) {
      fuente.alPreviewSinMano(LandmarkFrame.fromMap({'t': i * 33}));
    }
    expect(cortes, 1);
  });

  test('detenida no acepta movimiento', () async {
    await fuente.iniciar(preview.stream, visorListo: true);
    await fuente.detener();
    moverVisor();
    expect(inicios, 0);
    expect(fuente.activa, isFalse);
  });
}
