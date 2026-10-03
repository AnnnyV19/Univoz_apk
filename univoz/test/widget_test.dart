import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

    final configuracion = find.byKey(const ValueKey('purpose-configuracion'));
    await tester.ensureVisible(configuracion);
    await tester.tap(configuracion);
    await tester.pump();
    expect(
      tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
      isNotNull,
    );
    await tester.tap(find.text('Comenzar ahora'));
    await tester.pumpAndSettle();

    expect(find.byType(TraducirSenasScreen), findsOneWidget);
    expect(
        find.text('Configuración de reconocimiento de señas'), findsOneWidget);
  });
}
