/// Reconocimiento de senas por Dynamic Time Warping sobre plantillas.
///
/// Espejo exacto de tools/dtw.py. Corre en el dispositivo: las plantillas
/// llegan en el paquete que sincroniza PostgreSQL.
///
/// Lo que se compara NO es la secuencia guardada tal cual: la forma de la mano
/// debe haber pasado antes por isotropizarSecuencia (sign_norm.dart), y el
/// clasificador le resta a cada mano su posicion media (centrarUbicacion).
library dtw;

import 'dart:math' as math;

import 'sign_norm.dart';

/// Dimensiones del bloque de cuerpo que entran en la distancia: codos,
/// munecas y caderas, solo X e Y.
///
/// Quedan fuera dos cosas a proposito. Los hombros, porque su X e Y son
/// constantes por construccion (-0.5 y +0.5) y sumarian siempre cero. Y
/// TODAS las Z del cuerpo, porque la profundidad que estima MediaPipe Pose es
/// ruidosa: sirve de sobra para animar al avatar, que es para lo que se
/// agrego en la version 2.0.0 de sign_norm, pero al comparar dos senas mete
/// mas error que senal.
///
/// El resultado es que el clasificador compara EXACTAMENTE las mismas 12
/// dimensiones de cuerpo que antes del cambio a 3D. Si algun dia se quiere
/// probar si la profundidad ayuda a reconocer, basta con agregar aqui los
/// indices de kZBodyDims y volver a medir contra el set de prueba.
const List<int> kBodyDistDims = [
  6, 7, // codo izq
  9, 10, // codo der
  12, 13, // muneca izq
  15, 16, // muneca der
  18, 19, // cadera izq
  21, 22, // cadera der
];
const int kNBody = 12;
const int kNShape = 60;

/// Pesos por bloque. 2026-10-10, medidos con validacion cruzada por grabacion
/// (620 consultas, 541 senas, las 29 letras incluidas); espejo exacto de
/// tools/dtw.py, donde esta la explicacion completa:
///  * kWBody 0.5 -> 0: el cuerpo (codos, munecas, caderas) depende de cuanto
///    se separo cada persona y de la camara; con 0.15 el acierto en letras
///    cae de 43.6 % a 27.7 %. Sigue en el vector (avatar y "Practicar"), solo
///    no decide.
///  * kWLoc 1.5 -> 0.75 y SIN posicion absoluta (centrarUbicacion): cada
///    persona sena a otra altura; se compara la trayectoria, no la altura.
///  * Junto con la forma isotropica (isotropizarSecuencia): todas 28.2 % ->
///    34.0 %, letras 21.8 % -> 43.6 %.
const double kWBody = 0.0;
const double kWLoc = 0.75;
const double kWShape = 1.0;

/// Presencia de mano. Eran 2.0 y 1.0; se bajaron a 0.25 y 0.15 midiendo contra
/// las 146 plantillas reales (44 senas): la camara pierde una mano unos frames
/// incluso en grabaciones buenas, y con los valores viejos cada frame suelto
/// costaba ~1.7 contra ~0.2 de un frame que coincide, lo que dominaba la
/// distancia entre dos tomas de la MISMA sena. Con estos, el acierto sube ~9
/// puntos con 1 muestra por sena y ~6 con 3. Espejo exacto de tools/dtw.py: si
/// se vuelven a mover hay que recalibrar kMaxDistanceDefault y
/// kMinMarginDefault (viven en la misma escala) y regenerar
/// test/golden/golden_cases.json con tools/gen_golden.py.
const double kWPres = 0.25;
const double kShapePenalty = 0.15;

/// Umbrales de aceptacion por defecto, en la escala de la distancia de arriba.
/// Eran 0.55 / 0.12 y luego 0.65 / 0.32. Recalibrados el 2026-10-10 con la
/// distancia nueva (validacion cruzada por grabacion): antes acierta y acepta
/// 15.3 %, acepta mal 4.5 %; ahora 17.4 % y 3.3 %, y acepta 7 % de las senas
/// que NO estan en el diccionario. La distancia maxima casi no pesa; el que
/// manda es el margen (0.40 deja 91 % de precision aceptando menos).
const double kMaxDistanceDefault = 0.50;
const double kMinMarginDefault = 0.32;

const int kBand = 4;

/// Tramos del prefiltro. Con UN vector promedio por plantilla y ~2 200
/// plantillas (1 089 + espejos) la que habria ganado quedaba fuera de las 80
/// candidatas 13 % de las veces; con 8 tramos, 0.6 %.
const int kNSegmentos = 8;

