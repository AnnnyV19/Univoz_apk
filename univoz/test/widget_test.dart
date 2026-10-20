// Prueba de humo de la app: arranca MyApp y comprueba que la pantalla de
// bienvenida aparece con sus dos botones. (Reemplaza la plantilla del contador
// de Flutter, que ya no corresponde a esta app; el original quedó respaldado en
// D:\UNIVOZ_APK\_respaldo_antes_de_widget_test\.)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:univoz/main.dart';

void main() {
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
