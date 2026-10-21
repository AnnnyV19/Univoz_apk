import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:univoz/screens/privacidad_screen.dart';

void main() {
  test('el texto de la app es el de docs/PRIVACIDAD.md', () {
    final md = File('../docs/PRIVACIDAD.md').readAsStringSync();
    expect(privacidadMarkdown(), md);
  });

  testWidgets('la pantalla muestra el texto', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: PrivacidadScreen()));
    expect(find.text('Privacidad'), findsOneWidget);
    expect(find.text('Tu cámara'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Cómo borrar tus datos'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Cómo borrar tus datos'), findsOneWidget);
  });
}