const List<List<int>> _handBlocks = [
  [kOffLocL, kOffPresL, kOffShapeL],
  [kOffLocR, kOffPresR, kOffShapeR],
];

/// Distancia ponderada por bloques entre dos frames normalizados.
///
/// Cada bloque se promedia por su numero de dimensiones antes de ponderarse,
/// para que la forma de la mano (120 dims) no aplaste a la ubicacion (4 dims).
double frameDistance(List<double> a, List<double> b) {
  var acc = 0.0;

  var s = 0.0;
  for (final i in kBodyDistDims) {
    final d = a[i] - b[i];
    s += d * d;
  }
  acc += kWBody * s / kNBody;

  for (final blk in _handBlocks) {
    final offLoc = blk[0];
    final offPres = blk[1];
    final offShape = blk[2];

    final pa = a[offPres];
    final pb = b[offPres];
    final dp = pa - pb;
    acc += kWPres * dp * dp;

    final ha = pa >= 0.5;
    final hb = pb >= 0.5;
    if (ha && hb) {
      // Solo X e Y: la Z de la muneca es profundidad de cuerpo, y va fuera
      // por el mismo motivo que kBodyDistDims.
      final d0 = a[offLoc] - b[offLoc];
      final d1 = a[offLoc + 1] - b[offLoc + 1];
      acc += kWLoc * (d0 * d0 + d1 * d1) / 2.0;
      var t = 0.0;
      for (var i = offShape; i < offShape + kNShape; i++) {
        final d = a[i] - b[i];
        t += d * d;
      }
      acc += kWShape * t / kNShape;
    } else if (ha != hb) {
      acc += kWShape * kShapePenalty;
    }
  }

  return math.sqrt(acc);
}

/// DTW con banda de Sakoe-Chiba, normalizado por la secuencia mas larga.
///
/// [ceiling] permite abandonar temprano una plantilla que ya no puede ganar.
double dtwDistance(
  List<List<double>> a,
  List<List<double>> b, {
  int band = kBand,
  double? ceiling,
}) {
  final n = a.length;
  final m = b.length;
  if (n == 0 || m == 0) return double.infinity;

  const inf = double.infinity;
  final ratio = m / n;
  var prev = List<double>.filled(m + 1, inf);
  prev[0] = 0.0;

  final norm = math.max(n, m);

  for (var i = 1; i <= n; i++) {
    final center = (i - 1) * ratio;
    final lo = math.max(1, (center - band).floor() + 1);
    final hi = math.min(m, (center + band).ceil() + 1);

    final cur = List<double>.filled(m + 1, inf);
    var filaMin = inf;
    for (var j = lo; j <= hi; j++) {
      var best = prev[j - 1];
      if (prev[j] < best) best = prev[j];
      if (cur[j - 1] < best) best = cur[j - 1];
      if (best == inf) continue;
      cur[j] = best + frameDistance(a[i - 1], b[j - 1]);
      if (cur[j] < filaMin) filaMin = cur[j];
    }

    if (ceiling != null && filaMin / norm > ceiling) return inf;
    prev = cur;
  }

  final d = prev[m];
  return d == inf ? inf : d / norm;
}

/// Vector promedio de la secuencia, usado como prefiltro barato.
List<double> signature(List<List<double>> seq) {
  final sig = List<double>.filled(kFrameDim, 0.0);
  for (final f in seq) {
    for (var i = 0; i < kFrameDim; i++) {
      sig[i] += f[i];
    }
  }
  final n = seq.length;
  for (var i = 0; i < kFrameDim; i++) {
    sig[i] /= n;
  }
  return sig;
}

const List<List<int>> _locPres = [
  [kOffLocL, kOffPresL],
  [kOffLocR, kOffPresR],
];

/// Copia de la secuencia sin la posicion media de cada mano.
///
/// A cada mano se le resta, en X e Y, el promedio de la posicion de su muneca
/// sobre los frames en que esta presente. Queda solo la TRAYECTORIA: de donde
/// a donde se movio, no a que altura sena esa persona. La Z no entra en la
/// distancia y se deja igual. El original no se modifica: el avatar sigue
/// dibujando la altura real de cada sena. Espejo de centrar_ubicacion (dtw.py).
List<List<double>> centrarUbicacion(List<List<double>> seq) {
  final out = seq.map((f) => List<double>.from(f)).toList();
  for (final lp in _locPres) {
    final offLoc = lp[0];
    final offPres = lp[1];
    final idx = <int>[
      for (var t = 0; t < out.length; t++)
        if (out[t][offPres] >= 0.5) t
    ];
    if (idx.isEmpty) continue;
    var mx = 0.0;
    var my = 0.0;
    for (final t in idx) {
      mx += out[t][offLoc];
      my += out[t][offLoc + 1];
    }
    mx /= idx.length;
    my /= idx.length;
    for (final t in idx) {
      out[t][offLoc] -= mx;
      out[t][offLoc + 1] -= my;
    }
  }
  return out;
}

