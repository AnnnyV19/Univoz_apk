/// Normalizacion de landmarks para reconocimiento de senas.
///
/// Espejo exacto de python/sign_norm.py. Cualquier cambio aqui tiene que
/// hacerse alla tambien, y el golden test tiene que seguir pasando en ambos.
///
/// Este archivo no depende de Flutter a proposito: asi corre en `dart test`
/// sin levantar un emulador.
///
/// VERSION 2.0.0: el cuerpo pasa de 2D a 3D, y se calcula desde el esqueleto
/// METRICO de MediaPipe (worldLandmarks), no desde las coordenadas de imagen.
///
/// Se intento primero usar la Z que traen los landmarks de imagen, y no
/// sirve: sus valores son incoherentes entre puntos vecinos. Medido en una
/// captura real, un antebrazo de 0.8 anchos de hombro daba 3.5 de recorrido
/// en Z, y las caderas quedaban dos anchos de hombro detras de los hombros.
/// MediaPipe la documenta como profundidad relativa aproximada y no da para
/// reconstruir una postura. Los mismos segmentos medidos con worldLandmarks
/// dieron 0.73, 0.65, 0.67 y 0.83: coherentes entre si y con la anatomia.
///
/// El bloque de cuerpo ya no son coordenadas de imagen rotadas, sino
/// proyecciones sobre una base ortonormal sacada del propio esqueleto:
///   +X  hacia la derecha de la persona (hombro izq -> hombro der)
///   +Y  hacia arriba (caderas -> hombros, ortogonalizado)
///   +Z  hacia el frente de la persona
/// dividido todo por la distancia entre hombros. Eso lo hace invariante a
/// donde este la persona, a que tan lejos, y a hacia donde este girada.
library sign_norm;

import 'dart:math' as math;
import 'dart:typed_data';

const String kNormVersion = '2.0.0';
const int kTFrames = 32;
const int kFrameDim = 152;

const int kLShoulder = 11;
const int kRShoulder = 12;
const int kLHip = 23;
const int kRHip = 24;
const int kLWrist = 15;
const int kRWrist = 16;

/// Hombros, codos, munecas, caderas.
const List<int> kPoseBodyIdx = [11, 12, 13, 14, 15, 16, 23, 24];
const List<List<int>> kBodyMirrorPairs = [
  [0, 1],
  [2, 3],
  [4, 5],
  [6, 7],
];

const int kHandWrist = 0;
const int kHandMiddleMcp = 9;
const int kNHandPts = 20;

const double kMinVisibility = 0.5;
const double kEps = 1e-6;

/// Validaciones de rig_motion_frame.mjs (handUsable / poseGeometry): una
/// mano o un cuerpo geometricamente imposibles no entran al vector.
const double kMargenMano = 0.15;
const double kMargenCuerpo = 0.15;
const List<List<int>> kConexionesMano = [
  [0, 1], [1, 2], [2, 3], [3, 4],
  [0, 5], [5, 6], [6, 7], [7, 8],
  [0, 9], [9, 10], [10, 11], [11, 12],
  [0, 13], [13, 14], [14, 15], [15, 16],
  [0, 17], [17, 18], [18, 19], [19, 20],
  [5, 9], [9, 13], [13, 17],
];

/// Las munecas estabilizadas del render mueven la ubicacion a lo sumo esto
/// (en anchos de hombro).
const double kTopeMunecaRender = 0.75;

const int kOffBody = 0; // 24 = 8 puntos x (x, y, z)
const int kOffLocL = 24; // 3
const int kOffLocR = 27; // 3
const int kOffPresL = 30;
const int kOffPresR = 31;
const int kOffShapeL = 32; // 60 = 20 puntos x (x, y, z)
const int kOffShapeR = 92; // 60

/// Dimensiones con profundidad del CUERPO. El clasificador las ignora: aunque
/// worldLandmarks es mucho mejor que la Z de imagen, sigue siendo una
/// estimacion y al comparar dos senas aporta menos que lo que ensucia. La Z
/// de la FORMA de las manos no esta aqui y si se usa.
const List<int> kZBodyDims = [
  2, 5, 8, 11, 14, 17, 20, 23, // los 8 puntos del cuerpo
  kOffLocL + 2, kOffLocR + 2, // las dos munecas
];

