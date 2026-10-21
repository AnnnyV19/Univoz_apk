import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:senas_core/modo_desarrollador.dart';
import 'package:senas_core/pantalla_ajustes.dart';
import 'package:senas_core/tema_univoz.dart';
import 'package:univoz/screens/purpose_screen.dart';
import 'package:univoz/screens/traducir_senas_screen.dart';

void main() {
  setUp(() {
    // Sin disco: el modo vive en memoria durante la prueba.
    ModoDesarrollador.directorioParaPruebas =
        () async => throw const FileSystemException('sin disco');
    ModoDesarrollador.restablecerParaPruebas();
  });

  tearDown(() {
    ModoDesarrollador.directorioParaPruebas = null;
    ModoDesarrollador.restablecerParaPruebas();
  });

  Widget app(Widget home, {double escala = 1.0}) => MaterialApp(
        theme: temaUnivoz(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(escala),
          ),
          child: child!,
        ),
        home: home,
      );

  group('Configuración y modo desarrollador', () {
    testWidgets('apagado: solo lo esencial y la versión', (tester) async {
      await tester.pumpWidget(app(const TraducirSenasScreen()));

      expect(find.text('Ajustes de reconocimiento'), findsOneWidget);
      expect(find.text('Sincronizar'), findsOneWidget);
      // El espejo es del producto; capturar muestras es de desarrollo.
      expect(find.text('Espejo'), findsOneWidget);
      expect(find.text('Agregar muestras'), findsNothing);
      expect(find.text(kVersionApp), findsOneWidget);
      expect(kVersionApp, 'Univoz 0.9.0 beta');
    });

    test('kVersionApp coincide con la versión de pubspec.yaml', () {
      final linea = File('pubspec.yaml')
          .readAsLinesSync()
          .firstWhere((l) => l.startsWith('version:'));
      final nombre = RegExp(r'version:\s*([\d.]+)\+\d+').firstMatch(linea)![1]!;
      expect(kVersionApp, startsWith('Univoz $nombre'));
    });

    test('docs/RELEASE.md cita la versión y el build de pubspec.yaml', () {
      final linea = File('pubspec.yaml')
          .readAsLinesSync()
          .firstWhere((l) => l.startsWith('version:'));
      final completa = RegExp(r'version:\s*(\S+)').firstMatch(linea)![1]!;
      expect(File('../docs/RELEASE.md').readAsStringSync(),
          contains('Versión actual: $completa'));
    });

    testWidgets('Privacidad abre el texto de privacidad', (tester) async {
      await tester.pumpWidget(app(const TraducirSenasScreen()));

      await tester.scrollUntilVisible(find.text('Privacidad'), 200);
      await tester.tap(find.text('Privacidad'));
      await tester.pumpAndSettle();

      expect(find.text('Privacidad de Univoz'), findsOneWidget);
      expect(find.text('Tu cámara'), findsOneWidget);
    });

    testWidgets('7 toques en la versión muestran las herramientas',
        (tester) async {
      await tester.pumpWidget(app(const TraducirSenasScreen()));

      for (var i = 0; i < 7; i++) {
        await tester.tap(find.text(kVersionApp));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump();

      expect(ModoDesarrollador.activo, isTrue);
      expect(find.text('Modo desarrollador activado'), findsOneWidget);
      expect(find.text('Agregar muestras'), findsOneWidget);
      expect(find.text('Espejo'), findsOneWidget);

      // Otros 7 toques lo apagan y vuelven a ocultarse.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      for (var i = 0; i < 7; i++) {
        await tester.tap(find.text(kVersionApp));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(ModoDesarrollador.activo, isFalse);
      expect(find.text('Modo desarrollador desactivado'), findsOneWidget);
      expect(find.text('Agregar muestras'), findsNothing);
    });

    testWidgets('Ajustes de reconocimiento abre sin pedir la cámara',
        (tester) async {
      // Si pidiera la cámara, el canal de permission_handler fallaría en la
      // prueba (no hay plugin) y la pantalla no se abriría.
      await tester.pumpWidget(app(const TraducirSenasScreen()));
      await tester.tap(find.text('Ajustes de reconocimiento'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(PantallaAjustes), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Texto grande (escala 1.3)', () {
    for (final escala in [1.3]) {
      testWidgets('Purpose sin desbordes a x$escala', (tester) async {
        tester.view.physicalSize = const Size(360 * 3, 640 * 3);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(app(const PurposeScreen(), escala: escala));
        await tester.pump();
        expect(tester.takeException(), isNull);
      });

      testWidgets('Configuración sin desbordes a x$escala', (tester) async {
        tester.view.physicalSize = const Size(360 * 3, 640 * 3);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        await tester
            .pumpWidget(app(const TraducirSenasScreen(), escala: escala));
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  });
}