/// [n] vectores promedio, uno por tramo consecutivo de la secuencia. Es el
/// prefiltro del clasificador (ver kNSegmentos). Espejo de firma_segmentos.
List<List<double>> firmaSegmentos(List<List<double>> seq,
    [int n = kNSegmentos]) {
  final m = seq.length;
  if (m == 0) {
    return List.generate(n, (_) => List<double>.filled(kFrameDim, 0.0));
  }
  final out = <List<double>>[];
  for (var k = 0; k < n; k++) {
    final lo = k * m ~/ n;
    final hi = math.max(lo + 1, (k + 1) * m ~/ n);
    out.add(signature(seq.sublist(lo, hi)));
  }
  return out;
}

double _distanciaFirmas(List<List<double>> fa, List<List<double>> fb) {
  var s = 0.0;
  for (var i = 0; i < fa.length; i++) {
    s += frameDistance(fa[i], fb[i]);
  }
  return s / fa.length;
}

class Template {
  final String signId;
  final String gloss;
  final String espanol;

  /// La secuencia tal cual llego, con la altura real de cada sena (la usa el
  /// avatar).
  final List<List<double>> seq;

  /// La que se compara: sin la posicion absoluta de la mano.
  final List<List<double>> cseq;

  /// Su prefiltro (kNSegmentos vectores promedio).
  final List<List<double>> segs;

  Template._(this.signId, this.gloss, this.espanol, this.seq, this.cseq,
      this.segs);

  factory Template(String signId, String gloss, List<List<double>> seq,
      {String espanol = ''}) {
    final c = centrarUbicacion(seq);
    return Template._(signId, gloss, espanol, seq, c, firmaSegmentos(c));
  }
}

class Prediction {
  final String? gloss;
  final String? signId;
  final String? espanol;
  final double distance;
  final double margin;
  final bool aceptada;

  const Prediction(this.gloss, this.signId, this.espanol, this.distance,
      this.margin, this.aceptada);

  /// Lo que hay que decir en voz alta: el español guardado si lo hay, o si
  /// no la glosa vuelta pronunciable (COMO_ESTAS -> como estas). Un solo
  /// lugar para esta decision evita que TTS y la UI se desincronicen.
  String get textoHablado {
    final e = espanol;
    if (e != null && e.trim().isNotEmpty) return e;
    final g = gloss;
    if (g == null || g.isEmpty) return '';
    return g.toLowerCase().replaceAll('_', ' ');
  }

  @override
  String toString() => 'Prediction($gloss, d=${distance.toStringAsFixed(4)}, '
      'margen=${margin.toStringAsFixed(3)}, '
      '${aceptada ? "aceptada" : "rechazada"})';
}

class DtwClassifier {
  final List<Template> templates = [];
  final double maxDistance;
  final double minMargin;
  final int prefilter;
  final int band;

  DtwClassifier({
    this.maxDistance = kMaxDistanceDefault,
    this.minMargin = kMinMarginDefault,
    this.prefilter = 80,
    this.band = kBand,
  });

  void add(String signId, String gloss, List<List<double>> seq,
      {String espanol = ''}) {
    templates.add(Template(signId, gloss, seq, espanol: espanol));
  }

  List<Template> _candidatos(List<List<double>> segs) {
    if (prefilter <= 0 || templates.length <= prefilter) return templates;
    final puntuadas = templates
        .map((t) => MapEntry(_distanciaFirmas(segs, t.segs), t))
        .toList()
      ..sort((x, y) => x.key.compareTo(y.key));
    return puntuadas.take(prefilter).map((e) => e.value).toList();
  }

  /// Cuanto puede alejarse una plantilla de la mejor antes de abandonarla.
  ///
  /// Una plantilla de OTRA glosa solo puede cambiar la decision si queda a
  /// menos de d1 / (1 - minMargin). Con un factor fijo de 1.5 el margen solo
  /// era exacto hasta 0.333 (1 - 1/1.5): por encima, una plantilla abandonada
  /// dejaba el margen en 1.0 y se aceptaba de mas. Con el margen por defecto
  /// (0.32) el factor sigue siendo 1.5. Espejo de _factor_abandono en dtw.py.
  double get _factorAbandono =>
      math.max(1.5, 1.0 / (1.0 - math.min(minMargin, 0.95)));

