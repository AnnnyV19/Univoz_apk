import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'package:senas_core/red.dart';

const _sinEspera = Duration.zero;

void main() {
  group('redGet', () {
    test('reintenta una vez si la primera falla por red', () async {
      var llamadas = 0;
      final cliente = MockClient((_) async {
        llamadas++;
        if (llamadas == 1) throw http.ClientException('Connection reset');
        return http.Response('ok', 200);
      });
      final r = await redGet(cliente, Uri.parse('https://x.test/a'),
          espera: _sinEspera);
      expect(r.body, 'ok');
      expect(llamadas, 2);
    });

    test('reintenta una vez ante un 5xx y devuelve el resultado', () async {
      var llamadas = 0;
      final cliente = MockClient((_) async {
        llamadas++;
        return llamadas == 1
            ? http.Response('boom', 503)
            : http.Response('ok', 200);
      });
      final r = await redGet(cliente, Uri.parse('https://x.test/a'),
          espera: _sinEspera);
      expect(r.statusCode, 200);
      expect(llamadas, 2);
    });

    test('solo un reintento: si vuelve a fallar lanza FalloRed', () async {
      var llamadas = 0;
      final cliente = MockClient((_) async {
        llamadas++;
        throw const SocketException('sin red');
      });
      await expectLater(
        redGet(cliente, Uri.parse('https://x.test/a'), espera: _sinEspera),
        throwsA(isA<FalloRed>().having((e) => e.mensaje, 'mensaje',
            'Sin conexión. Revisa tu internet e inténtalo de nuevo.')),
      );
      expect(llamadas, 2);
    });

    test('un 4xx no se reintenta y se devuelve tal cual', () async {
      var llamadas = 0;
      final cliente = MockClient((_) async {
        llamadas++;
        return http.Response('no', 403);
      });
      final r = await redGet(cliente, Uri.parse('https://x.test/a'),
          espera: _sinEspera);
      expect(r.statusCode, 403);
      expect(llamadas, 1);
    });

    test('un 5xx persistente se devuelve para que el llamador lo traduzca',
        () async {
      var llamadas = 0;
      final cliente = MockClient((_) async {
        llamadas++;
        return http.Response('SQLSTATE=XX000', 500);
      });
      final r = await redGet(cliente, Uri.parse('https://x.test/a'),
          espera: _sinEspera);
      expect(r.statusCode, 500);
      expect(llamadas, 2);
    });

    test('el timeout se traduce a un mensaje humano (tras reintentar)',
        () async {
      var llamadas = 0;
      final cliente = MockClient((_) async {
        llamadas++;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return http.Response('tarde', 200);
      });
      await expectLater(
        redGet(cliente, Uri.parse('https://x.test/a'),
            timeout: const Duration(milliseconds: 20), espera: _sinEspera),
        throwsA(isA<FalloRed>().having((e) => e.mensaje, 'mensaje',
            'El servidor tardó demasiado. Inténtalo más tarde.')),
      );
      expect(llamadas, 2);
    });

    test('espera el backoff entre intentos', () async {
      var llamadas = 0;
      final cliente = MockClient((_) async {
        llamadas++;
        if (llamadas == 1) throw http.ClientException('x');
        return http.Response('ok', 200);
      });
      final reloj = Stopwatch()..start();
      await redGet(cliente, Uri.parse('https://x.test/a'),
          espera: const Duration(milliseconds: 150));
      expect(reloj.elapsedMilliseconds, greaterThanOrEqualTo(140));
    });
  });

  group('redPost', () {
    test('NO reintenta: un POST no es idempotente', () async {
      var llamadas = 0;
      final cliente = MockClient((_) async {
        llamadas++;
        throw http.ClientException('cortado');
      });
      await expectLater(
        redPost(cliente, Uri.parse('https://x.test/a'), body: '{}'),
        throwsA(isA<FalloRed>()),
      );
      expect(llamadas, 1);
    });

    test('un 5xx en POST se devuelve sin reintentar', () async {
      var llamadas = 0;
      final cliente = MockClient((_) async {
        llamadas++;
        return http.Response('x', 502);
      });
      final r = await redPost(cliente, Uri.parse('https://x.test/a'));
      expect(r.statusCode, 502);
      expect(llamadas, 1);
    });

    test('respeta el timeout propio (subidas largas)', () async {
      final cliente = MockClient((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return http.Response('', 200);
      });
      await expectLater(
        redPost(cliente, Uri.parse('https://x.test/a'),
            timeout: const Duration(milliseconds: 20)),
        throwsA(isA<FalloRed>().having(
            (e) => e.mensaje, 'mensaje', contains('tardó demasiado'))),
      );
    });
  });

  group('mensajes', () {
    test('valores por defecto: 10 s y 30 s para subidas', () {
      expect(kTimeoutRed, const Duration(seconds: 10));
      expect(kTimeoutSubida, const Duration(seconds: 30));
      expect(kEsperaReintento, const Duration(milliseconds: 800));
    });

    test('estados HTTP a mensajes humanos', () {
      expect(mensajeDeEstado(401), 'No tienes permiso para esta acción.');
      expect(mensajeDeEstado(403), 'No tienes permiso para esta acción.');
      expect(mensajeDeEstado(500),
          'El servidor tuvo un problema. Inténtalo más tarde.');
      expect(mensajeDeEstado(503),
          'El servidor tuvo un problema. Inténtalo más tarde.');
      expect(mensajeDeEstado(404), isNot(contains('404')));
    });

    test('mensajeHumano nunca filtra el error crudo a una persona normal',
        () {
      const crudo = 'SocketException: OS Error: Connection refused, errno = 111, '
          'address = 10.0.0.5';
      expect(mensajeHumano(const SocketException(crudo)),
          'Sin conexión. Revisa tu internet e inténtalo de nuevo.');
      expect(mensajeHumano(TimeoutException('x')),
          'El servidor tardó demasiado. Inténtalo más tarde.');
      final raro = mensajeHumano(StateError('stack interno'));
      expect(raro, isNot(contains('stack interno')));
      expect(raro, 'Algo salió mal. Inténtalo de nuevo.');
    });

    test('mensajeHumano en modo desarrollador conserva el detalle', () {
      expect(mensajeHumano(StateError('stack interno'), dev: true),
          contains('stack interno'));
      final f = falloDeExcepcion(const SocketException('errno 111'));
      expect(mensajeHumano(f, dev: true), contains('errno 111'));
      expect(mensajeHumano(f), isNot(contains('errno')));
    });
  });
}
