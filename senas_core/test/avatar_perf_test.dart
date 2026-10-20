import 'package:flutter_test/flutter_test.dart';

import 'package:senas_core/avatar_bridge.dart';

void main() {
  test('decodificarPerf devuelve el objeto del visor', () {
    final perf = decodificarPerf(
        'perf:{"latency_ms":[30.5],"fps":{"render":30},"tier":"bajo"}');
    expect(perf, isNotNull);
    expect(perf!['tier'], 'bajo');
    expect((perf['fps'] as Map)['render'], 30);
  });

  test('decodificarPerf ignora mensajes corruptos o que no son objeto', () {
    expect(decodificarPerf('perf:{roto'), isNull);
    expect(decodificarPerf('perf:[1,2]'), isNull);
    expect(decodificarPerf('perf:'), isNull);
    expect(decodificarPerf('fin'), isNull);
  });

  test('decodificarMovimiento lee el quieto/movimiento del visor', () {
    final m = decodificarMovimiento(
        'motion:{"t":1234,"m":1,"s":0.91,"f":0.2,"h":true}');
    expect(m, isNotNull);
    expect(m!.timestampMs, 1234);
    expect(m.hayMovimiento, isTrue);
    expect(m.puntaje, closeTo(.91, 1e-9));
    expect(m.dedos, closeTo(.2, 1e-9));
    final quieto = decodificarMovimiento('motion:{"t":5,"m":0,"h":false}');
    expect(quieto!.hayMovimiento, isFalse);
  });

  test('decodificarMovimiento ignora mensajes rotos', () {
    expect(decodificarMovimiento('motion:{roto'), isNull);
    expect(decodificarMovimiento('motion:{"m":1}'), isNull); // sin tiempo
    expect(decodificarMovimiento('perf:{"t":1,"m":1}'), isNull);
  });
}
