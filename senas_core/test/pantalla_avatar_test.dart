// Prueba de la pantalla del diccionario (PantallaAvatar) sin telefono: el
// puente es AvatarBridge.sinVisor (no dibuja el avatar, pero guarda el JS que
// la pantalla le manda) y VistaAvatar recibe un widget en lugar del WebView y el diccionario es uno chico armado aqui.
//
// Lo que se comprueba es lo que fallaba: que el diccionario CABE y se puede
// recorrer en pantallas chicas (con y sin teclado), que se filtra al escribir,
// que tocar una seña manda la secuencia al visor y que una seña con la mano
// ausente al principio y al final llega recortada.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:senas_core/avatar_bridge.dart';
import 'package:senas_core/dtw.dart';
import 'package:senas_core/pantalla_avatar.dart';
import 'package:senas_core/plantillas.dart';
import 'package:senas_core/sign_norm.dart';

/// Lo que la pantalla le pidio ejecutar al visor (JavaScript).
final List<String> _js = [];

/// Sin carpetas del sistema. Dentro de un testWidgets el disco y los canales
/// reales no responden (el reloj es falso), y la pantalla se quedaba esperando
/// la calibracion guardada. Asi falla al instante, y la pantalla ya sabe
/// seguir sin ella.
class _SinCarpetas extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async => null;

  @override
  Future<String?> getTemporaryPath() async => null;
}

/// 32 cuadros: hombros en su sitio y la mano DERECHA presente en
/// [desde]..[hasta] (la mano sube 0.01 por cuadro).
List<List<double>> _seq({int desde = 0, int hasta = 31, bool izquierda = false}) {
  return [
    for (var i = 0; i < kTFrames; i++)
      () {
        final f = List<double>.filled(kFrameDim, 0.0);
        f[0] = -0.5;
        f[3] = 0.5;
        f[6] = -0.8; // codo izquierdo
        f[7] = -0.6;
        f[9] = 0.8; // codo derecho
        f[10] = -0.6;
        if (i >= desde && i <= hasta) {
          final pres = izquierda ? kOffPresL : kOffPresR;
          final loc = izquierda ? kOffLocL : kOffLocR;
          final forma = izquierda ? kOffShapeL : kOffShapeR;
          f[pres] = 1.0;
          f[loc] = 0.3;
          f[loc + 1] = 0.2 + 0.01 * i;
          for (var k = 0; k < 60; k++) {
            f[forma + k] = 0.1 * (k % 5) + 0.01 * i;
          }
        }
        return f;
      }(),
  ];
}

Diccionario _diccionarioDePrueba() {
  final c = DtwClassifier(maxDistance: 0.5, minMargin: 0.32, prefilter: 40);
  var n = 0;
  void agrega(String gloss, String espanol, List<List<double>> seq) {
    c.add('id-$gloss', gloss, seq, espanol: espanol);
    n++;
  }

  agrega('HOLA', 'hola', _seq());
  agrega('COMO_ESTAS', '¿cómo estás?', _seq());
  agrega('SI_PUEDO', 'sí puedo', _seq(desde: 8, hasta: 22)); // mano 15/32
  agrega('SOLO_IZQUIERDA', 'con la izquierda', _seq(izquierda: true));
  agrega('A', 'a', _seq());
  agrega('B', 'b', _seq());
  agrega('NN', 'ñ', _seq());
  for (var i = 1; i <= 40; i++) {
    final dos = i.toString().padLeft(2, '0');
    agrega('PALABRA_$dos', 'palabra $dos', _seq());
  }
  return Diccionario(
    c,
    ResumenDiccionario(
      delPaquete: n,
      sincronizadas: 0,
      locales: 0,
      espejadas: 0,
      senasDistintas: n,
    ),
  );
}

