import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show ByteData;
import 'package:flutter_test/flutter_test.dart';
import 'package:senas_core/avatar_bridge.dart';
import 'package:senas_core/avatar_vivo.dart';
import 'package:senas_core/camera_bridge.dart';
import 'package:senas_core/diagnostico_latencia.dart';

LandmarkFrame _frame(int t, {Map<String, Object?> extra = const {}}) {
  final data =
      jsonDecode(File('test/golden/golden_cases.json').readAsStringSync())
          as Map<String, dynamic>;
  final f = ((data['cases'] as List).first as Map)['frames'][0] as Map;
  return LandmarkFrame.fromMap({
    't': t,
    'pose': f['pose'],
    'poseMundo': f['pose_mundo'],
    'left': f['left'],
    'right': f['right'],
    ...extra,
  });
}

void main() {
  tearDown(DiagnosticoLatencia.restablecerParaPruebas);

  group('toggles de desarrollador', () {
    test('por defecto reproducen el comportamiento de siempre', () {
      expect(DiagnosticoLatencia.suavizado.value, SuavizadoAvatar.normal);
      expect(DiagnosticoLatencia.delegado.value, DelegadoMediaPipe.gpu);
      DiagnosticoLatencia.desarrolladorParaPruebas = false;
      expect(DiagnosticoLatencia.activo, isFalse);
    });

    test('valores wire que entienden el visor y Kotlin', () {
      expect(SuavizadoAvatar.values.map((e) => e.wire),
          ['normal', 'off']);
      expect(DelegadoMediaPipe.values.map((e) => e.wire), ['gpu', 'cpu']);
    });

    test('fuera del modo desarrollador lo elegido no se aplica', () {
      DiagnosticoLatencia.suavizado.value = SuavizadoAvatar.apagado;
      DiagnosticoLatencia.delegado.value = DelegadoMediaPipe.cpu;
      DiagnosticoLatencia.desarrolladorParaPruebas = false;
      expect(DiagnosticoLatencia.suavizadoEfectivo, SuavizadoAvatar.normal);
      expect(DiagnosticoLatencia.delegadoEfectivo, DelegadoMediaPipe.gpu);
      DiagnosticoLatencia.desarrolladorParaPruebas = true;
      expect(DiagnosticoLatencia.suavizadoEfectivo, SuavizadoAvatar.apagado);
      expect(DiagnosticoLatencia.delegadoEfectivo, DelegadoMediaPipe.cpu);
    });
  });

  group('VentanaMs', () {
    test('p50, p95 y max; vacia es guion', () {
      final v = VentanaMs();
      expect(v.resumen(), '-');
      for (var i = 1; i <= 100; i++) {
        v.agregar(i.toDouble());
      }
      expect(v.resumen(), '50.0/95.0/100.0');
      v.limpiar();
      expect(v.n, 0);
      expect(v.resumen(), '-');
    });

    test('es un anillo y descarta no finitos', () {
      final v = VentanaMs(4);
      for (var i = 1; i <= 10; i++) {
        v.agregar(i.toDouble());
      }
      v.agregar(double.nan);
      expect(v.n, 4);
      expect(v.resumen(), '8.0/10.0/10.0');
    });
  });

  group('MedidorEnvio', () {
    test('cierra la ventana a 1 s con tasas, cola y cap_send', () {
      final m = MedidorEnvio();
      m.frameLlegado(0);
      expect(m.cerrarSiToca(500000), isNull);
      for (var i = 0; i < 29; i++) {
        m.frameLlegado(i * 1000);
      }
      for (var i = 0; i < 15; i++) {
        m.enviado(esperaMs: 4, viajeMs: 10, capAgeMs: 100);
      }
      m.reemplazado();
      m.sinPose();
      m.fallo();
      final linea = m.cerrarSiToca(1000000)!;
      expect(linea, contains('win=1000ms in=30.0/s sent=15.0/s'));
      expect(linea, contains('replaced=1 nopose=1 err=1'));
      expect(linea, contains('wait=4.0/4.0/4.0'));
      expect(linea, contains('rtt=10.0/10.0/10.0'));
      expect(linea, contains('cap_send=104.0/104.0/104.0'));
      expect(linea, contains('cap_ack=114.0/114.0/114.0'));
      // Publica el p50 de cap_send para el estimado del visor.
      final js = DiagnosticoLatencia.formatearResumenVisor(
          {'window_ms': 1000, 'shown_ms': {'p50': 20.0, 'p95': 30.0, 'max': 40.0}},
          capSendP50: 104.0);
      expect(js, contains('e2e_est_p50=124.0'));
      // La ventana siguiente arranca limpia.
      expect(m.cerrarSiToca(1500000), isNull);
      final vacia = m.cerrarSiToca(2000000)!;
      expect(vacia, contains('in=0.0/s sent=0.0/s replaced=0'));
      expect(vacia, contains('cap_send=-'));
    });

    test('sin cap_age_ms (Kotlin sin diagnostico) no inventa cap_send', () {
      final m = MedidorEnvio();
      m.frameLlegado(0);
      m.enviado(esperaMs: 3, viajeMs: 7);
      final linea = m.cerrarSiToca(1000000)!;
      expect(linea, contains('wait=3.0/3.0/3.0 rtt=7.0/7.0/7.0'));
      expect(linea, contains('cap_send=- cap_ack=-'));
    });
  });

  group('resumen del visor', () {
    test('arma la linea js y la imprime con la etiqueta UnivozLat', () {
      final lineas = <String>[];
      DiagnosticoLatencia.salida = lineas.add;
      DiagnosticoLatencia.alResumenVisor(jsonEncode({
        'frames_in': 15,
        'ticks': 60,
        'superseded': 2,
        'window_ms': 1000,
        'suavizado': 'off',
        'apply_ms': {'n': 15, 'p50': 2.0, 'p95': 4.0, 'max': 8.0},
        'tick_ms': {'n': 60, 'p50': 3.0, 'p95': 5.0, 'max': 9.0},
        'shown_ms': {'n': 15, 'p50': 8.0, 'p95': 17.0, 'max': 30.0},
      }));
      expect(lineas.single,
          'UnivozLat js win=1000ms in=15.0/s render=60.0/s superseded=2 '
          'smooth=off apply=2.0/4.0/8.0 tick=3.0/5.0/9.0 '
          'shown=8.0/17.0/30.0 e2e_est_p50=-');
    });

    test('un mensaje roto no imprime ni lanza', () {
      final lineas = <String>[];
      DiagnosticoLatencia.salida = lineas.add;
      DiagnosticoLatencia.alResumenVisor('no es json');
      DiagnosticoLatencia.alResumenVisor('[1,2]');
      expect(lineas, isEmpty);
    });
  });

  group('LandmarkFrame', () {
    test('cap_age_ms y llegada se leen y sobreviven a conLandmarks', () {
      final f = _frame(1, extra: {'cap_age_ms': 123.5});
      expect(f.capAgeMs, 123.5);
      expect(f.llegadaUs, isNotNull);
      final copia = f.conLandmarks(pose: f.pose, left: f.left, right: f.right);
      expect(copia.capAgeMs, 123.5);
      expect(copia.llegadaUs, f.llegadaUs);
      expect(_frame(2).capAgeMs, isNull);
      // No viaja a las sesiones guardadas.
      expect(f.toJson().containsKey('cap_age_ms'), isFalse);
    });
  });

  group('AlimentadorAvatar con medidor', () {
    test('cuenta reemplazados y mide espera, viaje y cap_send', () async {
      final medidor = MedidorEnvio();
      final alimentador = AlimentadorAvatar(
        medidor: medidor,
        enviar: (v, {renderFrame, timestampMs, quality = 1.0, sourceMeta}) async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
        },
      );
      alimentador.iniciar();
      for (var i = 1; i <= 6; i++) {
        alimentador.alFrame(_frame(i, extra: {'cap_age_ms': 100.0}));
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(medidor.viaje.n, greaterThanOrEqualTo(1));
      // Seis frames llegaron seguidos y el envio solo toma el ultimo.
      final linea = medidor.cerrarSiToca(relojDiagnosticoUs() + 2000000)!;
      expect(linea, contains('replaced='));
      expect(linea, isNot(contains('replaced=0')));
      expect(medidor.espera.n, 0); // cerrarSiToca limpio la ventana
      expect(linea, isNot(contains('cap_send=-')));
      alimentador.detener();
    });

    test('un envio que falla cuenta err y no rompe', () async {
      final medidor = MedidorEnvio();
      final alimentador = AlimentadorAvatar(
        medidor: medidor,
        enviar: (v, {renderFrame, timestampMs, quality = 1.0, sourceMeta}) async {
          throw StateError('webview no listo');
        },
      );
      alimentador.iniciar();
      alimentador.alFrame(_frame(1));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final linea = medidor.cerrarSiToca(relojDiagnosticoUs() + 2000000)!;
      expect(linea, contains('err=1'));
      expect(alimentador.framesEnviados, 0);
      alimentador.detener();
    });

    test('sin modo desarrollador y sin medidor no mide ni imprime', () async {
      final lineas = <String>[];
      DiagnosticoLatencia.salida = lineas.add;
      DiagnosticoLatencia.desarrolladorParaPruebas = false;
      final alimentador = AlimentadorAvatar(
        enviar: (v, {renderFrame, timestampMs, quality = 1.0, sourceMeta}) async {},
      );
      alimentador.iniciar();
      alimentador.alFrame(_frame(1));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(alimentador.framesEnviados, 1);
      expect(lineas, isEmpty);
      alimentador.detener();
    });
  });

  group('AvatarBridge aplica los toggles al visor', () {
    const suaveApagado =
        "window.configurarSuavizado && window.configurarSuavizado('off')";
    const suaveNormal =
        "window.configurarSuavizado && window.configurarSuavizado('normal')";
    const latOn = 'window.configurarLatencia && window.configurarLatencia(true)';

    testWidgets('con el modo apagado no manda nada extra', (tester) async {
      DiagnosticoLatencia.desarrolladorParaPruebas = false;
      final js = <String>[];
      final bridge = AvatarBridge.sinVisor(
        ejecutar: (c) async => js.add(c),
        modelo: () async => ByteData(4),
      );
      bridge.simularMensaje('js_listo');
      await tester.pump();
      DiagnosticoLatencia.suavizado.value = SuavizadoAvatar.apagado;
      await tester.pump();
      expect(js.where((c) => c.contains('configurarSuavizado')), isEmpty);
      expect(js.where((c) => c.contains('configurarLatencia')), isEmpty);
      bridge.dispose();
    });

    testWidgets('tras cargar aplica lo elegido y luego los cambios en vivo',
        (tester) async {
      DiagnosticoLatencia.desarrolladorParaPruebas = true;
      DiagnosticoLatencia.suavizado.value = SuavizadoAvatar.apagado;
      final js = <String>[];
      final bridge = AvatarBridge.sinVisor(
        ejecutar: (c) async => js.add(c),
        modelo: () async => ByteData(4),
      );
      bridge.simularMensaje('js_listo');
      await tester.pump();
      expect(js, contains(suaveApagado));
      expect(js, contains(latOn));
      js.clear();
      DiagnosticoLatencia.suavizado.value = SuavizadoAvatar.normal;
      await tester.pump();
      expect(js, [suaveNormal]);
      js.clear();
      DiagnosticoLatencia.suavizado.value = SuavizadoAvatar.normal;
      await tester.pump();
      expect(js, isEmpty); // sin cambio no repite
      bridge.dispose();
    });

    testWidgets('el mensaje lat: del visor se imprime solo con el modo activo',
        (tester) async {
      final lineas = <String>[];
      DiagnosticoLatencia.salida = lineas.add;
      final bridge = AvatarBridge.sinVisor();
      DiagnosticoLatencia.desarrolladorParaPruebas = false;
      bridge.simularMensaje('lat:{"frames_in":1,"ticks":1,"window_ms":1000}');
      expect(lineas, isEmpty);
      DiagnosticoLatencia.desarrolladorParaPruebas = true;
      bridge.simularMensaje('lat:{"frames_in":1,"ticks":1,"window_ms":1000}');
      expect(lineas.single, startsWith('UnivozLat js win=1000ms'));
      bridge.dispose();
    });
  });
}
