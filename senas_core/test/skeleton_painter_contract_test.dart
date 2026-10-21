import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('preview Flutter descarta landmarks fuera de cuadro', () {
    final source = File('lib/skeleton_painter.dart').readAsStringSync();

    expect(source, contains('bool _puntoEnCuadro'));
    expect(source, contains('p[0].isFinite'));
    expect(source, contains('p[1].isFinite'));
    expect(source, contains('p[0] >= 0'));
    expect(source, contains('p[0] <= 1'));
    expect(source, contains('p[1] >= 0'));
    expect(source, contains('p[1] <= 1'));
    expect(source, contains('!_puntoEnCuadro(pa)'));
    expect(source, contains('!_puntoEnCuadro(p)'));
  });

  test('preview Flutter conserva perspectiva anatomica sin espejo', () {
    final espejo = File('lib/pantalla_espejo.dart').readAsStringSync();
    final captura = File('lib/pantalla_captura.dart').readAsStringSync();
    final traduccion = File('lib/skeleton_painter.dart').readAsStringSync();

    expect(espejo, isNot(contains('Matrix4.diagonal3Values')));
    expect(captura, isNot(contains('Matrix4.diagonal3Values')));
    expect(traduccion, isNot(contains('Matrix4.diagonal3Values')));
    expect(espejo, isNot(contains('camara.espejo')));
    expect(captura, isNot(contains('camara.espejo')));
    expect(traduccion, isNot(contains('camara.espejo')));
  });

  test('Traducir usa el avatar y el movimiento adaptativo del visor web', () {
    final source = File('lib/skeleton_painter.dart').readAsStringSync();
    final traducir =
        source.substring(source.indexOf('class _PantallaDeTranslacionState'));
    // Avatar con los frames fusionados, igual que Espejo.
    expect(traducir, contains('AlimentadorAvatar('));
    expect(traducir, contains('.listen(_alimentador.alFrame, onError: _errorStream)'));
    // Inicio y fin de la seña con el quieto/movimiento del visor.
    expect(traducir, contains('configurarMovimiento(true)'));
    expect(traducir, contains('onMovimiento'));
    expect(traducir, contains('_fuente.alMovimientoVisor('));
    expect(traducir, contains('_bridge.estado.addListener(_alCambiarEstadoVisor)'));
    // WebView y Texture lado a lado: encima, el WebView tapa la cámara. El
    // acomodo vive en DisposicionReconocer: filas y columnas, ningun Stack
    // que encime la camara sobre el avatar.
    expect(traducir, contains('VistaAvatar('));
    expect(traducir, contains('DisposicionReconocer('));
    final disposicion =
        File('lib/reconocer/disposicion_reconocer.dart').readAsStringSync();
    expect(disposicion, contains('LayoutBuilder('));
    expect(disposicion, isNot(contains('Stack(')));
    expect(disposicion, isNot(contains('Positioned(')));
    final contenido = traducir.substring(
        traducir.indexOf('Widget _contenido('),
        traducir.indexOf('Widget _errorCamara('));
    expect(contenido, isNot(contains('Stack(')));
    // Rendimiento y fluidez de Android a la sesión.
    expect(traducir, contains("_ctrl.sesion?.evento('perf', perf)"));
    // Sin pose usable el visor no recibe frames ni manda motion: el preview
    // sin mano o sin pose cuenta como quieto para no colgar la grabación.
    expect(traducir, contains('_fuente.alPreviewSinMano(f)'));
    final controlador =
        File('lib/controlador_captura.dart').readAsStringSync();
    expect(controlador,
        contains('!f.tieneAlgunaMano || normalizarCacheado(f) == null'));
  });

  test('Traducir reconoce con un solo DTW y corta la sena con pre-roll y cola',
      () {
    final source = File('lib/skeleton_painter.dart').readAsStringSync();
    final traducir =
        source.substring(source.indexOf('class _PantallaDeTranslacionState'));
    expect('.rank('.allMatches(traducir).length, 1,
        reason: 'un solo ranking DTW por intento');
    expect(traducir, contains('classifyRanking(ranking)'));
    expect(traducir, isNot(contains('.classify(seq)')));
    expect(traducir, contains('_ctrl.empezar(preRollMs: kPreRollMs)'));
    expect(traducir, contains('hastaMs:'));
    expect(traducir, contains('_detector.ultimoMovimientoMs'));
    expect(traducir, contains("evento('reconocimiento'"));
    expect(traducir, contains("pistaParaResultado('muy_corta')"));
    // El DTW se mide y queda en el evento de la sesion.
    expect(traducir, contains("'dtw_ms'"));
    expect(traducir, isNot(contains('exportar_paquete')));
    // Al limpiar por intento invalido, una respuesta tardia del backend no
    // repuebla; la pista se quita al cambiar de modo y al empezar otra sena.
    expect(traducir, contains('_consultaBackend++;'));
    expect('_pista.limpiar()'.allMatches(traducir).length, greaterThanOrEqualTo(3));
  });
}
