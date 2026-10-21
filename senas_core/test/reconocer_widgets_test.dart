import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:senas_core/camera_bridge.dart';
import 'package:senas_core/dtw.dart';
import 'package:senas_core/plantillas.dart';
import 'package:senas_core/reconocer/encabezado_reconocer.dart';
import 'package:senas_core/reconocer/guia_encuadre.dart';
import 'package:senas_core/reconocer/guia_inicial.dart';
import 'package:senas_core/reconocer/tarjeta_resultado.dart';
import 'package:senas_core/sign_norm.dart' show kFrameDim;
import 'package:senas_core/tema_univoz.dart';

Widget _app(Widget hijo) => MaterialApp(
      theme: temaUnivoz(),
      home: Scaffold(body: SingleChildScrollView(child: hijo)),
    );

final _seq = [List<double>.filled(kFrameDim, 0.0)];

Template _t(String gloss, [String espanol = '']) =>
    Template('id_$gloss', gloss, _seq, espanol: espanol);

final _candidatas = [
  MapEntry(0.20, _t('HOLA', 'Hola')),
  MapEntry(0.41, _t('AGUA')),
  MapEntry(0.47, _t('COMO_ESTAS')),
  MapEntry(0.52, _t('GRACIAS')),
];

Prediction _pred(double d, double margen) =>
    Prediction('HOLA', 'id_HOLA', 'Hola', d, margen, d <= .55 && margen >= .12);

Widget _tarjeta(Prediction p,
        {bool dev = false,
        Template? elegida,
        ValueChanged<Template>? onAlternativa,
        VoidCallback? onVerEnAvatar}) =>
    _app(TarjetaResultado(
      prediccion: p,
      umbral: .55,
      margenMin: .12,
      candidatas: _candidatas,
      elegida: elegida,
      desarrollador: dev,
      onAlternativa: onAlternativa ?? (_) {},
      onHablar: () {},
      onVerEnAvatar: onVerEnAvatar,
    ));