/// Base ortonormal del cuerpo, sacada del esqueleto metrico.
class _BaseCuerpo {
  final List<double> der; // hacia la derecha de la persona
  final List<double> arr; // hacia arriba
  final List<double> fre; // hacia el frente
  final List<double> origen; // punto medio entre hombros
  final double escala; // distancia entre hombros, en metros
  const _BaseCuerpo(this.der, this.arr, this.fre, this.origen, this.escala);

  /// Proyecta un punto del mundo sobre la base, en unidades de ancho de
  /// hombros.
  List<double> proyectar(List<double> p) {
    final q = [p[0] - origen[0], p[1] - origen[1], p[2] - origen[2]];
    return [
      _pto(q, der) / escala,
      _pto(q, arr) / escala,
      _pto(q, fre) / escala
    ];
  }
}

double _pto(List<double> a, List<double> b) =>
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2];

List<double> _resta(List<double> a, List<double> b) =>
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]];

List<double> _cruz(List<double> a, List<double> b) => [
      a[1] * b[2] - a[2] * b[1],
      a[2] * b[0] - a[0] * b[2],
      a[0] * b[1] - a[1] * b[0],
    ];

double _largo(List<double> a) => math.sqrt(_pto(a, a));

List<double>? _unitario(List<double> a) {
  final m = _largo(a);
  if (m < kEps) return null;
  return [a[0] / m, a[1] / m, a[2] / m];
}

/// Arma la base del cuerpo. Null si el esqueleto esta degenerado.
_BaseCuerpo? _baseDe(List<Landmark> w) {
  final hi = w[kLShoulder], hd = w[kRShoulder];
  final ci = w[kLHip], cd = w[kRHip];

  final der = _unitario(_resta(hd, hi));
  if (der == null) return null;
  final escala = _largo(_resta(hd, hi));

  final origen = [
    (hi[0] + hd[0]) * 0.5,
    (hi[1] + hd[1]) * 0.5,
    (hi[2] + hd[2]) * 0.5,
  ];
  final centroCaderas = [
    (ci[0] + cd[0]) * 0.5,
    (ci[1] + cd[1]) * 0.5,
    (ci[2] + cd[2]) * 0.5,
  ];

  // Arriba = caderas -> hombros, ortogonalizado contra la linea de hombros
  // (Gram-Schmidt) para que la base sea realmente ortonormal aunque la
  // persona este inclinada de lado.
  final tronco = _resta(origen, centroCaderas);
  final proy = _pto(tronco, der);
  final arr = _unitario([
    tronco[0] - der[0] * proy,
    tronco[1] - der[1] * proy,
    tronco[2] - der[2] * proy,
  ]);
  if (arr == null) return null;

  // Frente = arriba x derecha. Con los ejes de MediaPipe (X a la derecha de
  // la imagen, Y hacia abajo, Z creciendo al alejarse de la camara) este
  // producto apunta hacia el pecho de la persona.
  final fre = _unitario(_cruz(arr, der));
  if (fre == null) return null;

  return _BaseCuerpo(der, arr, fre, origen, escala);
}

/// Un landmark: [x, y, z] y opcionalmente visibility en la posicion 3.
typedef Landmark = List<double>;

/// Motivo de rechazo de una mano o de un frame, con los codigos de la web.
class MotivoNorm {
  final String stage;
  final String code;
  final String? side;
  final int? landmark;
  const MotivoNorm(this.code, {this.stage = 'capture', this.side, this.landmark});

  Map<String, Object?> toMap() =>
      {'stage': stage, 'code': code, 'side': side, 'landmark': landmark};

  @override
  String toString() => '$code${side == null ? '' : ' ($side)'}';
}

/// Resultado de una validacion: [code] y [landmark] dicen por que no.
class ValidacionNorm {
  final bool ok;
  final String? code;
  final int? landmark;
  const ValidacionNorm.ok()
      : ok = true,
        code = null,
        landmark = null;
  const ValidacionNorm.falla(this.code, [this.landmark]) : ok = false;
}

/// Punto como coord() de la web: lo que falta es NaN y la visibility, 0.
class _P {
  final double x, y, z, vis;
  _P(Landmark? p)
      : x = _en(p, 0, double.nan),
        y = _en(p, 1, double.nan),
        z = _en(p, 2, double.nan),
        vis = _en(p, 3, 0.0);
  _P.de(this.x, this.y, this.z) : vis = 0.0;
  bool get finito => x.isFinite && y.isFinite && z.isFinite;
  static double _en(Landmark? p, int i, double defecto) =>
      p != null && p.length > i ? p[i] : defecto;
}