PantallaAvatar _pantalla(Future<Diccionario> Function() cargador) =>
    PantallaAvatar(
      cargador: cargador,
      puente: AvatarBridge.sinVisor(ejecutar: (js) async => _js.add(js)),
      vista: const SizedBox.expand(key: ValueKey('visor_falso')),
    );

Future<void> _abre(WidgetTester tester, Size tam) async {
  PathProviderPlatform.instance = _SinCarpetas();
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = tam;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: _pantalla(() async => _diccionarioDePrueba()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  setUp(_js.clear);

  for (final tam in const [
    Size(320, 568),
    Size(360, 640),
    Size(411, 731),
    Size(412, 915),
  ]) {
    testWidgets('el diccionario cabe y se ve en ${tam.width}x${tam.height}',
        (tester) async {
      await _abre(tester, tam);

      expect(tester.takeException(), isNull);
      expect(find.byType(ListView), findsOneWidget);
      // Varias filas a la vista, no una o dos como antes.
      expect(find.byType(ListTile).evaluate().length, greaterThanOrEqualTo(4));
      // El diccionario recibe una buena parte de la pantalla (en la mas chica,
      // 320x568, ya son ~4 filas; en las demas, bastante mas).
      expect(tester.getSize(find.byType(ListView)).height,
          greaterThanOrEqualTo(tam.height * 0.28));
      expect(find.text('47 señas'), findsOneWidget);
    });
  }

  testWidgets('con el teclado abierto no se desborda y la lista sigue a la vista',
      (tester) async {
    await _abre(tester, const Size(360, 640));
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(ListView)).height, greaterThan(60));
    expect(find.byType(ListTile).evaluate().length, greaterThanOrEqualTo(1));
  });

  testWidgets('con "Manos y velocidad" abierto tampoco se desborda', (tester) async {
    await _abre(tester, const Size(360, 640));
    await tester.tap(find.text('Manos y velocidad'));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Ambas'), findsOneWidget);
    expect(find.text('Velocidad'), findsOneWidget);
    expect(tester.getSize(find.byType(ListView)).height, greaterThan(100));
  });

  testWidgets('escribir filtra la lista sin importar acentos ni mayúsculas',
      (tester) async {
    await _abre(tester, const Size(360, 640));

    await tester.enterText(find.byType(TextField), 'PALABRA 03');
    await tester.pump();
    expect(find.byType(ListTile), findsOneWidget);
    expect(find.text('Palabra 03'), findsOneWidget);
    expect(find.text('1 de 47 señas'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'como estas');
    await tester.pump();
    expect(find.text('¿cómo estás?'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'zzzz');
    await tester.pump();
    expect(find.byType(ListTile), findsNothing);
    expect(find.textContaining('No hay señas que coincidan'), findsOneWidget);
  });

  testWidgets('tocar una seña manda la secuencia al visor', (tester) async {
    await _abre(tester, const Size(360, 640));
    expect(_js.where((j) => j.contains('reproducirSecuencia')), isEmpty);

    await tester.tap(find.text('Hola'));
    await tester.pump();

    final enviados = _js.where((j) => j.contains('reproducirSecuencia')).toList();
    expect(enviados, hasLength(1));
    expect(enviados.single, contains("'2.0.0'"));
    expect(find.text('Señando...'), findsOneWidget);
  });

  testWidgets('una seña con la mano ausente al principio y al final llega recortada',
      (tester) async {
    await _abre(tester, const Size(360, 640));

    await tester.enterText(find.byType(TextField), 'puedo');
    await tester.pump();
    await tester.tap(find.text('Sí puedo'));
    await tester.pump();

    final js = _js.firstWhere((j) => j.contains('reproducirSecuencia'));
    final json = js.substring(js.indexOf("('") + 2, js.indexOf("',"));
    final frames = (jsonDecode(json) as List)
        .map((f) => (f as List).map((v) => (v as num).toDouble()).toList())
        .toList();
    expect(frames.length, kTFrames);
    // Antes: mano solo en los cuadros 8..22. Ahora: en todos.
    expect(frames.every((f) => f[kOffPresR] >= 0.5), isTrue);
    // Las alturas no se tocan: primera y ultima son las de la seña original.
    expect(frames.first[kOffLocR + 1], closeTo(0.2 + 0.01 * 8, 1e-9));
    expect(frames.last[kOffLocR + 1], closeTo(0.2 + 0.01 * 22, 1e-9));
  });

  testWidgets('una palabra que no está avisa en la pantalla', (tester) async {
    await _abre(tester, const Size(360, 640));

    await tester.enterText(find.byType(TextField), 'murcielago');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    expect(find.textContaining('No tengo la seña de "murcielago"'),
        findsOneWidget);
    expect(_js.where((j) => j.contains('reproducirSecuencia')), isEmpty);
  });

  testWidgets('las señas de aprendizaje salen en el Diccionario y el avatar las hace',
      (tester) async {
    PathProviderPlatform.instance = _SinCarpetas();
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(360, 640);
    addTearDown(tester.view.reset);
    final base = _diccionarioDePrueba();
    final d = Diccionario(base.clasificador, base.resumen, aprendizaje: [
      Template('apr-1', 'ZAPATOS', _seq(), espanol: 'zapatos'),
    ]);
    await tester.pumpWidget(
        MaterialApp(home: _pantalla(() async => d)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.enterText(find.byType(TextField), 'zapatos');
    await tester.pump();
    expect(find.text('Zapatos'), findsOneWidget);
    await tester.tap(find.text('Zapatos'));
    await tester.pump();
    expect(_js.where((j) => j.contains('reproducirSecuencia')), hasLength(1));
    // No entra al reconocimiento.
    expect(base.clasificador.templates.any((t) => t.gloss == 'ZAPATOS'), isFalse);
  });

  testWidgets('una frase con señas que sí hay sale seguida, no "no la tengo"',
      (tester) async {
    await _abre(tester, const Size(360, 640));

    await tester.enterText(find.byType(TextField), 'Hola, ¿cómo estás?');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    expect(find.textContaining('No tengo'), findsNothing);
    final js = _js.where((j) => j.contains('reproducirFrase')).toList();
    expect(js, hasLength(1));
    expect(_js.where((j) => j.contains('reproducirSecuencia')), isEmpty);
    final json = js.single.substring(
        js.single.indexOf("('") + 2, js.single.indexOf("','"));
    final segmentos = jsonDecode(json) as List;
    expect(segmentos, hasLength(2)); // HOLA + COMO_ESTAS
    for (final s in segmentos) {
      expect((s as Map)['frames'], hasLength(kTFrames));
    }
    expect(js.single, contains("'2.0.0'"));
    expect(find.text('Señando...'), findsOneWidget);
  });

  testWidgets('una palabra que no está pero se puede deletrear se deletrea',
      (tester) async {
    await _abre(tester, const Size(360, 640));

    // "baña": B, A, Ñ, A existen en el diccionario de prueba.
    await tester.enterText(find.byType(TextField), 'hola baña');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    final js = _js.firstWhere((j) => j.contains('reproducirFrase'));
    final segmentos = jsonDecode(js.substring(js.indexOf("('") + 2,
        js.indexOf("','"))) as List;
    expect(segmentos, hasLength(5)); // HOLA + B A Ñ A
    expect(find.textContaining('«baña» deletreado'), findsOneWidget);
  });

  testWidgets('si se eligió una sola mano y la seña usa la otra, lo dice',
      (tester) async {
    await _abre(tester, const Size(360, 640));
    await tester.tap(find.text('Manos y velocidad'));
    await tester.pump();
    await tester.tap(find.text('Der.'));
    await tester.pump();

    await tester.tap(find.text('Con la izquierda'));
    await tester.pump();

    expect(find.textContaining('mano izquierda del avatar'), findsOneWidget);
  });
}
