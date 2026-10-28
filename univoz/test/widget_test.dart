import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:univoz/main.dart';
import 'package:univoz/screens/purpose_screen.dart';
import 'package:univoz/screens/traducir_senas_screen.dart';
import 'package:univoz/screens/welcome_screen.dart';

void main() {
  testWidgets('welcome navigates to purpose selection', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WelcomeScreen()));

    expect(find.text('COMENZAR'), findsOneWidget);
    await tester.tap(find.text('COMENZAR'));
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
    expect(find.text('COMENZAR'), findsOneWidget);
    expect(find.text('¿Cómo funciona?'), findsOneWidget);
  });
}