double _dist(_P a, _P b) {
  final dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z;
  return math.sqrt(dx * dx + dy * dy + dz * dz);
}

/// No alimentar el normalizador con manos parcialmente corruptas: en una
/// oclusion MediaPipe puede devolver un punto aislado fuera de cuadro que
/// deforma angulo y orientacion de toda la mano. Espejo de handUsable.
ValidacionNorm manoUtilizable(List<Landmark>? mano) {
  if (mano == null || mano.length != 21) {
    return const ValidacionNorm.falla('hand_landmarks_incomplete');
  }
  final pts = mano.map(_P.new).toList();
  for (var i = 0; i < pts.length; i++) {
    if (!pts[i].finito) return ValidacionNorm.falla('point_non_finite', i);
  }
  final w = pts[0];
  // La muneca debe verse; las puntas pueden salirse un margen chico.
  if (!(w.x >= 0 && w.x <= 1 && w.y >= 0 && w.y <= 1)) {
    return const ValidacionNorm.falla('wrist_out_of_frame', 0);
  }
  bool dentro(_P p) =>
      p.x >= -kMargenMano &&
      p.x <= 1 + kMargenMano &&
      p.y >= -kMargenMano &&
      p.y <= 1 + kMargenMano;
  if (pts.where(dentro).length < 15) {
    final fuera = pts.indexWhere((p) => !dentro(p));
    return ValidacionNorm.falla('hand_out_of_frame', fuera >= 0 ? fuera : null);
  }
  final ex = pts[9].x - w.x, ey = pts[9].y - w.y;
  final escala = math.sqrt(ex * ex + ey * ey);
  if (!escala.isFinite || escala < 0.015 || escala > 0.65) {
    return const ValidacionNorm.falla('hand_scale_invalid', 9);
  }
  // Cada conexion plausible respecto de la escala del MCP medio: atrapa
  // puntos intercambiados o picos sin rechazar manos abiertas o cerradas.
  for (final c in kConexionesMano) {
    final d = _dist(pts[c[0]], pts[c[1]]);
    if (!d.isFinite || d < escala * 0.018 || d > escala * 2.2) {
      return ValidacionNorm.falla('hand_segment_invalid', c[1]);
    }
  }
  return const ValidacionNorm.ok();
}

/// Cuerpo con anclas visibles y segmentos del esqueleto metrico plausibles
/// respecto del ancho de hombros. Espejo de poseGeometry.
ValidacionNorm poseGeometriaValida(
    List<Landmark>? pose, List<Landmark>? poseMundo) {
  if (pose == null || pose.length < 33 || poseMundo == null ||
      poseMundo.length < 33) {
    return const ValidacionNorm.falla('pose-formato');
  }
  for (final i in [kLShoulder, kRShoulder, kLHip, kRHip]) {
    final p = _P(pose[i]);
    final hombro = i == kLShoulder || i == kRShoulder;
    // Los hombros deben verse en la imagen; las caderas pueden quedar fuera
    // del recorte: sus worldLandmarks siguen dando el eje del torso.
    final enMargen = p.x >= -kMargenCuerpo &&
        p.x <= 1 + kMargenCuerpo &&
        p.y >= -kMargenCuerpo &&
        p.y <= 1 + kMargenCuerpo;
    if (hombro && (!p.finito || !enMargen)) {
      return ValidacionNorm.falla('shoulder_out_of_frame', i);
    }
    if (!p.finito ||
        (hombro && (!p.vis.isFinite || p.vis < 0.2)) ||
        !_P(poseMundo[i]).finito) {
      return ValidacionNorm.falla('pose_anchor_unsafe', i);
    }
  }
  final w = poseMundo.map(_P.new).toList();
  final hombros = _dist(w[kLShoulder], w[kRShoulder]);
  if (!hombros.isFinite || hombros < 1e-3) {
    return const ValidacionNorm.falla('hombros-degenerados');
  }
  for (final s in const [
    [11, 13], [13, 15], [12, 14], [14, 16], [23, 24]
  ]) {
    final d = _dist(w[s[0]], w[s[1]]);
    if (!d.isFinite || d < hombros * 0.08 || d > hombros * 2.5) {
      return ValidacionNorm.falla('pose_segment_invalid', s[1]);
    }
  }
  _P medio(_P a, _P b) =>
      _P.de((a.x + b.x) * 0.5, (a.y + b.y) * 0.5, (a.z + b.z) * 0.5);
  final tronco = _dist(
      medio(w[kLShoulder], w[kRShoulder]), medio(w[kLHip], w[kRHip]));
  if (!tronco.isFinite || tronco <= hombros * 0.25 || tronco >= hombros * 4.0) {
    return const ValidacionNorm.falla('tronco-invalido');
  }
  return const ValidacionNorm.ok();
}

