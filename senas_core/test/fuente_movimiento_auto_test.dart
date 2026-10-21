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

  group('cambio de fuente en mitad de una sena', () {
    test('el visor listo a media sena espera a que vuelva a quieto',
        () async {
      final estados = <EstadoAuto>[];
      detector.onCambioEstado = estados.add;
      await fuente.iniciar(preview.stream, visorListo: false);
      moverPreview();
      expect(detector.estado, EstadoAuto.grabando);

      await fuente.visorCambio(listo: true);
      // Sigue la fuente de la sena en curso: sin reinicio silencioso.
      expect(detector.estado, EstadoAuto.grabando);
      expect(estados, [EstadoAuto.grabando]);
      expect(fuente.usaVisor, isFalse);
      expect(fuente.cambioDiferido, isTrue);
      expect(preview.hasListener, isTrue);
      // Y el motion del visor no se cuela en la sena en curso.
      moverVisor();
      expect(detector.estado, EstadoAuto.grabando);

      // La sena termina por sus frames: quieto de preview.
      var cortes = 0;
      detector.onFinDetectado = () => cortes++;
      for (var i = 6; i < 20; i++) {
        preview.add(_mano(i * 33, .2 + 5 * .06));
      }
      expect(cortes, 1);
      expect(detector.estado, EstadoAuto.reconociendo);
      // Reconociendo tampoco cambia la fuente.
      expect(fuente.usaVisor, isFalse);

      detector.entrarPausa(const Duration(milliseconds: 10), () {});
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(detector.estado, EstadoAuto.quieto);
      expect(fuente.usaVisor, isTrue);
      expect(fuente.cambioDiferido, isFalse);
      expect(preview.hasListener, isFalse);
      // Ahora si cuenta el visor.
      moverVisor();
      expect(inicios, 2);
    });

    test('si el avatar falla a media sena tambien espera', () async {
      await fuente.iniciar(preview.stream, visorListo: true);
      moverVisor();
      expect(detector.estado, EstadoAuto.grabando);
      await fuente.visorCambio(listo: false);
      expect(detector.estado, EstadoAuto.grabando);
      expect(fuente.usaVisor, isTrue);
      expect(preview.hasListener, isFalse);
      var cortes = 0;
      detector.onFinDetectado = () => cortes++;
      for (var i = 6; i < 20; i++) {
        fuente.alMovimientoVisor(hayMovimiento: false, timestampMs: i * 33);
      }
      expect(cortes, 1);
      detector.entrarPausa(const Duration(milliseconds: 10), () {});
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(fuente.usaVisor, isFalse);
      expect(preview.hasListener, isTrue);
    });

    test('un cambio y su contrario durante la sena no reinician nada',
        () async {
      await fuente.iniciar(preview.stream, visorListo: false);
      moverPreview();
      await fuente.visorCambio(listo: true);
      await fuente.visorCambio(listo: false);
      expect(fuente.cambioDiferido, isFalse);
      expect(detector.estado, EstadoAuto.grabando);
      expect(preview.hasListener, isTrue);
    });

    test('detener() descarta el cambio pendiente', () async {
      await fuente.iniciar(preview.stream, visorListo: false);
      moverPreview();
      await fuente.visorCambio(listo: true);
      await fuente.detener();
      expect(fuente.cambioDiferido, isFalse);
      expect(detector.alVolverAQuieto, isNull);
    });
  });
}
