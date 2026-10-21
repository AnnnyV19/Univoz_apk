import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:senas_core/camera_bridge.dart';
import 'package:senas_core/controlador_captura.dart';
import 'package:senas_core/muestras_locales.dart';
import 'package:senas_core/pantalla_ajustes.dart';
import 'package:senas_core/sesion_automatica.dart';
import 'package:senas_core/skeleton_painter.dart';

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

class _RutasFalsas extends PathProviderPlatform {
  final String ruta;
  _RutasFalsas(this.ruta);
  @override
  Future<String?> getApplicationDocumentsPath() async => ruta;
}

/// Camara cuyo iniciar espera a que el test lo libere.
class _CamaraLenta extends _CamaraFalsa {
  final liberar = Completer<void>();
  @override
  Future<CamaraIniciada> iniciar({bool frontal = true}) async {
    await liberar.future;
    return const CamaraIniciada(1, false);
  }
}

LandmarkFrame _frame(int t) {
  final data = jsonDecode(File('test/golden/golden_cases.json').readAsStringSync())
      as Map<String, dynamic>;
  final f = ((data['cases'] as List).first as Map)['frames'][0] as Map;
  return LandmarkFrame.fromMap({
    't': t,
    'pose': f['pose'],
    'poseMundo': f['pose_mundo'],
    'left': f['left'],
    'right': f['right'],
  });
}

/// El almacen escribe en disco de verdad: dentro de testWidgets hay que
/// dejar correr el reloj real un instante antes de repintar. Cada paso de
/// E/S real (abrir, escribir, cerrar, renombrar el .tmp de la escritura
/// atomica) necesita su propia vuelta del bucle, por eso varias vueltas.
Future<void> _asentar(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)));
  }
  await tester.pump();
}