/// Normaliza un frame. Devuelve null si el frame no sirve (hombros no
/// visibles, cuerpo imposible o sin esqueleto metrico). Espejo de
/// normalizeMotionFrame (rig_motion_frame.mjs) y de sign_norm.py.
///
/// [pose] son las coordenadas de imagen (para el filtro de visibilidad y la
/// rotacion de las manos) y [poseMundo] el esqueleto metrico (para todo el
/// bloque de cuerpo).
///
/// [munecasRender] (`left`/`right` en imagen) desplaza solo la UBICACION de
/// la mano hacia la muneca estabilizada del render (la de la pose puede ir
/// uno o dos frames atrasada), acotado a +-0.75 anchos de hombro: solo para
/// el vector del avatar. [motivos], si se pasa, recibe cada rechazo (de mano
/// o de frame) con los codigos de la web.
List<double>? normalizeFrame(
  List<Landmark>? pose,
  List<Landmark>? poseMundo, {
  List<Landmark>? left,
  List<Landmark>? right,
  double minVisibility = kMinVisibility,
  Map<String, Landmark>? munecasRender,
  List<MotivoNorm>? motivos,
}) {
  if (pose == null || pose.length < 33 || poseMundo == null ||
      poseMundo.length < 33) {
    motivos?.add(const MotivoNorm('pose_format'));
    return null;
  }

  final ls = _P(pose[kLShoulder]);
  final rs = _P(pose[kRShoulder]);
  if (!ls.finito ||
      !rs.finito ||
      !(ls.vis >= minVisibility) ||
      !(rs.vis >= minVisibility)) {
    motivos?.add(const MotivoNorm('shoulder_confidence_low'));
    return null;
  }

  for (final index in kPoseBodyIdx) {
    if (!_P(poseMundo[index]).finito) {
      motivos?.add(const MotivoNorm('pose_world_non_finite'));
      return null;
    }
  }

  final geometria = poseGeometriaValida(pose, poseMundo);
  if (!geometria.ok) {
    motivos?.add(MotivoNorm(geometria.code!, landmark: geometria.landmark));
    return null;
  }

  final base = _baseDe(poseMundo);
  if (base == null) return null;

  // Marco 2D de imagen: se sigue usando para la FORMA de las manos, que solo
  // existe en coordenadas de imagen. Alinea la linea de hombros con la
  // horizontal para que inclinar la cabeza no cambie la forma detectada.
  final dx = rs.x - ls.x;
  final dy = rs.y - ls.y;
  final escalaImg = math.sqrt(dx * dx + dy * dy);
  if (escalaImg < kEps) return null;
  final cosT = dx / escalaImg;
  final sinT = dy / escalaImg;

  final out = List<double>.filled(kFrameDim, 0.0);

  for (var i = 0; i < kPoseBodyIdx.length; i++) {
    final q = base.proyectar(poseMundo[kPoseBodyIdx[i]]);
    out[kOffBody + i * 3] = q[0];
    out[kOffBody + i * 3 + 1] = q[1];
    out[kOffBody + i * 3 + 2] = q[2];
  }

  final hands = [
    [left, 'left', kOffLocL, kOffPresL, kOffShapeL, kLWrist],
    [right, 'right', kOffLocR, kOffPresR, kOffShapeR, kRWrist],
  ];

  for (final h in hands) {
    final hand = h[0] as List<Landmark>?;
    if (hand == null || hand.length != 21) continue;
    final side = h[1] as String;
    final offLoc = h[2] as int;
    final offPres = h[3] as int;
    final offShape = h[4] as int;
    final idxMuneca = h[5] as int;
    final valida = manoUtilizable(hand);
    if (!valida.ok) {
      motivos?.add(
          MotivoNorm(valida.code!, side: side, landmark: valida.landmark));
      continue;
    }

    // Ubicacion de la mano: se toma la muneca del modelo de POSE, no la del
    // detector de manos, para que quede en el mismo espacio metrico que el
    // resto del cuerpo. Son practicamente el mismo punto anatomico.
    final q = base.proyectar(poseMundo[idxMuneca]);
    // Muneca estabilizada del render: residuo de imagen llevado a los ejes
    // del cuerpo y acotado. El vector de reconocimiento no la usa.
    final estable = _P(munecasRender?[side]);
    final munecaImg = _P(pose[idxMuneca]);
    if (estable.finito && munecaImg.finito) {
      final ix = (estable.x - munecaImg.x) / escalaImg;
      final iy = (estable.y - munecaImg.y) / escalaImg;
      q[0] += (ix * cosT + iy * sinT)
          .clamp(-kTopeMunecaRender, kTopeMunecaRender);
      q[1] += (-ix * sinT + iy * cosT)
          .clamp(-kTopeMunecaRender, kTopeMunecaRender);
    }
    out[offLoc] = q[0];
    out[offLoc + 1] = q[1];
    out[offLoc + 2] = q[2];
    out[offPres] = 1.0;

    // La FORMA si viene del detector de manos: es relativa a su propia
    // muneca y escalada por el tamano de la mano, asi que no depende de
    // donde este el brazo.
    final w = hand[kHandWrist];
    final m = hand[kHandMiddleMcp];
    final hdx = m[0] - w[0];
    final hdy = m[1] - w[1];
    var handScale = math.sqrt(hdx * hdx + hdy * hdy);
    if (handScale < kEps) handScale = escalaImg * 0.25;

    for (var j = 1; j < 21; j++) {
      final p = hand[j];
      final qx = p[0] - w[0];
      final qy = p[1] - w[1];
      final k = offShape + (j - 1) * 3;
      out[k] = (qx * cosT + qy * sinT) / handScale;
      out[k + 1] = (-qx * sinT + qy * cosT) / handScale;
      out[k + 2] = (p[2] - w[2]) / handScale;
    }
  }

  return out.every((v) => v.isFinite) ? out : null;
}

