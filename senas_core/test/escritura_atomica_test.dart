import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:senas_core/escritura_atomica.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('atomico_'));
  tearDown(() => dir.deleteSync(recursive: true));

  List<String> tmps() => dir
      .listSync()
      .map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last)
      .where((n) => n.endsWith('.tmp'))
      .toList();

  test('crea el archivo y no deja .tmp', () async {
    final f = File('${dir.path}/datos.json');
    await escribirAtomico(f, '{"a":1}');
    expect(f.readAsStringSync(), '{"a":1}');
    expect(tmps(), isEmpty);
  });

  test('reemplaza el contenido anterior completo', () async {
    final f = File('${dir.path}/datos.json')..writeAsStringSync('viejo' * 100);
    await escribirAtomico(f, 'nuevo');
    expect(f.readAsStringSync(), 'nuevo');
  });

  test('si la escritura falla lanza, no deja .tmp y el destino sigue igual',
      () async {
    // Un directorio no vacio en el destino hace fallar el rename.
    final destino = Directory('${dir.path}/datos.json')..createSync();
    File('${destino.path}/dentro.txt').writeAsStringSync('x');
    await expectLater(
        escribirAtomico(File(destino.path), 'roto'), throwsA(anything));
    expect(tmps(), isEmpty);
    expect(File('${destino.path}/dentro.txt').readAsStringSync(), 'x');
  });

  test('una escritura fallida no frena a las siguientes del mismo archivo',
      () async {
    final f = File('${dir.path}/datos.json');
    final mala = escribirAtomico(File('${dir.path}/no/existe/x.json'), 'a');
    final buena = escribirAtomico(f, 'bien');
    await expectLater(mala, throwsA(anything));
    await buena;
    expect(f.readAsStringSync(), 'bien');
  });

  test('escrituras simultaneas al mismo archivo: contenido valido, sin errores',
      () async {
    final f = File('${dir.path}/muestras.json');
    for (var ronda = 0; ronda < 20; ronda++) {
      final chico = jsonEncode({'n': 'a', 'x': 'a' * 10});
      final grande = jsonEncode({'n': 'b', 'x': 'b' * 200000});
      // Sin await entre las dos: se superponen.
      await Future.wait([
        escribirAtomico(f, chico),
        escribirAtomico(f, grande),
        escribirAtomico(f, chico),
      ]);
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      // Gana la ultima en llamar, completa.
      expect(j['n'], 'a');
      expect(tmps(), isEmpty);
    }
  });

  test('archivos distintos no se esperan entre si', () async {
    final a = File('${dir.path}/a.json');
    final b = File('${dir.path}/b.json');
    await Future.wait([escribirAtomico(a, 'A'), escribirAtomico(b, 'B')]);
    expect(a.readAsStringSync(), 'A');
    expect(b.readAsStringSync(), 'B');
  });

  test('version de bytes', () async {
    final f = File('${dir.path}/raw.json.gz');
    await escribirAtomicoBytes(f, [1, 2, 3]);
    expect(f.readAsBytesSync(), [1, 2, 3]);
    expect(tmps(), isEmpty);
  });

  group('barrerTmpHuerfanos', () {
    File tmp(String nombre, Duration antiguedad) {
      final f = File('${dir.path}/$nombre')..writeAsStringSync('x');
      f.setLastModifiedSync(DateTime.now().subtract(antiguedad));
      return f;
    }

    test('borra los .tmp viejos, respeta los recientes y los demas archivos',
        () async {
      final viejo = tmp('muestras_locales.json.123.4.tmp', const Duration(minutes: 5));
      final viejoLegacy = tmp('perfil.json.tmp', const Duration(hours: 1));
      final reciente = tmp('otro.json.123.5.tmp', const Duration(seconds: 5));
      final dato = tmp('muestras_locales.json', const Duration(days: 3));
      final borrados = await barrerTmpHuerfanos(dir);
      expect(borrados, 2);
      expect(viejo.existsSync(), isFalse);
      expect(viejoLegacy.existsSync(), isFalse);
      expect(reciente.existsSync(), isTrue);
      expect(dato.existsSync(), isTrue);
    });

    test('carpeta inexistente: 0 y sin lanzar', () async {
      expect(await barrerTmpHuerfanos(Directory('${dir.path}/no_existe')), 0);
    });
  });
}
