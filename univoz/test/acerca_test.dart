import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:univoz/screens/acerca_screen.dart';

void main() {
  test('cada fuente de datos tiene licencia (CC o uso autorizado), cita y enlace', () {
    expect(fuentesDeDatos.length, greaterThanOrEqualTo(5));
    for (final f in fuentesDeDatos) {
      expect(
          f.licencia.startsWith('CC BY') ||
              f.licencia.startsWith('Uso autorizado'),
          isTrue,
          reason: f.nombre);
      expect(f.cita.length, greaterThan(20), reason: f.nombre);
      expect(f.enlace, startsWith('https://'), reason: f.nombre);
    }
    // El Glosario de INDISCAPACIDAD CDMX (señas solo de aprendizaje).
    expect(fuentesDeDatos.any((f) => f.nombre.contains('INDISCAPACIDAD')),
        isTrue);
  });

  testWidgets('la pantalla Acerca de muestra los créditos', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AcercaScreen()));
    expect(find.text('Acerca de y créditos'), findsOneWidget);
    expect(find.textContaining('UAEMex'), findsWidgets);
    expect(find.textContaining('CICESE'), findsWidgets);
    expect(find.text('Licencia CC BY-SA 4.0'), findsOneWidget);
  });
}
