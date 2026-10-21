import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:senas_core/avatar_bridge.dart';
import 'package:senas_core/modo_desarrollador.dart';
import 'package:senas_core/pantalla_espejo.dart';

void main() {
  setUp(() {
    ModoDesarrollador.directorioParaPruebas =
        () async => throw const FileSystemException('sin disco');
    ModoDesarrollador.restablecerParaPruebas();
  });
  tearDown(() {
    ModoDesarrollador.directorioParaPruebas = null;
    ModoDesarrollador.restablecerParaPruebas();
  });

  Future<void> montar(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
        home: PantallaEspejo(
            modoProducto: true, visorParaPruebas: AvatarBridge.sinVisor())));
    await tester.pump();
  }

  testWidgets('espejo del producto: estado del cuerpo si, numeros no',
      (tester) async {
    await montar(tester);
    expect(find.textContaining('Cuerpo'), findsOneWidget);
    expect(find.textContaining('frames enviados'), findsNothing);
    expect(find.textContaining('Lados:'), findsNothing);
  });

  testWidgets('con modo desarrollador aparecen los numeros', (tester) async {
    ModoDesarrollador.notificador.value = true;
    await montar(tester);
    expect(find.textContaining('frames enviados'), findsOneWidget);
    expect(find.textContaining('Lados:'), findsOneWidget);
  });
}