void main() {
  group('TarjetaResultado', () {
    late List<MethodCall> plataforma;

    setUp(() {
      plataforma = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        plataforma.add(call);
        return null;
      });
    });

    bool vibro() => plataforma.any((c) =>
        c.method == 'HapticFeedback.vibrate' &&
        c.arguments == 'HapticFeedbackType.lightImpact');

    testWidgets('aceptada con holgura: grande, Alta, sin numeros',
        (tester) async {
      await tester.pumpWidget(_tarjeta(_pred(.20, .5)));
      await tester.pumpAndSettle();
      expect(find.text('Hola'), findsOneWidget);
      final estilo = tester.widget<Text>(find.text('Hola')).style!;
      expect(estilo.fontSize,
          Theme.of(tester.element(find.text('Hola'))).textTheme.headlineMedium!.fontSize);
      expect(find.text('Confianza Alta'), findsOneWidget);
      expect(find.textContaining('distancia'), findsNothing);
      // Alternativas sin la ganadora y sin distancias.
      expect(find.text('¿Quisiste decir…?'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'agua'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'como estas'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'gracias'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'Hola'), findsNothing);
      expect(vibro(), isTrue, reason: 'resultado nuevo aceptado vibra');
    });

    testWidgets('aceptada justa: Media', (tester) async {
      await tester.pumpWidget(_tarjeta(_pred(.50, .15)));
      await tester.pumpAndSettle();
      expect(find.text('Confianza Media'), findsOneWidget);
      expect(find.text('Hola'), findsOneWidget);
    });

    testWidgets('rechazada: amable, Baja, la mas parecida entre alternativas',
        (tester) async {
      await tester.pumpWidget(_tarjeta(_pred(.80, .05),
          onVerEnAvatar: () {}));
      await tester.pumpAndSettle();
      expect(find.text('No estoy seguro. Inténtalo de nuevo.'), findsOneWidget);
      expect(find.text('Confianza Baja'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'Hola'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'gracias'), findsNothing,
          reason: 'hasta 3 alternativas');
      expect(find.text('Ver en avatar'), findsNothing,
          reason: 'sin resultado no hay que reproducir');
      expect(find.textContaining('la más parecida'), findsNothing);
      expect(vibro(), isFalse);
    });

    testWidgets('modo desarrollador: numeros crudos y distancias',
        (tester) async {
      await tester.pumpWidget(_tarjeta(_pred(.80, .05), dev: true));
      await tester.pumpAndSettle();
      expect(
          find.text('distancia 0.800 (máx 0.55)  ·  margen 0.050 (mín 0.12)'),
          findsOneWidget);
      expect(find.text('la más parecida fue Hola'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'agua · 0.410'), findsOneWidget);
    });

    testWidgets('tocar una alternativa la elige; Ver en avatar avisa',
        (tester) async {
      Template? elegida;
      var verAvatar = 0;
      await tester.pumpWidget(_tarjeta(_pred(.20, .5),
          onAlternativa: (t) => elegida = t,
          onVerEnAvatar: () => verAvatar++));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ActionChip, 'agua'));
      expect(elegida?.gloss, 'AGUA');
      await tester.tap(find.text('Ver en avatar'));
      expect(verAvatar, 1);
    });

    testWidgets('corregida: muestra la elegida, no vibra y ofrece volver',
        (tester) async {
      await tester.pumpWidget(_tarjeta(_pred(.20, .5), elegida: _t('AGUA')));
      await tester.pumpAndSettle();
      expect(find.text('agua'), findsOneWidget);
      expect(find.text('Corregida por ti'), findsOneWidget);
      expect(find.textContaining('Confianza'), findsNothing);
      expect(find.widgetWithText(ActionChip, 'Hola'), findsOneWidget);
      expect(vibro(), isFalse);
    });

    testWidgets('sin animaciones del sistema aparece directo', (tester) async {
      await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: _tarjeta(_pred(.20, .5)),
      ));
      expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
      expect(find.text('Hola'), findsOneWidget);
    });
  });

  group('EncabezadoReconocer', () {
    const r = ResumenDiccionario(
        delPaquete: 146,
        sincronizadas: 0,
        locales: 0,
        espejadas: 146,
        senasDistintas: 44);

    testWidgets('para todos: solo senas disponibles', (tester) async {
      await tester.pumpWidget(_app(const EncabezadoReconocer(resumen: r)));
      expect(find.text('Reconocer seña'), findsOneWidget);
      expect(find.text('44 señas disponibles'), findsOneWidget);
      expect(find.textContaining('plantillas'), findsNothing);
    });

    testWidgets('desarrollador: desglose que suma el total', (tester) async {
      await tester.pumpWidget(
          _app(const EncabezadoReconocer(resumen: r, desarrollador: true)));
      expect(
          find.text(
              '292 plantillas = 146 base (paquete) + 0 locales + 146 espejadas'),
          findsOneWidget);
    });

    testWidgets('cargando', (tester) async {
      await tester.pumpWidget(_app(const EncabezadoReconocer(resumen: null)));
      expect(find.text('Cargando señas…'), findsOneWidget);
    });
  });

  group('Guia inicial', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('guia_reconocer');
      ControladorGuiaInicial.directorioParaPruebas = () async => tmp;
    });
    tearDown(() {
      ControladorGuiaInicial.directorioParaPruebas = null;
      tmp.deleteSync(recursive: true);
    });

    Widget capa(ControladorGuiaInicial c) => MaterialApp(
          theme: temaUnivoz(),
          home: Scaffold(
            body: CapaGuiaInicial(
                controlador: c, child: const Center(child: Text('pantalla'))),
          ),
        );

    testWidgets('primera vez: 3 pasos con Siguiente y se recuerda',
        (tester) async {
      final c = ControladorGuiaInicial();
      await tester.runAsync(c.mostrarSiPrimeraVez);
      await tester.pumpWidget(capa(c));
      expect(find.text('1 de 3'), findsOneWidget);
      expect(find.text('Colócate para que se vean tus hombros y manos'),
          findsOneWidget);
      await tester.tap(find.text('Siguiente'));
      await tester.pump();
      expect(find.text('En Automático reconozco cuando terminas la seña'),
          findsOneWidget);
      await tester.tap(find.text('Siguiente'));
      await tester.pump();
      expect(find.text('Toca una alternativa si me equivoqué'), findsOneWidget);
      expect(find.text('Omitir'), findsNothing, reason: 'el ultimo cierra');
      await tester.runAsync(() async {
        await tester.tap(find.text('Entendido'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      expect(c.abierta, isFalse);
      expect(find.text('pantalla'), findsOneWidget);
      expect(await tester.runAsync(ControladorGuiaInicial.yaVista), isTrue);

      // Otra apertura de la pantalla ya no la muestra sola.
      final otra = ControladorGuiaInicial();
      await tester.runAsync(otra.mostrarSiPrimeraVez);
      expect(otra.abierta, isFalse);
    });

    testWidgets('Omitir tambien la recuerda y el boton de info la reabre',
        (tester) async {
      final c = ControladorGuiaInicial();
      await tester.runAsync(c.mostrarSiPrimeraVez);
      await tester.pumpWidget(capa(c));
      await tester.runAsync(() async {
        await tester.tap(find.text('Omitir'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      expect(find.text('1 de 3'), findsNothing);
      expect(await tester.runAsync(ControladorGuiaInicial.yaVista), isTrue);
      c.abrir();
      await tester.pump();
      expect(find.text('1 de 3'), findsOneWidget);
    });

    testWidgets('archivo corrupto cuenta como no vista', (tester) async {
      File('${tmp.path}/guia_reconocer.json').writeAsStringSync('{{no');
      expect(await tester.runAsync(ControladorGuiaInicial.yaVista), isFalse);
    });
  });

  group('GuiaEncuadre', () {
    LandmarkFrame frame({double anchoHombros = 0.24, bool persona = true}) {
      final data =
          jsonDecode(File('test/golden/golden_cases.json').readAsStringSync())
              as Map<String, dynamic>;
      final f = ((data['cases'] as List).first as Map)['frames'][0] as Map;
      final m = jsonDecode(jsonEncode({
        't': 0,
        'pose': f['pose'],
        'poseMundo': f['pose_mundo'],
        'left': f['left'],
        'right': f['right'],
      })) as Map<String, dynamic>;
      final pose = m['pose'] as List;
      (pose[11] as List)[0] = 0.5 - anchoHombros / 2;
      (pose[12] as List)[0] = 0.5 + anchoHombros / 2;
      if (!persona) m.remove('pose');
      return LandmarkFrame.fromMap(m);
    }

    testWidgets('la pastilla aparece tras 1 s y se va tras 0.5 s bien',
        (tester) async {
      var ahora = 0;
      final notificador = ValueNotifier<LandmarkFrame?>(frame());
      await tester.pumpWidget(_app(SizedBox(
          width: 200,
          height: 260,
          child: GuiaEncuadre(frame: notificador, ahora: () => ahora))));
      expect(find.text(kPistaAcercate), findsNothing);

      Future<void> llega(LandmarkFrame f, int t) async {
        ahora = t;
        notificador.value = f;
        await tester.pump(const Duration(milliseconds: 300));
      }

      await llega(frame(anchoHombros: 0.08), 100);
      await llega(frame(anchoHombros: 0.081), 900);
      expect(find.text(kPistaAcercate), findsNothing);
      await llega(frame(anchoHombros: 0.082), 1150);
      expect(find.text(kPistaAcercate), findsOneWidget);
      await llega(frame(), 1300);
      expect(find.text(kPistaAcercate), findsOneWidget);
      await llega(frame(anchoHombros: 0.241), 1850);
      await tester.pumpAndSettle();
      expect(find.text(kPistaAcercate), findsNothing);
      notificador.dispose();
    });

    testWidgets('silueta solo sin persona', (tester) async {
      var ahora = 0;
      final notificador =
          ValueNotifier<LandmarkFrame?>(frame(persona: false));
      await tester.pumpWidget(_app(SizedBox(
          width: 200,
          height: 260,
          child: GuiaEncuadre(frame: notificador, ahora: () => ahora))));
      double opacidad() => tester
          .widget<AnimatedOpacity>(find.descendant(
              of: find.byType(GuiaEncuadre),
              matching: find.byType(AnimatedOpacity)))
          .opacity;
      expect(opacidad(), 0);
      ahora = 600;
      notificador.value = frame(persona: false);
      await tester.pumpAndSettle();
      expect(opacidad(), 1);
      ahora = 700;
      notificador.value = frame();
      await tester.pumpAndSettle();
      expect(opacidad(), 0);
      notificador.dispose();
    });
  });
}
