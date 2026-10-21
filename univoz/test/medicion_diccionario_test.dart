// Medicion de memoria del diccionario de 541 senas (51 MB de JSON).
//
// No corre en la bateria normal: es una herramienta para comparar antes y
// despues de tocar la carga. Se activa con una variable de entorno:
//
//   cd univoz && MEDIR_DICCIONARIO=1 flutter test test/medicion_diccionario_test.dart
//
// Imprime el RSS del proceso (el isolate de compute() es del mismo proceso),
// el pico (maxRss) y una estimacion del tamano retenido que cuenta 8 bytes por
// valor en un Float64List y ~24 (puntero + double en caja) en una lista normal.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:senas_core/dtw.dart';
import 'package:senas_core/plantillas.dart';

int _bytesLista(List<List<double>> l) {
  var b = 0;
  for (final f in l) {
    b += f is Float64List ? f.length * 8 + 16 : f.length * 24 + 16;
  }
  return b + l.length * 8 + 16;
}

String _mb(num bytes) => (bytes / (1024 * 1024)).toStringAsFixed(0);

void main() {
  final activa = Platform.environment['MEDIR_DICCIONARIO'] == '1';

  test('memoria retenida por cargarDiccionario', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final rss0 = ProcessInfo.currentRss;
    final sw = Stopwatch()..start();
    final d1 = await cargarDiccionario();
    final t1 = sw.elapsedMilliseconds;
    final rss1 = ProcessInfo.currentRss;
    final pico1 = ProcessInfo.maxRss;

    var seq = 0, cseq = 0, segs = 0;
    for (final Template t in d1.clasificador.templates) {
      if (t.guardaSeq) seq += _bytesLista(t.seq);
      cseq += _bytesLista(t.cseq);
      segs += _bytesLista(t.segs);
    }
    var apr = 0;
    for (final Template t in d1.aprendizaje) {
      apr += _bytesLista(t.seq) + _bytesLista(t.cseq) + _bytesLista(t.segs);
    }

    sw.reset();
    final d2 = await cargarDiccionario();
    final t2 = sw.elapsedMilliseconds;
    final rss2 = ProcessInfo.currentRss;
    final pico2 = ProcessInfo.maxRss;

    // ignore: avoid_print
    print('''
=== MEDICION DICCIONARIO ===
plantillas clasificador: ${d1.clasificador.templates.length}  aprendizaje: ${d1.aprendizaje.length}
RSS inicial:               ${_mb(rss0)} MB
1a carga:  $t1 ms   RSS ${_mb(rss1)} MB (+${_mb(rss1 - rss0)})   pico maxRss ${_mb(pico1)} MB
2a carga:  $t2 ms   RSS ${_mb(rss2)} MB (+${_mb(rss2 - rss1)} sobre la 1a)   pico maxRss ${_mb(pico2)} MB
misma instancia en la 2a carga: ${identical(d1, d2)}
estimado retenido (clasificador): seq ${_mb(seq)} MB, cseq ${_mb(cseq)} MB, segs ${_mb(segs)} MB
estimado retenido (aprendizaje):  ${_mb(apr)} MB
estimado total por Diccionario:   ${_mb(seq + cseq + segs + apr)} MB
''');
  }, skip: !activa, timeout: const Timeout(Duration(minutes: 5)));
}
