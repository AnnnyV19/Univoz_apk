import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:test/test.dart';

import 'package:senas_core/registro_errores.dart';

void main() {
  late Directory dir;
  late RegistroErrores registro;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('errores_');
    registro = RegistroErrores(directorio: () async => dir, maxBytes: 2000);
    addTearDown(registro.volcar);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  StackTrace pila(int lineas) => StackTrace.fromString(
      List.generate(lineas, (i) => '#$i      funcion$i (archivo.dart:$i:1)')
          .join('\n'));

  test('agrega una linea JSON con hora, error y pila', () async {
    await registro.registrar(StateError('algo'), pila(3),
        ahora: DateTime.utc(2026, 10, 20, 12));
    await registro.volcar();
    final lineas = File('${dir.path}/errores.jsonl').readAsLinesSync();
    expect(lineas, hasLength(1));
    final j = jsonDecode(lineas.single) as Map<String, dynamic>;
    expect(j['t'], '2026-10-20T12:00:00.000Z');
    expect(j['error'], contains('algo'));
    expect(j['stack'], contains('funcion0'));
  });

  test('la primera vez queda en disco al instante, sin esperar la ventana',
      () async {
    // Ni volcar() ni esperar: ventana de 10 s por defecto.
    await registro.registrar(StateError('primero'), pila(2));
    final lineas = File('${dir.path}/errores.jsonl').readAsLinesSync();
    expect(lineas, hasLength(1));
    expect((jsonDecode(lineas.single) as Map)['repeticiones'], 1);
    await registro.volcar();
    // Sin repeticiones no hay resumen.
    expect(File('${dir.path}/errores.jsonl').readAsLinesSync(), hasLength(1));
  });

  test('la pila se corta a 20 lineas', () async {
    await registro.registrar(Exception('x'), pila(50));
    await registro.volcar();
    final j = jsonDecode(File('${dir.path}/errores.jsonl').readAsLinesSync().single)
        as Map<String, dynamic>;
    final lineas = (j['stack'] as String).split('\n');
    expect(lineas, hasLength(20));
    expect(lineas.last, contains('funcion19'));
  });

  test('acumula varias lineas', () async {
    await registro.registrar('a', null);
    await registro.registrar('b', null);
    await registro.volcar();
    expect(File('${dir.path}/errores.jsonl').readAsLinesSync(), hasLength(2));
  });

  test('al pasar el tope rota a errores.jsonl.1', () async {
    for (var i = 0; i < 30; i++) {
      await registro.registrar('error numero $i ' + 'x' * 100, pila(2));
      await registro.volcar();
    }
    final actual = File('${dir.path}/errores.jsonl');
    final vieja = File('${dir.path}/errores.jsonl.1');
    expect(vieja.existsSync(), isTrue);
    expect(actual.lengthSync(), lessThanOrEqualTo(2000 + 600));
    // Solo hay una generacion vieja, no se acumulan.
    expect(dir.listSync(), hasLength(2));
    // La ultima entrada esta en el actual.
    expect(actual.readAsStringSync(), contains('error numero 29'));
  });

  test('un error enorme se trunca y nunca lanza', () async {
    await registro.registrar('y' * 100000, null);
    await registro.volcar();
    final j = jsonDecode(File('${dir.path}/errores.jsonl').readAsLinesSync().single)
        as Map<String, dynamic>;
    expect((j['error'] as String).length, lessThan(3000));
  });

  test('si no puede escribir, se traga el fallo', () async {
    final roto = RegistroErrores(
        directorio: () async => throw const FileSystemException('sin disco'));
    await roto.registrar('x', null);
    await roto.volcar(); // no debe lanzar
  });

  test('archivoParaCompartir: null sin errores, el archivo si hay', () async {
    expect(await registro.archivoParaCompartir(), isNull);
    await registro.registrar('x', null);
    final f = await registro.archivoParaCompartir();
    expect(f?.path, '${dir.path}/errores.jsonl');
  });

  group('errores repetidos', () {
    test('1000 errores iguales: la primera completa + UN resumen', () async {
      for (var i = 0; i < 1000; i++) {
        await registro.registrar(StateError('pinta mal'), pila(5));
      }
      await registro.volcar();
      final lineas = File('${dir.path}/errores.jsonl')
          .readAsLinesSync()
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .toList();
      expect(lineas, hasLength(2));
      expect(lineas[0]['repeticiones'], 1);
      expect(lineas[0]['stack'], contains('funcion0'));
      expect(lineas[1]['repeticiones'], 1000);
      expect(lineas[1]['resumen'], isTrue);
      expect(lineas[1].containsKey('stack'), isFalse);
    });

    test('distinto mensaje o distinta pila son entradas distintas', () async {
      await registro.registrar(StateError('a'), pila(3));
      await registro.registrar(StateError('b'), pila(3));
      await registro.registrar(StateError('a'), StackTrace.fromString('#0 otra (x.dart:1:1)'));
      await registro.volcar();
      expect(File('${dir.path}/errores.jsonl').readAsLinesSync(), hasLength(3));
      expect(
          File('${dir.path}/errores.jsonl')
              .readAsLinesSync()
              .map((l) => (jsonDecode(l) as Map)['repeticiones']),
          everyElement(1));
    });

    test('pasada la ventana se escribe sola y el siguiente abre otra entrada',
        () async {
      final corto = RegistroErrores(
          directorio: () async => dir,
          ventana: const Duration(milliseconds: 40));
      await corto.registrar(StateError('x'), pila(2));
      await corto.registrar(StateError('x'), pila(2));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await corto.registrar(StateError('x'), pila(2));
      await corto.volcar();
      final lineas = File('${dir.path}/errores.jsonl')
          .readAsLinesSync()
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .toList();
      // primera, resumen al cerrar la ventana, y primera de la ventana nueva.
      expect(lineas.map((j) => j['repeticiones']), [1, 2, 1]);
      expect(lineas.map((j) => j['resumen']), [null, true, null]);
    });

    test('errores distintos sin parar no acumulan una cola infinita',
        () async {
      var llamadas = 0;
      final lento = RegistroErrores(directorio: () async {
        llamadas++;
        await Future<void>.delayed(const Duration(milliseconds: 2));
        return dir;
      });
      for (var i = 0; i < 1000; i++) {
        // Sin esperar: asi llegan en la app (unawaited desde onError).
        unawaited(lento.registrar('error $i', null));
      }
      await lento.volcar();
      expect(llamadas, lessThan(300));
      final lineas = File('${dir.path}/errores.jsonl').readAsLinesSync();
      expect(lineas, isNotEmpty);
      expect(lineas.length, lessThan(300));
    });
  });

  test('al pasar a segundo plano se escriben los resumenes pendientes',
      () async {
    final obs = ObservadorRegistroErrores(registro);
    for (var i = 0; i < 4; i++) {
      await registro.registrar(StateError('repite'), pila(2));
    }
    // Primera vez en disco; el resumen espera a la ventana.
    expect(File('${dir.path}/errores.jsonl').readAsLinesSync(), hasLength(1));
    obs.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(File('${dir.path}/errores.jsonl').readAsLinesSync(), hasLength(1));
    obs.didChangeAppLifecycleState(AppLifecycleState.paused);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final lineas = File('${dir.path}/errores.jsonl').readAsLinesSync();
    expect(lineas, hasLength(2));
    expect((jsonDecode(lineas.last) as Map)['repeticiones'], 4);
  });

  test('un error cuyo toString lanza no rompe el registro', () async {
    await registro.registrar(_Malo(), null);
    await registro.volcar();
    final j = jsonDecode(File('${dir.path}/errores.jsonl').readAsLinesSync().single)
        as Map<String, dynamic>;
    expect(j['error'], contains('toString'));
  });
}

class _Malo {
  @override
  String toString() => throw StateError('no se puede');
}