/// Calidad del frame en [0, 1], como calcularCalidadFrameWeb (frameQuality
/// en rig_motion_frame.mjs): 0.75 x visibilidad media de los 8 puntos del
/// cuerpo (el minimo era demasiado sensible: un codo tapado la hundia) +
/// 0.25 x presencia de manos (una basta para una sena: 0.82; dos, 1; ninguna,
/// 0.65).
double calidadFrame(List<Landmark>? pose, List<Landmark>? poseMundo,
    List<Landmark>? left, List<Landmark>? right) {
  if (pose == null || pose.length < 33 || poseMundo == null ||
      poseMundo.length < 33) {
    return 0;
  }
  final cuerpo = kPoseBodyIdx.map((i) => _P(pose[i]).vis).toList();
  if (cuerpo.any((v) => !v.isFinite)) return 0;
  final visibilidad =
      (cuerpo.fold<double>(0, (t, v) => t + v.clamp(0.0, 1.0)) / cuerpo.length)
          .clamp(0.0, 1.0);
  final manos = left != null && right != null
      ? 1.0
      : left != null || right != null
          ? 0.82
          : 0.65;
  return (visibilidad * 0.75 + manos * 0.25).clamp(0.0, 1.0);
}

/// Sustituye frames nulos por el ultimo valido.
List<List<double>>? fillGaps(List<List<double>?> frames) {
  List<double>? last;
  for (final f in frames) {
    if (f != null) {
      last = f;
      break;
    }
  }
  if (last == null) return null;

  final out = <List<double>>[];
  for (final f in frames) {
    if (f != null) last = f;
    out.add(last!);
  }
  return out;
}

