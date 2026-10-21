import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';

import 'package:senas_core/camera_bridge.dart';
import 'package:senas_core/controlador_captura.dart';

/// Camara sin canal nativo: los frames los empuja el test.
class _CamaraFalsa extends CameraBridge {
  final fusion = StreamController<LandmarkFrame>.broadcast(sync: true);
  final preview = StreamController<LandmarkFrame>.broadcast(sync: true);
  int detenciones = 0;
  @override
  Stream<LandmarkFrame> get frames => fusion.stream;
  @override
  Stream<LandmarkFrame> get framesPreview => preview.stream;
  @override
  Future<CamaraIniciada> iniciar({bool frontal = true}) async =>
      const CamaraIniciada(1, false);
  @override
  Future<void> detener() async => detenciones++;
}

LandmarkFrame _f(int t) => LandmarkFrame.fromMap({'t': t});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VigilanteEstancamiento', () {
    test('avisa a los 4 s sin frames y no antes', () {
      fakeAsync((async) {
        var avisos = 0;
        final v = VigilanteEstancamiento(alEstancarse: () => avisos++);
        v.iniciar();
        async.elapse(const Duration(milliseconds: 3900));
        expect(avisos, 0);
        async.elapse(const Duration(milliseconds: 400));
        expect(avisos, 1);
        expect(v.activo, isFalse, reason: 'avisa una sola vez');
        async.elapse(const Duration(seconds: 10));
        expect(avisos, 1);
      });
    });

    test('cada frame reinicia la cuenta', () {
      fakeAsync((async) {
        var avisos = 0;
        final v = VigilanteEstancamiento(alEstancarse: () => avisos++);
        v.iniciar();
        for (var i = 0; i < 20; i++) {
          async.elapse(const Duration(seconds: 3));
          v.frame();
        }
        expect(avisos, 0);
        async.elapse(const Duration(milliseconds: 4300));
        expect(avisos, 1);
      });
    });

    test('detener lo cancela', () {
      fakeAsync((async) {
        var avisos = 0;
        final v = VigilanteEstancamiento(alEstancarse: () => avisos++);
        v.iniciar();
        async.elapse(const Duration(seconds: 2));
        v.detener();
        async.elapse(const Duration(seconds: 10));
        expect(avisos, 0);
      });
    });

    test('con la app en segundo plano no cuenta', () {
      fakeAsync((async) {
        var avisos = 0;
        var primerPlano = false;
        final v = VigilanteEstancamiento(
            alEstancarse: () => avisos++, enPrimerPlano: () => primerPlano);
        v.iniciar();
        async.elapse(const Duration(seconds: 30));
        expect(avisos, 0);
        // Al volver, la cuenta arranca de cero.
        primerPlano = true;
        async.elapse(const Duration(milliseconds: 3900));
        expect(avisos, 0);
        async.elapse(const Duration(milliseconds: 400));
        expect(avisos, 1);
      });
    });
  });

  // Con testWidgets: tester.pump avanza el reloj falso. Cancelar una
  // suscripcion devuelve un Future de la zona raiz que el reloj falso no
  // completa: apagar/reiniciar se lanzan sin await y [asentar] deja correr
  // el bucle real un instante (los timers siguen en la zona falsa).
  group('ControladorCaptura sin frames a mitad de la sesion', () {
    Future<void> esperar(WidgetTester tester, int ms) =>
        tester.pump(Duration(milliseconds: ms));
    Future<void> asentar(WidgetTester tester) async {
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
      }
    }

    testWidgets('a los 4 s sin frames queda el error bloqueante',
        (tester) async {
      final camara = _CamaraFalsa();
      final ctrl =
          ControladorCaptura(camara: camara, enPrimerPlano: () => true);
      await ctrl.iniciar();
      camara.preview.add(_f(0));
      expect(ctrl.estado, EstadoCamara.lista);
      // Frames sanos durante 10 s: preview y fusionados la mantienen viva.
      for (var t = 1; t <= 10; t++) {
        await esperar(tester, 1000);
        if (t.isEven) {
          camara.preview.add(_f(t * 1000));
        } else {
          camara.fusion.add(_f(t * 1000));
        }
      }
      expect(ctrl.error, isNull);
      await esperar(tester, 3900);
      expect(ctrl.error, isNull);
      await esperar(tester, 400);
      expect(ctrl.error, 'La cámara dejó de responder.');
      expect(ctrl.estado, EstadoCamara.error);
      expect(ctrl.lista, isFalse);
      expect(camara.detenciones, greaterThan(0));
      ctrl.dispose();
      await esperar(tester, 0);
    });

    testWidgets('antes del primer frame manda el vigilante de 5 s, no este',
        (tester) async {
      final camara = _CamaraFalsa();
      final ctrl =
          ControladorCaptura(camara: camara, enPrimerPlano: () => true);
      await ctrl.iniciar();
      await esperar(tester, 4500);
      expect(ctrl.error, isNull);
      await esperar(tester, 600);
      expect(ctrl.error, contains('no envió imagen'));
      ctrl.dispose();
      await esperar(tester, 0);
    });

    testWidgets('apagar (salir de la pantalla) cancela el vigilante',
        (tester) async {
      final camara = _CamaraFalsa();
      final ctrl =
          ControladorCaptura(camara: camara, enPrimerPlano: () => true);
      await ctrl.iniciar();
      camara.preview.add(_f(0));
      unawaited(ctrl.apagar());
      await asentar(tester);
      await esperar(tester, 10000);
      expect(ctrl.error, isNull);
      expect(ctrl.estado, EstadoCamara.detenida);
    });

    testWidgets('en segundo plano no marca error; al volver vuelve a vigilar',
        (tester) async {
      var primerPlano = true;
      final camara = _CamaraFalsa();
      final ctrl = ControladorCaptura(
          camara: camara, enPrimerPlano: () => primerPlano);
      await ctrl.iniciar();
      camara.preview.add(_f(0));
      primerPlano = false;
      await esperar(tester, 60000);
      expect(ctrl.error, isNull);
      primerPlano = true;
      camara.preview.add(_f(61000));
      await esperar(tester, 4300);
      expect(ctrl.error, 'La cámara dejó de responder.');
      ctrl.dispose();
      await esperar(tester, 0);
    });

    testWidgets('un error transitorio del nativo (tier_rebind_failed) cuenta '
        'como senal de vida', (tester) async {
      var ahora = 0;
      final camara = _CamaraFalsa();
      final ctrl = ControladorCaptura(
          camara: camara, ahora: () => ahora, enPrimerPlano: () => true);
      await ctrl.iniciar();
      camara.preview.add(_f(0));
      await esperar(tester, 3500);
      ahora = 3500;
      camara.fusion.addError(PlatformException(
          code: 'analisis', message: 'tier_rebind_failed'));
      await esperar(tester, 1000);
      expect(ctrl.error, isNull, reason: 'el nativo sigue vivo');
      camara.preview.add(_f(4500));
      await esperar(tester, 4300);
      expect(ctrl.error, 'La cámara dejó de responder.');
      ctrl.dispose();
      await esperar(tester, 0);
    });

    testWidgets('dispose detiene el vigilante sin esperar a cerrar la sesion',
        (tester) async {
      final camara = _CamaraFalsa();
      final ctrl =
          ControladorCaptura(camara: camara, enPrimerPlano: () => true);
      await ctrl.iniciar();
      camara.preview.add(_f(0));
      ctrl.dispose();
      // Sin asentar: el reloj falso avanza sin que corra ningun await de
      // apagar(); un tic del vigilante aqui usaria el notifier liberado.
      await esperar(tester, 10000);
      expect(ctrl.error, isNull);
    });

    testWidgets('Reintentar (iniciar de nuevo) limpia el error y vuelve a vigilar',
        (tester) async {
      final camara = _CamaraFalsa();
      final ctrl =
          ControladorCaptura(camara: camara, enPrimerPlano: () => true);
      await ctrl.iniciar();
      camara.preview.add(_f(0));
      await esperar(tester, 4300);
      expect(ctrl.estado, EstadoCamara.error);
      unawaited(ctrl.iniciar());
      await asentar(tester);
      expect(ctrl.error, isNull);
      camara.preview.add(_f(5000));
      expect(ctrl.estado, EstadoCamara.lista);
      await esperar(tester, 2000);
      expect(ctrl.error, isNull);
      await esperar(tester, 2300);
      expect(ctrl.error, 'La cámara dejó de responder.');
      ctrl.dispose();
      await esperar(tester, 0);
    });
  });

  test('el texto del estancamiento es amable y sin detalles', () {
    expect(mensajeErrorCamara(StateError(kCamaraSinRespuesta)),
        'La cámara dejó de responder.');
  });
}
