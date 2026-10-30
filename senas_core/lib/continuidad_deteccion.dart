/// Resumen periodico de cuanto se sostiene la deteccion de MediaPipe, para
/// vigilar pruebas en vivo con `adb logcat` (linea `UNIVOZ_TRK`, solo con el
/// modo desarrollador) y comparar variantes de camara/modelo sin exportar la
/// sesion. Mide lo que llega a Dart: manos CRUDAS (`left`/`right`, las que
/// usa el reconocimiento), pose, cara y la visibilidad de las munecas.
library continuidad_deteccion;

import 'camera_bridge.dart' show LandmarkFrame;

class ResumenContinuidad {
  ResumenContinuidad({this.ventanaMs = 2000});

  final int ventanaMs;

  int? _inicioMs;
  int _n = 0;
  int _izq = 0, _der = 0, _alguna = 0, _pose = 0, _cara = 0;
  int _huecoActual = 0, _huecoMax = 0;
  double _visMunecas = 0;
  int _conVis = 0;
  final List<double> _infer = [];
  String _modo = '';
  String _tier = '';

  /// Alimenta un frame; devuelve la linea de la ventana que acaba de cerrarse
  /// (el frame que la cierra cuenta para la ventana siguiente), o null.
  String? alFrame(LandmarkFrame f) {
    String? linea;
    final inicio = _inicioMs;
    if (inicio == null) {
      _inicioMs = f.timestampMs;
    } else if (f.timestampMs - inicio >= ventanaMs) {
      linea = _cerrar(f.timestampMs - inicio);
      _reiniciar(f.timestampMs);
    }
    _n++;
    final izq = f.left != null, der = f.right != null;
    if (izq) _izq++;
    if (der) _der++;
    if (izq || der) {
      _alguna++;
      _huecoActual = 0;
    } else {
      _huecoActual++;
      if (_huecoActual > _huecoMax) _huecoMax = _huecoActual;
    }
    final pose = f.pose;
    if (pose != null) {
      _pose++;
      if (pose.length > 16) {
        _visMunecas += (pose[15][3] + pose[16][3]) / 2;
        _conVis++;
      }
    }
    if (f.face != null) _cara++;
    final infer = f.inferMs;
    if (infer != null) _infer.add(infer);
    _modo = f.captureMode;
    _tier = f.tier ?? '';
    return linea;
  }

  void _reiniciar(int t) {
    _inicioMs = t;
    _n = 0;
    _izq = _der = _alguna = _pose = _cara = 0;
    _huecoActual = _huecoMax = 0;
    _visMunecas = 0;
    _conVis = 0;
    _infer.clear();
  }

  String _cerrar(int duracionMs) {
    String pct(int x) => _n == 0 ? '0' : (100 * x / _n).round().toString();
    final orden = [..._infer]..sort();
    final p50 = orden.isEmpty ? '-' : orden[(orden.length - 1) ~/ 2].round();
    final vis = _conVis == 0 ? '-' : (_visMunecas / _conVis).toStringAsFixed(2);
    final fps = (_n * 1000 / duracionMs).toStringAsFixed(1);
    return 'UNIVOZ_TRK n=$_n fps=$fps izq=${pct(_izq)} der=${pct(_der)} '
        'alguna=${pct(_alguna)} hueco_max=$_huecoMax pose=${pct(_pose)} '
        'cara=${pct(_cara)} vis_mun=$vis infer_p50=$p50 modo=$_modo '
        'tier=${_tier.isEmpty ? '-' : _tier}';
  }
}