/// Remuestrea linealmente a [t] frames.
List<List<double>>? resample(List<List<double>> frames, [int t = kTFrames]) {
  final n = frames.length;
  if (n == 0) return null;
  if (n == 1) {
    return List.generate(t, (_) => List<double>.from(frames[0]));
  }

  final out = <List<double>>[];
  for (var i = 0; i < t; i++) {
    final pos = i * (n - 1) / (t - 1);
    final lo = pos.floor();
    final hi = math.min(lo + 1, n - 1);
    final w = pos - lo;
    final a = frames[lo];
    final b = frames[hi];
    out.add(List<double>.generate(kFrameDim, (d) => a[d] + (b[d] - a[d]) * w));
  }
  return out;
}

/// Espejea un frame ya normalizado (augmentation para personas zurdas).
///
/// La Z no se toca: espejear a alguien de lado a lado no cambia que tan cerca
/// esta de la camara.
List<double> mirrorFrame(List<double> v) {
  final out = List<double>.filled(kFrameDim, 0.0);

  for (final pair in kBodyMirrorPairs) {
    final a = pair[0];
    final b = pair[1];
    out[kOffBody + a * 3] = -v[kOffBody + b * 3];
    out[kOffBody + a * 3 + 1] = v[kOffBody + b * 3 + 1];
    out[kOffBody + a * 3 + 2] = v[kOffBody + b * 3 + 2];
    out[kOffBody + b * 3] = -v[kOffBody + a * 3];
    out[kOffBody + b * 3 + 1] = v[kOffBody + a * 3 + 1];
    out[kOffBody + b * 3 + 2] = v[kOffBody + a * 3 + 2];
  }

  out[kOffLocL] = -v[kOffLocR];
  out[kOffLocL + 1] = v[kOffLocR + 1];
  out[kOffLocL + 2] = v[kOffLocR + 2];
  out[kOffLocR] = -v[kOffLocL];
  out[kOffLocR + 1] = v[kOffLocL + 1];
  out[kOffLocR + 2] = v[kOffLocL + 2];

  out[kOffPresL] = v[kOffPresR];
  out[kOffPresR] = v[kOffPresL];

  for (var j = 0; j < kNHandPts; j++) {
    final sl = kOffShapeL + j * 3;
    final sr = kOffShapeR + j * 3;
    out[sl] = -v[sr];
    out[sl + 1] = v[sr + 1];
    out[sl + 2] = v[sr + 2];
    out[sr] = -v[sl];
    out[sr + 1] = v[sl + 1];
    out[sr + 2] = v[sl + 2];
  }

  return out;
}

// ---------------------------------------------------------------------------
// FORMA ISOTROPICA (2026-10-10). Espejo exacto de sign_norm.isotropizar_* en
// tools/sign_norm.py; ver alla la explicacion completa.
//
// Los landmarks de mano de MediaPipe vienen divididos por el ANCHO y el ALTO
// de la imagen por separado, asi que la mano sale aplastada o estirada segun el
// aspecto de la camara (16:9 comprime x y z a 0.56 de y; el bitmap de analisis
// de la app, 360x480, los estira 1.33). El formato guardado (norm 2.0.0) NO
// cambia: la correccion se aplica donde se COMPARA, a una secuencia ya
// normalizada y remuestreada, y es una funcion pura de (forma, aspecto).
// ---------------------------------------------------------------------------

/// Marca del paquete de plantillas ya corregido (campo "forma" del JSON).
const String kFormaIso = 'iso1';

/// Aspecto (ancho / alto) que se asume para un video o una plantilla de la que
/// no se sabe nada: casi todos los de la base son 16:9.
const double kAspectoVideo = 16.0 / 9.0;

/// Aspecto del bitmap de analisis de la app (360x480, vertical 3:4). Se usa
/// cuando el lado nativo no informa el tamano real de la imagen.
const double kAspectoAnalisisApp = 0.75;

/// Distancia muneca -> MCP del indice, medio, anular y menique, en las
/// unidades de la forma 2.0.0 (escala 2D muneca->MCP9 = 1).
const List<double> kRefPalma = [1.07, 1.01, 0.92, 0.84];

/// Posicion de MCP5, 9, 13 y 17 dentro de los 20 puntos guardados.
const List<int> kIdxPalma = [4, 8, 12, 16];

