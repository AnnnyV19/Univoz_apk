import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

import 'package:senas_core/dtw.dart';
import 'package:senas_core/plantillas.dart';
import 'package:senas_core/reconocer/disposicion_reconocer.dart';
import 'package:senas_core/reconocer/encabezado_reconocer.dart';
import 'package:senas_core/reconocer/tarjeta_resultado.dart';
import 'package:senas_core/sign_norm.dart' show kFrameDim;
import 'package:senas_core/tema_univoz.dart';

final _seq = [List<double>.filled(kFrameDim, 0.0)];
Template _t(String g, [String e = '']) =>
    Template('id_$g', g, _seq, espanol: e);

const _avatar = Key('avatar');
const _camara = Key('camara');
const _boton = Key('boton_grabar');

/// La pantalla "Reconocer seña" armada con las mismas piezas que
/// PantallaDeTranslacion (que no se puede montar: el WebView necesita
/// plataforma): AppBar con encabezado, franja de modo, DisposicionReconocer
/// con la tarjeta real y el boton de abajo.
Widget _pantalla({required String gloss, double escala = 1.0}) {
  final ganadora = _t(gloss);
  final candidatas = [
    MapEntry(0.21, ganadora),
    MapEntry(0.41, _t('AGUA')),
    MapEntry(0.47, _t('COMO_ESTAS')),
    MapEntry(0.52, _t('GRACIAS')),
  ];
  return MaterialApp(
    theme: _tema(),
    builder: (context, hijo) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(escala)),
      child: hijo!,
    ),
    home: Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const EncabezadoReconocer(
            resumen: ResumenDiccionario(
                delPaquete: 146,
                sincronizadas: 0,
                locales: 0,
                espejadas: 146,
                senasDistintas: 44)),
        centerTitle: true,
        toolbarHeight: 64,
        actions: [
          IconButton(onPressed: () {}, icon: const Icon(Icons.info_outline)),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
            child: Row(children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SelectorModo(automatico: false, onCambiar: (_) {}),
                ),
              ),
              IconButton(
                  onPressed: () {},
                  icon: const Icon(Icons.cameraswitch_outlined)),
            ]),
          ),
          Expanded(
            child: DisposicionReconocer(
              avatar: const ColoredBox(key: _avatar, color: Color(0xFFDDDDDD)),
              camara: (_) =>
                  const ColoredBox(key: _camara, color: Color(0xFF333333)),
              panel: TarjetaResultado(
                prediccion: Prediction(gloss, 'id_$gloss', '', .21, .49, true),
                umbral: .55,
                margenMin: .12,
                candidatas: candidatas,
                onAlternativa: (_) {},
                onHablar: () {},
                onVerEnAvatar: () {},
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: _boton,
                  onPressed: () {},
                  icon: const Icon(Icons.fiber_manual_record),
                  label: const Text('Grabar seña'),
                  style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16)),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Roboto real (la de Android) desde los artefactos del SDK: la fuente de
/// pruebas dibuja cada letra como un cuadro de 1 em, casi el doble de ancho,
/// y las medidas de texto no se parecerian a un telefono.
Future<void> _cargarRoboto() async {
  final artefactos =
      File(Platform.resolvedExecutable).parent.parent.parent.path;
  final carpeta = Directory('$artefactos/material_fonts');
  if (!carpeta.existsSync()) return;
  final roboto = FontLoader('Roboto');
  for (final nombre in ['Roboto-Regular.ttf', 'Roboto-Medium.ttf',
      'Roboto-Bold.ttf']) {
    final f = File('${carpeta.path}/$nombre');
    if (!f.existsSync()) continue;
    roboto.addFont(
        Future.value(ByteData.sublistView(f.readAsBytesSync())));
  }
  await roboto.load();
}

ThemeData _tema() {
  final t = temaUnivoz();
  return t.copyWith(
    textTheme: t.textTheme.apply(fontFamily: 'Roboto'),
    // Botones con estilo de texto propio (sin familia) tambien en Roboto.
    filledButtonTheme: FilledButtonThemeData(
        style: t.filledButtonTheme.style?.copyWith(
            textStyle: WidgetStatePropertyAll(
                const TextStyle(fontFamily: 'Roboto', fontSize: 16)))),
  );
}

/// Telefono de [ancho] x [alto] dp con barra de estado y de navegacion.
void _telefono(WidgetTester tester, double ancho, double alto) {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = Size(ancho * 2, alto * 2);
  tester.view.padding = const FakeViewPadding(top: 48, bottom: 96);
  addTearDown(tester.view.reset);
}

void main() {
  setUpAll(_cargarRoboto);

  for (final escala in [1.0, 1.3]) {
    for (final gloss in ['HOLA', 'ME_AYUDAS_UN_POCO']) {
      testWidgets(
          '360x640 a escala $escala ($gloss): resultado, confianza y la '
          'primera alternativa sin desplazar', (tester) async {
        _telefono(tester, 360, 640);
        await tester.pumpWidget(_pantalla(gloss: gloss, escala: escala));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'sin desbordes');

        final texto = gloss.toLowerCase().replaceAll('_', ' ');
        final nombre = tester.renderObject<RenderParagraph>(find.text(texto));
        expect(nombre.didExceedMaxLines, isFalse,
            reason: 'el nombre de la sena no se recorta');
        expect(find.text('Confianza Alta').hitTestable(), findsOneWidget);
        expect(find.text(texto).hitTestable(), findsOneWidget);

        // La primera alternativa se puede tocar tal cual, sin desplazar,
        // y queda arriba del boton de grabar.
        final chip = find.byType(ActionChip).first;
        expect(chip.hitTestable(), findsOneWidget);
        expect(tester.getRect(chip).bottom,
            lessThanOrEqualTo(tester.getRect(find.byKey(_boton)).top));

        // Camara junto al avatar, nunca encima; el avatar conserva alto.
        final avatar = tester.getRect(find.byKey(_avatar));
        final camara = tester.getRect(find.byKey(_camara));
        expect(avatar.overlaps(camara), isFalse);
        expect(camara.left, greaterThanOrEqualTo(avatar.right));
        expect(avatar.height, greaterThanOrEqualTo(kAltoMinimoArriba - 8));
      });
    }
  }

  testWidgets('telefono alto: el avatar se queda con ~55 %', (tester) async {
    _telefono(tester, 360, 800);
    await tester.pumpWidget(_pantalla(gloss: 'HOLA'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final area = tester.getRect(find.byType(DisposicionReconocer));
    final avatar = tester.getRect(find.byKey(_avatar));
    expect(avatar.height / area.height, closeTo(0.55, 0.04));
    expect(find.byType(ActionChip).first.hitTestable(), findsOneWidget);
  });

  testWidgets('ancho (horizontal): avatar y camara lado a lado 3:2',
      (tester) async {
    _telefono(tester, 800, 600);
    await tester.pumpWidget(_pantalla(gloss: 'HOLA', escala: 1.3));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final avatar = tester.getRect(find.byKey(_avatar));
    final camara = tester.getRect(find.byKey(_camara));
    expect(avatar.overlaps(camara), isFalse);
    expect(avatar.width / camara.width, closeTo(1.5, 0.05));
  });
}
