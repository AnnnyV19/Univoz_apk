import 'dart:io';

import 'package:test/test.dart';

import 'package:senas_core/rotacion_sesiones.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('sesiones_'));
  tearDown(() => dir.deleteSync(recursive: true));

  // Ids de sesion ordenables: el sello va primero.
  File crear(int n, {int bytes = 10}) {
    final id = '2026010${n ~/ 10}T0000${(n % 10)}0Z-abcdef';
    return File('${dir.path}/$id.jsonl')..writeAsBytesSync(List.filled(bytes, 65));
  }

  List<String> quedan() => (dir.listSync().map((e) => e.uri.pathSegments.last).toList()
    ..sort());

  test('dentro de los limites no borra nada', () async {
    for (var i = 0; i < 5; i++) {
      crear(i);
    }
    expect(await podarSesiones(dir), 0);
    expect(quedan(), hasLength(5));
  });

  test('conserva solo los N archivos mas recientes', () async {
    for (var i = 0; i < 12; i++) {
      crear(i);
    }
    final borrados = await podarSesiones(dir, maxArchivos: 5);
    expect(borrados, 7);
    final restantes = quedan();
    expect(restantes, hasLength(5));
    // Sobreviven los 5 mas nuevos (7 a 11); el mas viejo ya no esta.
    expect(restantes.first, startsWith('20260100T000070Z'));
    expect(restantes.last, startsWith('20260101T000010Z'));
  });

  test('con el limite por defecto deja 30', () async {
    for (var i = 0; i < 40; i++) {
      crear(i);
    }
    await podarSesiones(dir);
    expect(quedan(), hasLength(kMaxArchivosSesion));
  });

  test('respeta el tope de bytes borrando primero los mas viejos', () async {
    for (var i = 0; i < 6; i++) {
      crear(i, bytes: 100);
    }
    await podarSesiones(dir, maxBytes: 250);
    final restantes = quedan();
    expect(restantes, hasLength(2)); // 2 * 100 <= 250 < 3 * 100
    expect(restantes.first, startsWith('20260100T000040Z'));
  });

  test('nunca borra la sesion mas nueva, aunque sola pase el tope', () async {
    crear(0, bytes: 500);
    await podarSesiones(dir, maxBytes: 100, maxArchivos: 0);
    expect(quedan(), hasLength(1));

    crear(1, bytes: 500);
    await podarSesiones(dir, maxBytes: 100, maxArchivos: 0);
    expect(quedan(), ['20260100T000010Z-abcdef.jsonl']);
  });

  test('respeta los nombres de conservar', () async {
    for (var i = 0; i < 4; i++) {
      crear(i);
    }
    await podarSesiones(dir,
        maxArchivos: 1, conservar: {'20260100T000000Z-abcdef.jsonl'});
    expect(quedan(), [
      '20260100T000000Z-abcdef.jsonl',
      '20260100T000030Z-abcdef.jsonl',
    ]);
  });

  test('ignora lo que no es .jsonl y carpetas inexistentes', () async {
    File('${dir.path}/nota.txt').writeAsStringSync('x');
    crear(1);
    await podarSesiones(dir, maxArchivos: 0);
    // La unica sesion es la mas nueva: se conserva; nota.txt ni se mira.
    expect(quedan(), ['20260100T000010Z-abcdef.jsonl', 'nota.txt']);
    expect(await podarSesiones(Directory('${dir.path}/no_existe')), 0);
  });

  test('los topes por defecto son 50 MB y 30 archivos', () {
    expect(kMaxBytesSesiones, 50 * 1024 * 1024);
    expect(kMaxArchivosSesion, 30);
  });

  test('cada sesion nueva poda antes de abrir su archivo', () {
    final fuente = File('lib/sesion_automatica.dart').readAsStringSync();
    final poda = fuente.indexOf('podarSesiones(');
    final abre = fuente.indexOf('sumideroArchivo(dirSesiones)');
    expect(poda, isNonNegative);
    expect(abre, greaterThan(poda));
  });

  group('partesDeUltimaSesion', () {
    File archivo(String nombre) =>
        File('${dir.path}/$nombre')..writeAsStringSync('x');

    List<String> nombres(List<File> fs) =>
        [for (final f in fs) f.uri.pathSegments.last];

    test('devuelve todas las partes de la ultima sesion en orden', () async {
      archivo('20260101T000000Z-aaaaaa.jsonl');
      archivo('20260102T000000Z-bbbbbb.part003.jsonl');
      archivo('20260102T000000Z-bbbbbb.jsonl');
      archivo('20260102T000000Z-bbbbbb.part002.jsonl');
      archivo('nota.txt');
      expect(nombres(await partesDeUltimaSesion(dir)), [
        '20260102T000000Z-bbbbbb.jsonl',
        '20260102T000000Z-bbbbbb.part002.jsonl',
        '20260102T000000Z-bbbbbb.part003.jsonl',
      ]);
    });

    test('una sesion sin partes es solo su archivo', () async {
      archivo('20260101T000000Z-aaaaaa.jsonl');
      expect(nombres(await partesDeUltimaSesion(dir)),
          ['20260101T000000Z-aaaaaa.jsonl']);
    });

    test('sin sesiones o sin carpeta devuelve vacio', () async {
      expect(await partesDeUltimaSesion(dir), isEmpty);
      expect(await partesDeUltimaSesion(Directory('${dir.path}/no')), isEmpty);
    });

    test('nombreDeSesion separa id y parte', () {
      expect(nombreDeSesion('a-b.jsonl'), (id: 'a-b', parte: 1));
      expect(nombreDeSesion('a-b.part012.jsonl'), (id: 'a-b', parte: 12));
      expect(nombreDeSesion('nota.txt'), isNull);
    });
  });
}
