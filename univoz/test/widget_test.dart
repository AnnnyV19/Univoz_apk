import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:univoz/main.dart';
import 'package:univoz/screens/purpose_screen.dart';
import 'package:univoz/screens/traducir_senas_screen.dart';
import 'package:univoz/screens/welcome_screen.dart';
import 'package:univoz/screens/tutorial_screen.dart';
import 'package:univoz/services/tutorial_visto.dart';

void main() {
  testWidgets('primera vez: bienvenida -> tutorial -> menu', (tester) async {
    TutorialVisto.restablecerParaPruebas(visto: false);
    TutorialVisto.directorioParaPruebas =
        () async => throw const FileSystemException('sin disco');
    addTearDown(() => TutorialVisto.directorioParaPruebas = null);
    await tester.pumpWidget(const MaterialApp(home: WelcomeScreen()));

    await tester.tap(find.text('Comenzar'));
    await tester.pumpAndSettle();
    expect(find.byType(TutorialScreen), findsOneWidget);
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.text('Siguiente'));
      await tester.pump();
    }
    await tester.tap(find.text('Empezar'));
    await tester.pumpAndSettle();
    expect(find.byType(PurposeScreen), findsOneWidget);
    expect(TutorialVisto.visto, isTrue);
  });

  testWidgets('welcome navigates to purpose selection', (tester) async {
    TutorialVisto.restablecerParaPruebas(visto: true);
    await tester.pumpWidget(const MaterialApp(home: WelcomeScreen()));

    expect(find.text('Comenzar'), findsOneWidget);
    await tester.tap(find.text('Comenzar'));
    await tester.pumpAndSettle();

    expect(find.byType(PurposeScreen), findsOneWidget);
    expect(find.text('¿Para qué quieres\nusar UNIVOZ?'), findsOneWidget);
  });

  testWidgets('purpose selection opens configuration without camera',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: PurposeScreen()));

    // Configuración es la tuerca de arriba, no una de las opciones.
    expect(find.text('Configuración'), findsNothing);
    await tester.tap(find.byTooltip('Configuración'));
    await tester.pumpAndSettle();

    expect(find.byType(TraducirSenasScreen), findsOneWidget);
    expect(
        find.text('Configuración de reconocimiento de señas'), findsOneWidget);
  });

  // Prueba de humo de la dueña (app-limpia): arranca MyApp completo.
  testWidgets('la app arranca en la pantalla de bienvenida', (tester) async {
    // Tamaño de un teléfono para que nada se desborde en la prueba.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MyApp());
    await tester.pump();

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.text('Comenzar'), findsOneWidget);
    expect(find.text('¿Cómo funciona?'), findsOneWidget);
  });
}
