import 'dart:io';

import 'package:flutter/services.dart' show ByteData;
import 'package:flutter_test/flutter_test.dart';
import 'package:senas_core/avatar_bridge.dart';
import 'package:senas_core/frase_a_senas.dart' show SegmentoFrase;

void main() {
  group('llamadaSegura', () {
    test('no llama una funcion que el visor todavia no definio', () {
      expect(llamadaSegura('configurarVista', "'espejo'"),
          "window.configurarVista && window.configurarVista('espejo')");
      expect(
          llamadaSegura('iniciarCalibracionPulgares'),
          'window.iniciarCalibracionPulgares && '
          'window.iniciarCalibracionPulgares()');
    });
  });

  group('ColaPuenteAvatar', () {
    test('antes de js_listo no produce JS ni acepta frames', () {
      final cola = ColaPuenteAvatar();
      expect(cola.listo, isFalse);
      expect(cola.vista(espejo: true), isNull);
      expect(cola.manos(izquierda: false, derecha: true), isNull);
      expect(cola.aceptaFrames, isFalse);
    });

    test('al cargar el avatar reaplica lo ultimo pedido (gana el mas nuevo)',
        () {
      final cola = ColaPuenteAvatar()
        ..vista(espejo: true)
        ..vista(espejo: false)
        ..manos(izquierda: false, derecha: true)
        ..manos(izquierda: true, derecha: false);
      cola.marcarListo();
      expect(cola.listo, isTrue);
      expect(cola.aceptaFrames, isTrue);
      expect(cola.llamadasAlCargar(), [
        "window.configurarVista && window.configurarVista('interlocutor')",
        'window.configurarManos && window.configurarManos(true, false)',
      ]);
    });

    test('sin pedidos previos no reaplica nada', () {
      final cola = ColaPuenteAvatar()..marcarListo();
      expect(cola.llamadasAlCargar(), isEmpty);
    });

    test('ya listo, cada pedido produce su JS defensivo al instante', () {
      final cola = ColaPuenteAvatar()..marcarListo();
      expect(cola.vista(espejo: true),
          "window.configurarVista && window.configurarVista('espejo')");
      expect(cola.manos(izquierda: true, derecha: true),
          'window.configurarManos && window.configurarManos(true, true)');
    });

    test('el encuadre pedido antes de js_listo se reaplica al cargar', () {
      final cola = ColaPuenteAvatar()
        ..vista(espejo: false)
        ..encuadre(AvatarBridge.encuadreCodos)
        ..encuadre(AvatarBridge.encuadreCintura)
        ..encuadre(AvatarBridge.encuadreCodos);
      cola.marcarListo();
      expect(cola.llamadasAlCargar(), [
        "window.configurarVista && window.configurarVista('interlocutor')",
        "window.encuadrarCamara && window.encuadrarCamara('codos')",
      ]);
      // Ya listo: produce su JS defensivo al instante.
      expect(cola.encuadre(AvatarBridge.encuadreCintura),
          "window.encuadrarCamara && window.encuadrarCamara('cintura')");
    });

    test('al recargar vuelve a esperar y conserva los valores', () {
      final cola = ColaPuenteAvatar()
        ..marcarListo()
        ..vista(espejo: true);
      cola.reiniciar();
      expect(cola.listo, isFalse);
      expect(cola.aceptaFrames, isFalse);
      expect(cola.manos(izquierda: false, derecha: false), isNull);
      cola.marcarListo();
      expect(cola.llamadasAlCargar(), [
        "window.configurarVista && window.configurarVista('espejo')",
        'window.configurarManos && window.configurarManos(false, false)',
      ]);
    });
  });

  group('AvatarBridge.encuadrar y reproducirFrase (aporte de app-limpia)', () {
    List<List<double>> seq() => [
          for (var i = 0; i < 32; i++) List<double>.filled(152, 0.0),
        ];

    testWidgets('encuadrar se encola hasta js_listo y luego va directo',
        (tester) async {
      final js = <String>[];
      final bridge = AvatarBridge.sinVisor(
        ejecutar: (c) async => js.add(c),
        modelo: () async => ByteData(4),
      );
      await bridge.encuadrar(AvatarBridge.encuadreCodos);
      expect(js, isEmpty);
      bridge.simularMensaje('js_listo');
      await tester.pump();
      const codos =
          "window.encuadrarCamara && window.encuadrarCamara('codos')";
      expect(js, contains(codos));
      js.clear();
      await bridge.encuadrar('cualquier-cosa'); // modo raro: cae a cintura
      expect(js.single,
          "window.encuadrarCamara && window.encuadrarCamara('cintura')");
      bridge.dispose();
    });

    testWidgets('reproducirFrase valida 32x152 y manda JSON defensivo',
        (tester) async {
      final js = <String>[];
      final bridge = AvatarBridge.sinVisor(ejecutar: (c) async => js.add(c));
      await bridge.reproducirFrase([SegmentoFrase(seq(), 30)]);
      expect(js.single, startsWith('window.reproducirFrase && '));
      expect(js.single, contains("'2.0.0'"));
      await expectLater(
        bridge.reproducirFrase([SegmentoFrase(seq().sublist(1), 30)]),
        throwsA(anything),
      );
      await bridge.reproducirFrase(const []); // vacia: no hace nada
      expect(js, hasLength(1));
      bridge.dispose();
    });
  });

  group('AvatarBridge.sinVisor', () {
    test('arranca cargando y descarta frames antes de js_listo', () async {
      final bridge = AvatarBridge.sinVisor();
      expect(bridge.estado.value, EstadoAvatar.cargando);
      expect(bridge.mensajeError, isNull);
      // Sin visor no hay WebView: no debe lanzar ni esperar nada.
      await bridge.mostrarFrame(List<double>.filled(152, 0));
      await bridge.configurarVista(espejo: true);
      bridge.dispose();
    });

    test('reintentar vuelve a cargando y limpia el motivo', () async {
      final bridge = AvatarBridge.sinVisor();
      bridge.estado.value = EstadoAvatar.error;
      await bridge.reintentar();
      expect(bridge.estado.value, EstadoAvatar.cargando);
      expect(bridge.mensajeError, isNull);
      bridge.dispose();
    });
  });

  group('AvatarBridge recarga y limite de carga', () {
    const vistaEspejo =
        "window.configurarVista && window.configurarVista('espejo')";
    const vistaInterlocutor =
        "window.configurarVista && window.configurarVista('interlocutor')";
    const manosSoloDerecha =
        'window.configurarManos && window.configurarManos(false, true)';

    testWidgets(
        'reintentar: ignora restos de la pagina vieja y reaplica lo ultimo',
        (tester) async {
      final js = <String>[];
      final bridge = AvatarBridge.sinVisor(
        ejecutar: (c) async => js.add(c),
        modelo: () async => ByteData(4),
      );
      await bridge.configurarVista(espejo: true);
      await bridge.configurarManos(izquierda: false, derecha: true);
      expect(js, isEmpty);
      bridge.simularMensaje('js_listo');
      await tester.pump();
      expect(js.first, startsWith('window.cargarAvatarBase64 && '));
      expect(js, containsAll([vistaEspejo, manosSoloDerecha]));
      bridge.simularMensaje('avatar_listo');
      expect(bridge.estado.value, EstadoAvatar.listo);

      await bridge.reintentar();
      js.clear();
      expect(bridge.estado.value, EstadoAvatar.cargando);
      // Pedido durante la recarga: se guarda, no se inyecta.
      await bridge.configurarVista(espejo: false);
      expect(js, isEmpty);
      // Mensajes viejos antes de onPageStarted: no cuentan.
      bridge.simularMensaje('avatar_listo');
      bridge.simularMensaje('avatar_error:viejo');
      bridge.simularMensaje('js_listo');
      await tester.pump();
      expect(bridge.estado.value, EstadoAvatar.cargando);
      expect(js, isEmpty);

      bridge.simularPaginaIniciada();
      // avatar_listo sin js_listo de esta carga tampoco cuenta.
      bridge.simularMensaje('avatar_listo');
      expect(bridge.estado.value, EstadoAvatar.cargando);
      bridge.simularMensaje('js_listo');
      await tester.pump();
      expect(js.first, startsWith('window.cargarAvatarBase64 && '));
      expect(
          js.where((c) => c.contains('configurarVista')), [vistaInterlocutor]);
      expect(js, contains(manosSoloDerecha));
      bridge.simularMensaje('avatar_listo');
      expect(bridge.estado.value, EstadoAvatar.listo);
      bridge.dispose();
    });

    testWidgets('sin respuesta en 45 s pasa a error por tiempo',
        (tester) async {
      final bridge = AvatarBridge.sinVisor();
      expect(AvatarBridge.limiteCarga, const Duration(seconds: 45));
      await tester.pump(const Duration(seconds: 44));
      expect(bridge.estado.value, EstadoAvatar.cargando);
      await tester.pump(const Duration(seconds: 1));
      expect(bridge.estado.value, EstadoAvatar.error);
      expect(bridge.mensajeError, 'El avatar tardó demasiado en cargar.');

      // Reintentar vuelve a dar 45 s completos.
      await bridge.reintentar();
      await tester.pump(const Duration(seconds: 44));
      expect(bridge.estado.value, EstadoAvatar.cargando);
      await tester.pump(const Duration(seconds: 1));
      expect(bridge.estado.value, EstadoAvatar.error);
      bridge.dispose();
    });

    testWidgets('listo a tiempo cancela el limite', (tester) async {
      final bridge = AvatarBridge.sinVisor(
        ejecutar: (_) async {},
        modelo: () async => ByteData(4),
      );
      bridge.simularMensaje('js_listo');
      await tester.pump();
      bridge.simularMensaje('avatar_listo');
      await tester.pump(const Duration(seconds: 90));
      expect(bridge.estado.value, EstadoAvatar.listo);
      bridge.dispose();
    });
  });

  group('motivoErrorAvatar', () {
    const generico = 'Ocurrió un problema al preparar el avatar. '
        'Toca Reintentar.';

    test('traduce fallos tecnicos a un motivo corto y humano', () {
      expect(motivoErrorAvatar('tiempo_agotado'),
          'El avatar tardó demasiado en cargar.');
      expect(motivoErrorAvatar('TypeError: x is undefined'), generico);
    });

    test('el visor es offline: nunca culpa a la conexion a internet', () {
      for (final detalle in [
        'net::ERR_INTERNET_DISCONNECTED',
        'sin_conexion',
        'arranque: fallo de conexión',
      ]) {
        final motivo = motivoErrorAvatar(detalle);
        expect(motivo, generico);
        expect(motivo.toLowerCase(), isNot(contains('internet')));
        expect(motivo.toLowerCase(), isNot(contains('conexión')));
      }
    });
  });

  test('visor: Script error. saneado no es fatal y avisa listo/error a Dart',
      () {
    final html = File('assets/avatar_viewer/index.html').readAsStringSync();
    expect(html,
        contains("evento.message === 'Script error.' && !evento.filename"));
    expect(html, contains('window.__visorArrancado = true;'));
    expect(html, contains("avisarDart('js_error:' + mensaje)"));
    expect(html, contains("window.SenasChannel.postMessage('avatar_listo')"));
    expect(html, contains("postMessage('avatar_error:' + msg)"));
  });

  test('visor: el cartel de arranque no muestra el error crudo a la persona',
      () {
    final html = File('assets/avatar_viewer/index.html').readAsStringSync();
    expect(
        html,
        contains("'Ocurrió un problema al preparar el avatar. "
            "Toca Reintentar.'"));
    expect(html, isNot(contains("'No se pudo cargar el avatar 3D ('")));
    // fallarAvatar manda el detalle a consola y a Dart, no al cartel.
    expect(html, contains('console.error(msg);\n      avisar('));
    expect(
        html, isNot(contains('avisar(msg);\n      if (window.SenasChannel)')));
  });
}
