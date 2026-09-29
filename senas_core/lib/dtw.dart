/// Reconocimiento de senas por Dynamic Time Warping sobre plantillas.
///
/// Espejo exacto de tools/dtw.py. Corre en el dispositivo: las plantillas
/// llegan en el paquete que sincroniza PostgreSQL.
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

const double kWBody = 0.5;
const double kWLoc = 1.5;
const double kWPres = 2.0;
const double kWShape = 1.0;
const double kShapePenalty = 1.0;

const int kBand = 4;

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

class Template {
  final String signId;
  final String gloss;
  final String espanol;
  final List<List<double>> seq;
  final List<double> sig;

  Template(this.signId, this.gloss, this.seq, {this.espanol = ''})
      : sig = signature(seq);
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
    this.maxDistance = 0.55,
    this.minMargin = 0.12,
    this.prefilter = 40,
    this.band = kBand,
  });

  void add(String signId, String gloss, List<List<double>> seq,
      {String espanol = ''}) {
    templates.add(Template(signId, gloss, seq, espanol: espanol));
  }

  List<Template> _candidatos(List<double> sig) {
    if (prefilter <= 0 || templates.length <= prefilter) return templates;
    final puntuadas = templates
        .map((t) => MapEntry(frameDistance(sig, t.sig), t))
        .toList()
      ..sort((x, y) => x.key.compareTo(y.key));
    return puntuadas.take(prefilter).map((e) => e.value).toList();
  }

  /// Todas las distancias, de menor a mayor.
  List<MapEntry<double, Template>> rank(List<List<double>> seq) {
    final cands = _candidatos(signature(seq));
    final out = <MapEntry<double, Template>>[];
    double? mejor;
    for (final t in cands) {
      final d = dtwDistance(seq, t.seq,
          band: band, ceiling: mejor == null ? null : mejor * 1.5);
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
