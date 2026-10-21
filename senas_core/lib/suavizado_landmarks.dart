/// Suavizado SOLO VISUAL de los landmarks que se dibujan sobre la camara.
///
/// MediaPipe da cada punto con un temblor de uno o dos pixeles aunque la
/// persona este quieta, y a 30 cuadros por segundo eso se ve como un esqueleto
/// "vibrando". Este filtro lo calma sin hacer que el dibujo vaya atrasado:
///
///  - con la mano quieta, mucho suavizado (el temblor baja a ~30 %);
///  - con la mano en movimiento rapido, casi nada (retraso de ~1 cuadro).
///
/// Es el filtro One Euro (Casiez, Roussel y Vogel, 2012): la frecuencia de
/// corte sube sola con la velocidad del punto.
///
/// IMPORTANTE: esto toca unicamente lo que se pinta. El reconocimiento, las
/// muestras guardadas y el avatar leen los frames SIN filtrar (el stream
/// fusionado de CameraBridge.frames); aqui nunca debe entrar nada de eso.
library suavizado_landmarks;

import 'dart:math' as math;

import 'camera_bridge.dart' show LandmarkFrame;

/// Filtro One Euro para UNA coordenada.
class FiltroOneEuro {
  /// Corte (Hz) con el punto quieto: mas bajo = mas suave y mas lento.
  final double minCutoff;

  /// Cuanto sube el corte por cada unidad/segundo de velocidad. Con
  /// coordenadas normalizadas (0..1), valores de 5 a 15 sirven.
  final double beta;

  /// Corte (Hz) con el que se suaviza la velocidad estimada.
  final double dCutoff;

  double? _crudoPrevio;
  double? _valor;
  double? _derivada;

  FiltroOneEuro({
    this.minCutoff = 1.0,
    this.beta = 10.0,
    this.dCutoff = 1.0,
  });

  static double _alfa(double dt, double corte) {
    final tau = 1.0 / (2.0 * math.pi * corte);
    return 1.0 / (1.0 + tau / dt);
  }

  /// Filtra [x]; [dt] son los segundos desde la muestra anterior (> 0).
  double filtrar(double x, double dt) {
    final previo = _crudoPrevio;
    final dx = previo == null ? 0.0 : (x - previo) / dt;
    _crudoPrevio = x;

    final ad = _alfa(dt, dCutoff);
    final derivadaPrev = _derivada;
    final d = derivadaPrev == null ? dx : ad * dx + (1.0 - ad) * derivadaPrev;
    _derivada = d;

    final corte = minCutoff + beta * d.abs();
    final a = _alfa(dt, corte);
    final valorPrev = _valor;
    final v = valorPrev == null ? x : a * x + (1.0 - a) * valorPrev;
    _valor = v;
    return v;
  }

  void reiniciar() {
    _crudoPrevio = null;
    _valor = null;
    _derivada = null;
  }
}

/// Filtros de un conjunto de landmarks (la pose, o una mano): uno por
/// coordenada x e y de cada punto.
class _GrupoLandmarks {
  final double minCutoff;
  final double beta;

  final List<FiltroOneEuro> _fx = [];
  final List<FiltroOneEuro> _fy = [];
  int? _ultimoT;
  List<List<double>>? _ultimaSalida;

  _GrupoLandmarks(this.minCutoff, this.beta);

  /// Si pasan mas de esto sin muestras, lo anterior ya no sirve de referencia.
  static const double _huecoMaxSeg = 0.25;
  static const double _dtPorDefecto = 1.0 / 30.0;

  void reiniciar() {
    for (final f in _fx) {
      f.reiniciar();
    }
    for (final f in _fy) {
      f.reiniciar();
    }
    _ultimoT = null;
    _ultimaSalida = null;
  }

  List<List<double>>? filtrar(List<List<double>>? crudo, int tMs) {
    if (crudo == null) {
      // La mano (o la persona) desaparecio: cuando vuelva, que arranque
      // desde su posicion real y no arrastrada desde donde estaba.
      reiniciar();
      return null;
    }

    final previaSalida = _ultimaSalida;
    final previoT = _ultimoT;
    if (previaSalida != null &&
        previoT != null &&
        previoT == tMs &&
        previaSalida.length == crudo.length) {
      // Mismo instante que el cuadro anterior (el nativo repite el ultimo
      // dato de un modelo cuando termina el otro): no hay muestra nueva, y
      // volver a filtrarla solo falsearia la velocidad.
      return previaSalida;
    }

    var dt = previoT == null ? _dtPorDefecto : (tMs - previoT) / 1000.0;
    if (previoT != null && (dt <= 0 || dt > _huecoMaxSeg)) {
      reiniciar();
      dt = _dtPorDefecto;
    }
    if (previaSalida != null && previaSalida.length != crudo.length) {
      reiniciar();
      dt = _dtPorDefecto;
    }

    while (_fx.length < crudo.length) {
      _fx.add(FiltroOneEuro(minCutoff: minCutoff, beta: beta));
      _fy.add(FiltroOneEuro(minCutoff: minCutoff, beta: beta));
    }

    final salida = <List<double>>[];
    for (var i = 0; i < crudo.length; i++) {
      final p = crudo[i];
      if (p.length < 2 || !p[0].isFinite || !p[1].isFinite) {
        // Punto invalido: se deja pasar tal cual y se reinicia su filtro.
        _fx[i].reiniciar();
        _fy[i].reiniciar();
        salida.add(p);
        continue;
      }
      final x = _fx[i].filtrar(p[0], dt);
      final y = _fy[i].filtrar(p[1], dt);
      // z y visibilidad (si hay) pasan sin tocar.
      salida.add(<double>[x, y, ...p.sublist(2)]);
    }

    _ultimoT = tMs;
    _ultimaSalida = salida;
    return salida;
  }
}

/// Suaviza la pose y las dos manos de un [LandmarkFrame] para dibujarlas.
class SuavizadorLandmarks {
  final _GrupoLandmarks _pose;
  final _GrupoLandmarks _izquierda;
  final _GrupoLandmarks _derecha;

  /// [minCutoff] y [beta]: ver [FiltroOneEuro]. Los valores por defecto se
  /// eligieron simulando una mano que se queda quieta con temblor de 0.3-0.6 %
  /// de la imagen y luego da un barrido rapido: el temblor baja a ~30 % y el
  /// barrido llega con un cuadro de retraso.
  SuavizadorLandmarks({double minCutoff = 1.0, double beta = 10.0})
      : _pose = _GrupoLandmarks(minCutoff, beta),
        _izquierda = _GrupoLandmarks(minCutoff, beta),
        _derecha = _GrupoLandmarks(minCutoff, beta);

  /// Devuelve una copia de [f] con pose y manos suavizadas. Todo lo demas
  /// (mundo, render, cara, aspecto de la imagen, nivel del dispositivo,
  /// metadatos) pasa igual: ver [LandmarkFrame.conLandmarks].
  LandmarkFrame filtrar(LandmarkFrame f) {
    final poseT = f.poseTimestampMs ?? f.timestampMs;
    final manosT = f.handsTimestampMs ?? f.timestampMs;
    return f.conLandmarks(
      pose: _pose.filtrar(f.pose, poseT),
      left: _izquierda.filtrar(f.left, manosT),
      right: _derecha.filtrar(f.right, manosT),
    );
  }

  /// Olvida todo (al cambiar de camara, por ejemplo).
  void reiniciar() {
    _pose.reiniciar();
    _izquierda.reiniciar();
    _derecha.reiniciar();
  }
}