  /// Todas las distancias, de menor a mayor.
  List<MapEntry<double, Template>> rank(List<List<double>> seq) {
    final q = centrarUbicacion(seq);
    final cands = _candidatos(firmaSegmentos(q));
    final out = <MapEntry<double, Template>>[];
    double? mejor;
    final factor = _factorAbandono;
    for (final t in cands) {
      final d = dtwDistance(q, t.cseq,
          band: band, ceiling: mejor == null ? null : mejor * factor);
      if (d == double.infinity) continue;
      if (mejor == null || d < mejor) mejor = d;
      out.add(MapEntry(d, t));
    }
    out.sort((x, y) => x.key.compareTo(y.key));
    return out;
  }

  Prediction classify(List<List<double>> seq) {
    final r = rank(seq);
    if (r.isEmpty) {
      return const Prediction(null, null, null, double.infinity, 0.0, false);
    }

    final d1 = r.first.key;
    final t1 = r.first.value;

    double? d2;
    for (final e in r) {
      if (e.value.gloss != t1.gloss) {
        d2 = e.key;
        break;
      }
    }

    final margin = (d2 == null || d2 == 0) ? 1.0 : (d2 - d1) / d2;
    final aceptada = d1 <= maxDistance && margin >= minMargin;
    return Prediction(t1.gloss, t1.signId, t1.espanol, d1, margin, aceptada);
  }
}

// ---------------------------------------------------------------------------
// Diagnostico: descompone la distancia DTW en cuerpo y forma de cada mano.
// Portado desde la rama de interfaz. Lo usa pantalla_practicar.dart para
// decir QUE salio distinto, en vez de solo un numero. No lo usa el
// clasificador: es explicacion, no decision.
// ---------------------------------------------------------------------------
class Diagnostico {
  /// Que tan lejos estuvo la posicion/movimiento del CUERPO (hombros, codos,
  /// munecas, caderas), normalizado por frame. Mismo peso relativo que usa
  /// el clasificador, asi que un valor "alto" aca es comparable a lo que ya
  /// se calibro para aceptar/rechazar.
  final double cuerpo;

  /// Distancia de la FORMA de cada mano (como estan dobladas los dedos),
  /// null si esa mano no participa en la plantilla objetivo.
  final double? formaIzq;
  final double? formaDer;

  /// Si la presencia de cada mano coincidio con lo esperado. true en
  /// izqEsperadaPeroFalto/derEsperadaPeroFalto significa "la plantilla usa
  /// esta mano y el intento no", y viceversa con izqSobra/derSobra.
  final bool izqEsperadaPeroFalto;
  final bool derEsperadaPeroFalto;
  final bool izqSobra;
  final bool derSobra;

  const Diagnostico({
    required this.cuerpo,
    this.formaIzq,
    this.formaDer,
    required this.izqEsperadaPeroFalto,
    required this.derEsperadaPeroFalto,
    required this.izqSobra,
    required this.derSobra,
  });

  /// Umbral por encima del cual una distancia de cuerpo/forma se considera
  /// "no coincide". No es una ciencia exacta -- es del mismo orden que
  /// maxDistance por defecto del clasificador, elegido porque cuerpo/forma
  /// son componentes de esa misma distancia total.
  static const double kUmbral = 0.30;

  /// Mensaje en espanol explicando el problema mas grande encontrado, en
  /// terminos que alguien practicando pueda entender y corregir. Nunca
  /// vacio: si nada especifico destaca, da un mensaje generico.
  String explicacion() {
    if (izqEsperadaPeroFalto) {
      return 'Esta se\u00f1a usa la mano izquierda y no la detecte. Fijate que se '
          'vea bien en camara.';
    }
    if (derEsperadaPeroFalto) {
      return 'Esta se\u00f1a usa la mano derecha y no la detecte. Fijate que se vea '
          'bien en camara.';
    }
    if (izqSobra || derSobra) {
      final lado = izqSobra ? 'izquierda' : 'derecha';
      return 'Usaste la mano $lado de mas: esta se\u00f1a no la necesita.';
    }

    final candidatas = <MapEntry<String, double>>[
      MapEntry('cuerpo', cuerpo),
      if (formaIzq != null) MapEntry('formaIzq', formaIzq!),
      if (formaDer != null) MapEntry('formaDer', formaDer!),
    ]..sort((a, b) => b.value.compareTo(a.value));

    final peor = candidatas.first;
    if (peor.value < kUmbral) {
      return 'Muy cerca. Sigue practicando el mismo movimiento.';
    }
    switch (peor.key) {
      case 'cuerpo':
        return 'La posicion o el movimiento del brazo no coincidieron. '
            'Fijate donde empieza y termina la se\u00f1a respecto a tu cuerpo.';
      case 'formaIzq':
        return 'La forma de la mano izquierda (como doblas los dedos) no '
            'coincidio con la se\u00f1a.';
      case 'formaDer':
        return 'La forma de la mano derecha (como doblas los dedos) no '
            'coincidio con la se\u00f1a.';
      default:
        return 'No coincidio del todo. Segui practicando.';
    }
  }
}