/// Corrige la forma de UNA mano presente (20 puntos x,y,z desde [off]) en una
/// copia del frame: x y z por el aspecto, y escala por la mediana de las
/// distancias 3D muneca->MCP5,9,13,17 sobre su largo de referencia.
void _isotropizarMano(List<double> v, int off, double aspecto) {
  final r = <double>[];
  for (var i = 0; i < kIdxPalma.length; i++) {
    final k = off + kIdxPalma[i] * 3;
    final x = v[k] * aspecto;
    final y = v[k + 1];
    final z = v[k + 2] * aspecto;
    r.add(math.sqrt(x * x + y * y + z * z) / kRefPalma[i]);
  }
  r.sort();
  var hs = (r[1] + r[2]) / 2.0; // mediana de 4
  if (hs < 1e-6) hs = 1.0;
  for (var j = 0; j < kNHandPts; j++) {
    final k = off + j * 3;
    final x = v[k] * aspecto;
    final y = v[k + 1];
    final z = v[k + 2] * aspecto;
    v[k] = x / hs;
    v[k + 1] = y / hs;
    v[k + 2] = z / hs;
  }
}

/// Frame de 152 con la forma de cada mano PRESENTE corregida. Devuelve copia.
List<double> isotropizarFrame(List<double> v, double aspecto) {
  final out = List<double>.from(v);
  if (v[kOffPresL] >= 0.5) _isotropizarMano(out, kOffShapeL, aspecto);
  if (v[kOffPresR] >= 0.5) _isotropizarMano(out, kOffShapeR, aspecto);
  return out;
}

List<List<double>> isotropizarSecuencia(
        List<List<double>> seq, double aspecto) =>
    seq.map((f) => isotropizarFrame(f, aspecto)).toList();

/// Empaqueta la secuencia a float16 para mandarla al servidor / BYTEA.
Uint8List packF16(List<List<double>> seq) {
  final flat = <double>[];
  for (final row in seq) {
    flat.addAll(row);
  }
  final bytes = ByteData(flat.length * 2);
  for (var i = 0; i < flat.length; i++) {
    bytes.setUint16(i * 2, _toF16(flat[i]), Endian.little);
  }
  return bytes.buffer.asUint8List();
}

/// Inverso de [packF16]: bytes float16 little endian -> matriz de frames.
/// Espejo de sign_norm.unpack_f16 en Python. Lo usa la sincronizacion con
/// Supabase, que baja las plantillas en el mismo formato en que se guardan
/// en la columna BYTEA.
List<List<double>> unpackF16(Uint8List bytes, {int dim = kFrameDim}) {
  final n = bytes.length ~/ 2;
  final vista = ByteData.sublistView(bytes);
  final plano = List<double>.generate(
      n, (i) => _fromF16(vista.getUint16(i * 2, Endian.little)),
      growable: false);

  final filas = <List<double>>[];
  for (var i = 0; i + dim <= n; i += dim) {
    filas.add(plano.sublist(i, i + dim));
  }
  return filas;
}

/// bits de float16 -> double.
double _fromF16(int bits) {
  final signo = (bits & 0x8000) != 0 ? -1.0 : 1.0;
  final exp = (bits >> 10) & 0x1F;
  final mant = bits & 0x3FF;

  if (exp == 0) {
    // Subnormal: mant * 2^-24. Sin bit implicito.
    return signo * mant * 5.960464477539063e-8;
  }
  if (exp == 0x1F) {
    return mant == 0 ? signo * double.infinity : double.nan;
  }
  // Normal: (1024 + mant) * 2^(exp - 25)
  return signo * (1024 + mant) * _pot2(exp - 25);
}

double _pot2(int e) => math.pow(2.0, e).toDouble();

/// float64 -> bits de float16, con redondeo al par mas cercano.
int _toF16(double value) {
  final f = ByteData(4)..setFloat32(0, value, Endian.little);
  final bits = f.getUint32(0, Endian.little);
  final sign = (bits >> 16) & 0x8000;
  var exp = ((bits >> 23) & 0xFF) - 127 + 15;
  var mant = bits & 0x7FFFFF;

  if (exp >= 0x1F) return sign | 0x7C00; // inf / overflow
  if (exp <= 0) {
    if (exp < -10) return sign;
    mant |= 0x800000;
    final shift = 14 - exp;
    var sub = mant >> shift;
    if (((mant >> (shift - 1)) & 1) == 1) sub += 1;
    return sign | sub;
  }

  var half = sign | (exp << 10) | (mant >> 13);
  if ((mant & 0x1000) != 0) half += 1;
  return half & 0xFFFF;
}
