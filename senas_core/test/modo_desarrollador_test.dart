import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:senas_core/muestras_locales.dart';
import 'package:senas_core/modo_desarrollador.dart';

class _RutasFalsas extends PathProviderPlatform {
  _RutasFalsas(this.ruta);
  final String ruta;
  @override
  Future<String?> getApplicationDocumentsPath() async => ruta;
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('modo_dev_test');
    ModoDesarrollador.directorioParaPruebas = () async => tmp;
    ModoDesarrollador.restablecerParaPruebas();
  });

  tearDown(() async {
    ModoDesarrollador.directorioParaPruebas = null;
    await tmp.delete(recursive: true);
  });

  test('arranca apagado y alternar notifica y persiste', () async {
    expect(ModoDesarrollador.activo, isFalse);
    var avisos = 0;
    ModoDesarrollador.notificador.addListener(() => avisos++);
    expect(await ModoDesarrollador.alternar(), isTrue);
    expect(ModoDesarrollador.activo, isTrue);
    expect(avisos, 1);

    // Un arranque nuevo lee lo guardado.
    ModoDesarrollador.restablecerParaPruebas();
    expect(ModoDesarrollador.activo, isFalse);
    await ModoDesarrollador.cargar();
    expect(ModoDesarrollador.activo, isTrue);

    expect(await ModoDesarrollador.alternar(), isFalse);
    ModoDesarrollador.restablecerParaPruebas();
    await ModoDesarrollador.cargar();
    expect(ModoDesarrollador.activo, isFalse);
  });

  test('archivo corrupto se trata como apagado', () async {
    await File('${tmp.path}/modo_desarrollador.json').writeAsString('{{no');
    await ModoDesarrollador.cargar();
    expect(ModoDesarrollador.activo, isFalse);
  });

  test('sin carpeta disponible no revienta y sigue en memoria', () async {
    ModoDesarrollador.directorioParaPruebas =
        () async => throw const FileSystemException('sin disco');
    expect(await ModoDesarrollador.alternar(), isTrue);
    expect(ModoDesarrollador.activo, isTrue);
  });

  testWidgets('DetectorModoDesarrollador: 7 toques alternan con aviso',
      (tester) async {
    ModoDesarrollador.directorioParaPruebas =
        () async => throw const FileSystemException('sin disco');
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Center(
          child: DetectorModoDesarrollador(child: Text('Univoz 0.9.0 beta')),
        ),
      ),
    ));
    final texto = find.text('Univoz 0.9.0 beta');
    for (var i = 0; i < 6; i++) {
      await tester.tap(texto);
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(ModoDesarrollador.activo, isFalse);
    await tester.tap(texto);
    await tester.pump();
    await tester.pump();
    expect(ModoDesarrollador.activo, isTrue);
    expect(find.text('Modo desarrollador activado'), findsOneWidget);

    // Otros 7 toques lo apagan.
    ScaffoldMessenger.of(tester.element(texto)).clearSnackBars();
    await tester.pump();
    for (var i = 0; i < 7; i++) {
      await tester.tap(texto);
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump();
    expect(ModoDesarrollador.activo, isFalse);
    expect(find.text('Modo desarrollador desactivado'), findsOneWidget);
  });

  testWidgets('toques lentos no cuentan (ventana de 3 s entre toques)',
      (tester) async {
    ModoDesarrollador.directorioParaPruebas =
        () async => throw const FileSystemException('sin disco');
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Center(child: DetectorModoDesarrollador(child: Text('v'))),
      ),
    ));
    for (var i = 0; i < 7; i++) {
      await tester.tap(find.text('v'));
      await tester.pump(const Duration(seconds: 4));
    }
    expect(ModoDesarrollador.activo, isFalse);
  });

  group('diagnosticos ocultos al apagar el modo', () {
    final almacen = AlmacenMuestras.instancia;

    setUp(() {
      PathProviderPlatform.instance = _RutasFalsas(tmp.path);
      almacen.ajustes = Ajustes()..rigDiagnosticMode = true;
    });

    test('apagar el modo desactiva rigDiagnosticMode y lo guarda', () async {
      await ModoDesarrollador.establecer(true);
      expect(almacen.ajustes.rigDiagnosticMode, isTrue);
      await ModoDesarrollador.establecer(false);
      expect(almacen.ajustes.rigDiagnosticMode, isFalse);
      final guardado = File('${tmp.path}/$kNombreArchivo').readAsStringSync();
      expect(guardado, contains('"rig_diagnostic_mode":false'));
    });

    test('un diagnostico guardado de antes se apaga al arrancar sin modo',
        () async {
      await ModoDesarrollador.cargar();
      expect(ModoDesarrollador.activo, isFalse);
      expect(almacen.ajustes.rigDiagnosticMode, isFalse);
    });

    test('encendido no toca el diagnostico', () async {
      await ModoDesarrollador.establecer(true);
      expect(almacen.ajustes.rigDiagnosticMode, isTrue);
    });
  });

  test('forzarActivo enciende en memoria sin escribir ni apagar diagnosticos',
      () async {
    PathProviderPlatform.instance = _RutasFalsas(tmp.path);
    final almacen = AlmacenMuestras.instancia;
    almacen.ajustes = Ajustes()..rigDiagnosticMode = true;
    ModoDesarrollador.forzarActivo();
    expect(ModoDesarrollador.activo, isTrue);
    expect(almacen.ajustes.rigDiagnosticMode, isTrue);
    expect(File('${tmp.path}/modo_desarrollador.json').existsSync(), isFalse);
    almacen.ajustes = Ajustes();
  });
}