/// Compara un intento contra UNA plantilla objetivo (no contra todo el
/// diccionario) y descompone la distancia por componente, para poder
/// explicarle a quien practica que fue lo que no coincidio.
///
/// A diferencia de dtwDistance, esto NO alinea con Dynamic Time Warping --
/// ambas secuencias ya vienen remuestreadas a kTFrames (32) por
/// resample(), asi que comparar frame a frame alcanza para dar una senal
/// util sin la complejidad de reconstruir el camino de alineacion del DTW.
/// Es deliberadamente mas simple que el clasificador: sirve para explicar,
/// no para decidir si una sena entra al diccionario.
Diagnostico diagnosticar(List<List<double>> intento, List<List<double>> objetivo) {
  final n = math.min(intento.length, objetivo.length);
  if (n == 0) {
    return const Diagnostico(
      cuerpo: 1.0,
      izqEsperadaPeroFalto: false,
      derEsperadaPeroFalto: false,
      izqSobra: false,
      derSobra: false,
    );
  }

  double cuerpo = 0;
  double formaIzqAcc = 0, formaDerAcc = 0;
  int nIzq = 0, nDer = 0;
  int izqObjPresente = 0, izqIntPresente = 0;
  int derObjPresente = 0, derIntPresente = 0;

  for (var k = 0; k < n; k++) {
    final fa = intento[k];
    final fb = objetivo[k];

    var s = 0.0;
    for (final i in kBodyDistDims) {
      final d = fa[i] - fb[i];
      s += d * d;
    }
    cuerpo += s / kNBody;

    final presIzqInt = fa[kOffPresL] >= 0.5;
    final presIzqObj = fb[kOffPresL] >= 0.5;
    if (presIzqObj) izqObjPresente++;
    if (presIzqInt) izqIntPresente++;
    if (presIzqInt && presIzqObj) {
      var t = 0.0;
      for (var i = kOffShapeL; i < kOffShapeL + kNShape; i++) {
        final d = fa[i] - fb[i];
        t += d * d;
      }
      formaIzqAcc += t / kNShape;
      nIzq++;
    }

    final presDerInt = fa[kOffPresR] >= 0.5;
    final presDerObj = fb[kOffPresR] >= 0.5;
    if (presDerObj) derObjPresente++;
    if (presDerInt) derIntPresente++;
    if (presDerInt && presDerObj) {
      var t = 0.0;
      for (var i = kOffShapeR; i < kOffShapeR + kNShape; i++) {
        final d = fa[i] - fb[i];
        t += d * d;
      }
      formaDerAcc += t / kNShape;
      nDer++;
    }
  }

  // Presencia esperada: la plantilla usa esa mano en mas de un cuarto de
  // sus frames (evita falsos "falto la mano" por un frame suelto donde el
  // detector parpadeo durante la grabacion original).
  final izqEsperada = izqObjPresente > n ~/ 4;
  final derEsperada = derObjPresente > n ~/ 4;
  final izqDetectada = izqIntPresente > n ~/ 4;
  final derDetectada = derIntPresente > n ~/ 4;

  return Diagnostico(
    cuerpo: math.sqrt(cuerpo / n),
    formaIzq: nIzq > 0 ? math.sqrt(formaIzqAcc / nIzq) : null,
    formaDer: nDer > 0 ? math.sqrt(formaDerAcc / nDer) : null,
    izqEsperadaPeroFalto: izqEsperada && !izqDetectada,
    derEsperadaPeroFalto: derEsperada && !derDetectada,
    izqSobra: !izqEsperada && izqDetectada,
    derSobra: !derEsperada && derDetectada,
  );
}