/// Toca y deja terminar la escritura real a disco antes de repintar.
Future<void> _tocarYGuardar(WidgetTester tester, Finder f) async {
  await tester.runAsync(() async {
    await tester.tap(f);
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('pistaParaResultado', () {
    test('cada motivo tiene su texto', () {
      expect(pistaParaResultado('muy_corta'),
          'Seña muy corta. Repítela un poco más lenta.');
      expect(pistaParaResultado('vacia'),
          'No vi tus manos. Ponte frente a la cámara.');
      expect(pistaParaResultado('sin_diccionario'),
          'Aún no hay señas cargadas.');
    });
    test('motivo desconocido no inventa pista', () {
      expect(pistaParaResultado('otro'), isNull);
    });
  });

  group('errores del stream nativo', () {
    test('un error fusionado deja un estado recuperable y no cuenta frames',
        () async {
      final camara = _CamaraFalsa();
      final ctrl = ControladorCaptura(camara: camara);
      await ctrl.iniciar();
      camara.fusion.add(_frame(0));
      ctrl.empezar();
      camara.fusion.add(_frame(33));
      camara.fusion.addError(
          PlatformException(code: 'camera_unavailable', message: 'boom'));
      camara.fusion.add(_frame(66));
      expect(ctrl.error, contains('no está disponible'));
      expect(ctrl.estado, EstadoCamara.error);
      expect(ctrl.framesGrabados, 2, reason: 'el error no es un frame');
      expect(ctrl.framesInvalidos, 0);
      expect(camara.detenciones, greaterThan(0));
      // Reintentar vuelve a arrancar y limpia el error.
      await ctrl.iniciar();
      expect(ctrl.error, isNull);
      expect(ctrl.lista, isTrue);
      ctrl.dispose();
    });

    test('el mismo error en preview y fusion se registra una vez', () async {
      final camara = _CamaraFalsa();
      final ctrl = ControladorCaptura(camara: camara);
      await ctrl.iniciar();
      var avisos = 0;
      ctrl.addListener(() => avisos++);
      final e = PlatformException(code: 'camera_busy', message: 'x');
      camara.preview.addError(e);
      camara.fusion.addError(e);
      expect(avisos, 1);
      ctrl.dispose();
    });
  });

  group('clasificacion de errores del stream', () {
    GravedadError g(String code, [String? msg]) =>
        clasificarErrorStream(PlatformException(code: code, message: msg));

    test('cada codigo que emite Kotlin tiene su gravedad', () {
      // LandmarkEngine.onError -> "mediapipe" (holistic/manos/pose por frame)
      expect(g('mediapipe', 'pose: x'), GravedadError.transitorio);
      expect(g('mediapipe', 'holistic: x'), GravedadError.transitorio);
      expect(g('mediapipe', 'manos: x'), GravedadError.transitorio);
      // LandmarkPlugin: "analisis" por frame y tier_rebind_failed (la camara
      // sigue con la resolucion anterior).
      expect(g('analisis', 'tier_rebind_failed'), GravedadError.transitorio);
      expect(g('analisis', 'boom'), GravedadError.transitorio);
      expect(g('analisis'), GravedadError.transitorio);
      // Apertura/enlace de camara, permiso y cualquier cosa desconocida.
      for (final c in [
        'camera_permission',
        'camera_busy',
        'camera_unavailable',
        'camera_start_failed',
        'camera_start_cancelled',
        'otro_codigo',
      ]) {
        expect(g(c), GravedadError.fatal, reason: c);
      }
      expect(clasificarErrorStream(StateError('x')), GravedadError.fatal);
    });

    test('escala solo si los errores persisten sin ningun frame valido', () {
      final v = VigilanteErrores(ventanaMs: 3000);
      expect(v.registrarTransitorio(0), isFalse);
      expect(v.registrarTransitorio(1000), isFalse);
      expect(v.registrarTransitorio(2999), isFalse);
      expect(v.registrarTransitorio(3000), isTrue);
    });

    test('un frame valido reinicia la cuenta', () {
      final v = VigilanteErrores(ventanaMs: 3000);
      expect(v.registrarTransitorio(0), isFalse);
      v.frameValido();
      expect(v.registrarTransitorio(2900), isFalse);
      expect(v.registrarTransitorio(5000), isFalse);
      expect(v.registrarTransitorio(5900), isTrue);
    });

    test('errores aislados entre frames sanos nunca escalan', () {
      final v = VigilanteErrores(ventanaMs: 3000);
      for (var t = 0; t < 20000; t += 100) {
        v.frameValido();
        expect(v.registrarTransitorio(t), isFalse);
      }
    });

    test('un error transitorio no detiene la camara ni muestra error',
        () async {
      var ahora = 0;
      final camara = _CamaraFalsa();
      final ctrl = ControladorCaptura(camara: camara, ahora: () => ahora);
      await ctrl.iniciar();
      camara.preview.add(_frame(0));
      camara.fusion.addError(PlatformException(
          code: 'analisis', message: 'tier_rebind_failed'));
      camara.preview.addError(PlatformException(
          code: 'mediapipe', message: 'pose: x'));
      expect(ctrl.error, isNull);
      expect(ctrl.estado, EstadoCamara.lista);
      expect(camara.detenciones, 0);
      ctrl.dispose();
    });

    test('si persisten 3 s sin frames escala al error bloqueante', () async {
      var ahora = 0;
      final camara = _CamaraFalsa();
      final ctrl = ControladorCaptura(camara: camara, ahora: () => ahora);
      await ctrl.iniciar();
      camara.preview.add(_frame(0));
      final e = PlatformException(code: 'mediapipe', message: 'pose: x');
      camara.preview.addError(e);
      ahora = 1500;
      camara.preview.addError(e);
      expect(ctrl.error, isNull);
      ahora = 3100;
      camara.preview.addError(e);
      expect(ctrl.error, 'Hubo un problema con la cámara.');
      expect(ctrl.estado, EstadoCamara.error);
      expect(camara.detenciones, greaterThan(0));
      ctrl.dispose();
    });

    test('un error durante camara.iniciar no se pisa con enlazada', () async {
      final camara = _CamaraLenta();
      final ctrl = ControladorCaptura(camara: camara);
      final inicio = ctrl.iniciar();
      await Future<void>.delayed(Duration.zero);
      camara.preview.addError(
          PlatformException(code: 'camera_busy', message: 'x'));
      camara.liberar.complete();
      await inicio;
      expect(ctrl.estado, EstadoCamara.error);
      expect(ctrl.lista, isFalse);
      expect(ctrl.error, contains('otra aplicación'));
      ctrl.dispose();
    });
  });

  group('PistaTemporal', () {
    testWidgets('aparece, se borra sola a los 2.5 s y avisa', (tester) async {
      var cambios = 0;
      final pista = PistaTemporal(alCambiar: () => cambios++);
      pista.mostrar('muy_corta');
      expect(pista.texto, 'Seña muy corta. Repítela un poco más lenta.');
      await tester.pump(const Duration(milliseconds: 2400));
      expect(pista.texto, isNotNull);
      await tester.pump(const Duration(milliseconds: 200));
      expect(pista.texto, isNull);
      expect(cambios, 2);
      pista.dispose();
    });

    testWidgets('una pista nueva reinicia el plazo y limpiar la cancela',
        (tester) async {
      final pista = PistaTemporal(alCambiar: () {});
      pista.mostrar('vacia');
      await tester.pump(const Duration(milliseconds: 2000));
      pista.mostrar('sin_diccionario');
      await tester.pump(const Duration(milliseconds: 2000));
      expect(pista.texto, 'Aún no hay señas cargadas.');
      pista.limpiar();
      expect(pista.texto, isNull);
      pista.mostrar('vacia');
      pista.dispose();
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('consentimiento de sesion', () {
    late Directory tmp;
    final almacen = AlmacenMuestras.instancia;

    // Un solo directorio para todo el grupo: el almacen es un singleton que
    // recuerda la ruta de su archivo.
    setUpAll(() {
      tmp = Directory.systemTemp.createTempSync('univoz_consent');
      PathProviderPlatform.instance = _RutasFalsas(tmp.path);
    });
    tearDownAll(() => tmp.deleteSync(recursive: true));
    setUp(() => almacen.ajustes = Ajustes());

    Widget app(Future<void> Function(BuildContext) alPulsar) => MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => alPulsar(context),
              child: const Text('pedir'),
            ),
          ),
        );

    testWidgets('responder No se recuerda y no se vuelve a preguntar',
        (tester) async {
      var resultados = <bool>[];
      await tester.pumpWidget(app((c) async =>
          resultados.add(await asegurarConsentimiento(c, almacen))));
      await tester.tap(find.text('pedir'));
      await _asentar(tester);
      expect(find.text('Medir y registrar la sesión'), findsOneWidget);
      await tester.tap(find.text('No'));
      await _asentar(tester);
      expect(resultados, [false]);
      expect(almacen.ajustes.consentimientoSesion, isFalse);
      expect(almacen.ajustes.consentimientoPreguntado, isTrue);

      await tester.tap(find.text('pedir'));
      await _asentar(tester);
      expect(find.text('Medir y registrar la sesión'), findsNothing);
      expect(resultados, [false, false]);
    });

    testWidgets('cerrar el dialogo sin responder no se recuerda y vuelve a preguntar',
        (tester) async {
      final resultados = <bool>[];
      await tester.pumpWidget(app((c) async =>
          resultados.add(await asegurarConsentimiento(c, almacen))));
      await tester.tap(find.text('pedir'));
      await _asentar(tester);
      await tester.tapAt(const Offset(2, 2)); // fuera del dialogo
      await _asentar(tester);
      expect(resultados, [false]);
      expect(almacen.ajustes.consentimientoPreguntado, isFalse);
      await tester.tap(find.text('pedir'));
      await _asentar(tester);
      expect(find.text('Medir y registrar la sesión'), findsOneWidget);
    });

    testWidgets('responder Acepto persiste y no vuelve a preguntar',
        (tester) async {
      var resultados = <bool>[];
      await tester.pumpWidget(app((c) async =>
          resultados.add(await asegurarConsentimiento(c, almacen))));
      await tester.tap(find.text('pedir'));
      await _asentar(tester);
      await tester.tap(find.text('Acepto'));
      await _asentar(tester);
      expect(resultados, [true]);
      await tester.tap(find.text('pedir'));
      await _asentar(tester);
      expect(find.text('Medir y registrar la sesión'), findsNothing);
      expect(resultados, [true, true]);
    });

    test('el No sobrevive a guardar y recargar los ajustes', () {
      final a = Ajustes(consentimientoPreguntado: true);
      final b = Ajustes.fromJson(
          (jsonDecode(jsonEncode(a.toJson())) as Map).cast<String, dynamic>());
      expect(b.consentimientoPreguntado, isTrue);
      expect(b.consentimientoSesion, isFalse);
      expect(b.copiar().consentimientoPreguntado, isTrue);
    });

    test('un archivo viejo con Si cuenta como ya preguntado', () {
      final b = Ajustes.fromJson({'consentimiento_sesion': true});
      expect(b.consentimientoPreguntado, isTrue);
      expect(Ajustes.fromJson(const {}).consentimientoPreguntado, isFalse);
    });

    testWidgets('el interruptor de Ajustes cambia y guarda el consentimiento',
        (tester) async {
      await tester.runAsync(almacen.cargar);
      almacen.ajustes = Ajustes(consentimientoPreguntado: true);
      await tester.pumpWidget(const MaterialApp(home: PantallaAjustes()));
      await _asentar(tester);
      final interruptor = find.widgetWithText(SwitchListTile,
          'Guardar sesiones para mejorar el reconocimiento');
      await tester.scrollUntilVisible(interruptor, 200,
          scrollable: find.byType(Scrollable).first);
      expect(tester.widget<SwitchListTile>(interruptor).value, isFalse);
      await tester.ensureVisible(interruptor);
      await tester.pump();
      await _tocarYGuardar(tester, interruptor);
      expect(tester.widget<SwitchListTile>(interruptor).value, isTrue);
      expect(almacen.ajustes.consentimientoSesion, isTrue);
      expect(almacen.ajustes.consentimientoPreguntado, isTrue);
      await _tocarYGuardar(tester, interruptor);
      expect(almacen.ajustes.consentimientoSesion, isFalse);
      expect(almacen.ajustes.consentimientoPreguntado, isTrue);
    });
  });

  test('plataforma de la sesion no esta fija en android', () {
    expect(nombrePlataformaSesion(), isNot(isEmpty));
    expect(File('lib/sesion_automatica.dart').readAsStringSync(),
        isNot(contains("'platform': 'android'")));
  });
}
