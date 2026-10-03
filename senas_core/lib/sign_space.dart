/// SignSpaceFrame v1: representacion de la sena independiente del cuerpo.
///
/// Espejo exacto de tools/sign_space.py. Cualquier cambio aqui tiene que
/// hacerse alla (y en assets/avatar_viewer/rig_sign_space.mjs), y el golden
/// test/golden/sign_space_cases.json tiene que seguir pasando en los tres.
///
/// MotionFrameV2 152D (sign_norm.dart) no cambia. Este frame alimenta al
/// avatar y a la biblioteca de senas: direcciones unitarias de los
/// segmentos, palma y anclas de la cara en anchos de hombro, contactos, y la
/// ausencia en una mascara aparte (nunca un cero con significado).
library sign_space;

import 'dart:math' as math;

const String kSignSpaceVersion = '1.0.0';

const int kSsNose = 0;
const int kSsMouthL = 9, kSsMouthR = 10;
const int kSsLShoulder = 11, kSsRShoulder = 12;
const int kSsLElbow = 13, kSsRElbow = 14;
const int kSsLWrist = 15, kSsRWrist = 16;
const int kSsLPinky = 17, kSsRPinky = 18;
const int kSsLIndex = 19, kSsRIndex = 20;
const int kSsLHip = 23, kSsRHip = 24;

const double kSsMinVisibility = 0.5;
const double kSsHipVisibility = 0.5;
const double _kEps = 1e-6;

const int kSsOffUpperL = 0;
const int kSsOffForeL = 3;
const int kSsOffUpperR = 6;
const int kSsOffForeR = 9;
const int kSsOffPalmL = 12;
const int kSsOffPalmR = 15;
const int kSsOffNose = 18;
const int kSsOffMouth = 21;
const int kSsOffHandDirL = 24;
const int kSsOffHandDirR = 27;
const int kSsOffContact = 30;
const int kSignSpaceDim = 35;

const int kSsContactFaceL = 0,
    kSsContactFaceR = 1,
    kSsContactChestL = 2,
    kSsContactChestR = 3,
    kSsContactHands = 4;

const List<double> kSsChest = [0.0, -0.40, 0.10];
const double kSsThresholdFace = 0.30;
const double kSsThresholdChest = 0.30;
const double kSsThresholdHands = 0.25;

/// Grupos de la mascara. `false` = ese bloque no existe en este frame.
const List<String> kSsMaskKeys = ['armL', 'armR', 'handL', 'handR', 'face'];

class SignSpaceFrame {
  final String version;

  /// `full` si la vertical sale de las caderas; `upper` si las caderas no
  /// eran visibles y se uso la vertical de la camara.
  final String mode;

  /// Ancho de hombros en metros.
  final double scale;
  final List<double> values;
  final Map<String, bool> mask;

  const SignSpaceFrame({
    required this.version,
    required this.mode,
    required this.scale,
    required this.values,
    required this.mask,
  });

  Map<String, dynamic> toJson() => {
        'version': version,
        'mode': mode,
        'scale': scale,
        'values': values,
        'mask': mask,
      };
}

typedef _V = List<double>;

double _pto(_V a, _V b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
_V _resta(_V a, _V b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
_V _cruz(_V a, _V b) => [
      a[1] * b[2] - a[2] * b[1],
      a[2] * b[0] - a[0] * b[2],
      a[0] * b[1] - a[1] * b[0],
    ];
double _largo(_V a) => math.sqrt(_pto(a, a));

_V? _unitario(_V a) {
  final m = _largo(a);
  if (m < _kEps) return null;
  return [a[0] / m, a[1] / m, a[2] / m];
}

_V _medio(List<_V> ps) {
  final n = ps.length.toDouble();
  return [
    for (var i = 0; i < 3; i++) ps.fold<double>(0, (s, p) => s + p[i]) / n
  ];
}

bool _visible(List<List<double>> pose, int idx, double minimo) {
  final p = pose[idx];
  return p.length >= 4 && p[3] >= minimo;
}

class _Base {
  final _V der, arr, fre, origen;
  final double escala;
  final String modo;
  const _Base(
      this.der, this.arr, this.fre, this.origen, this.escala, this.modo);

  _V dir(_V a, _V b) {
    final d = _unitario(_resta(b, a));
    if (d == null) return const [];
    return [_pto(d, der), _pto(d, arr), _pto(d, fre)];
  }

  _V pos(_V p) {
    final q = _resta(p, origen);
    return [
      _pto(q, der) / escala,
      _pto(q, arr) / escala,
      _pto(q, fre) / escala
    ];
  }
}

_Base? _base(List<List<double>> pose, List<List<double>> w, double hipVis) {
  final hi = w[kSsLShoulder], hd = w[kSsRShoulder];
  final der = _unitario(_resta(hd, hi));
  if (der == null) return null;
  final escala = _largo(_resta(hd, hi));
  final origen = _medio([hi, hd]);

  _V tronco;
  String modo;
  if (_visible(pose, kSsLHip, hipVis) && _visible(pose, kSsRHip, hipVis)) {
    tronco = _resta(origen, _medio([w[kSsLHip], w[kSsRHip]]));
    modo = 'full';
  } else {
    tronco = const [0.0, -1.0, 0.0]; // vertical de la camara
    modo = 'upper';
  }
  final proy = _pto(tronco, der);
  final arr = _unitario([
    tronco[0] - der[0] * proy,
    tronco[1] - der[1] * proy,
    tronco[2] - der[2] * proy,
  ]);
  if (arr == null) return null;
  final fre = _unitario(_cruz(arr, der));
  if (fre == null) return null;
  return _Base(der, arr, fre, origen, escala, modo);
}

/// Calcula el frame. Null si los hombros no son visibles o el esqueleto es
/// degenerado. [pose]: 33 landmarks de imagen con visibility; [poseMundo]:
/// 33 worldLandmarks metricos.
SignSpaceFrame? signSpaceFrame(
  List<List<double>>? pose,
  List<List<double>>? poseMundo, {
  double minVisibility = kSsMinVisibility,
  double hipVisibility = kSsHipVisibility,
}) {
  if (pose == null || pose.length < 33) return null;
  if (poseMundo == null || poseMundo.length < 33) return null;
  if (!_visible(pose, kSsLShoulder, minVisibility) ||
      !_visible(pose, kSsRShoulder, minVisibility)) {
    return null;
  }
  for (final p in poseMundo.take(25)) {
    if (p.length < 3 || p.take(3).any((v) => !v.isFinite)) return null;
  }

  final base = _base(pose, poseMundo, hipVisibility);
  if (base == null) return null;

  final w = poseMundo;
  final out = List<double>.filled(kSignSpaceDim, 0.0);
  final mask = {for (final k in kSsMaskKeys) k: false};
  final palmas = <String, _V>{};

  void escribir(int off, _V v) {
    for (var i = 0; i < 3; i++) {
      out[off + i] = v[i];
    }
  }

  for (final lado in const [
    [
      'L',
      kSsLShoulder,
      kSsLElbow,
      kSsLWrist,
      kSsLPinky,
      kSsLIndex,
      kSsOffUpperL,
      kSsOffForeL,
      kSsOffPalmL,
      kSsOffHandDirL
    ],
    [
      'R',
      kSsRShoulder,
      kSsRElbow,
      kSsRWrist,
      kSsRPinky,
      kSsRIndex,
      kSsOffUpperR,
      kSsOffForeR,
      kSsOffPalmR,
      kSsOffHandDirR
    ],
  ]) {
    final nombre = lado[0] as String;
    final hombro = lado[1] as int, codo = lado[2] as int;
    final muneca = lado[3] as int, menique = lado[4] as int;
    final indice = lado[5] as int;
    final offU = lado[6] as int, offF = lado[7] as int;
    final offP = lado[8] as int, offH = lado[9] as int;

    if (_visible(pose, codo, minVisibility) &&
        _visible(pose, muneca, minVisibility)) {
      final du = base.dir(w[hombro], w[codo]);
      final df = base.dir(w[codo], w[muneca]);
      if (du.isNotEmpty && df.isNotEmpty) {
        escribir(offU, du);
        escribir(offF, df);
        mask['arm$nombre'] = true;
      }
    }
    if (_visible(pose, muneca, minVisibility)) {
      final nudillos = _medio([w[menique], w[indice]]);
      final dh = base.dir(w[muneca], nudillos);
      if (dh.isNotEmpty) {
        final palma = base.pos(_medio([w[muneca], w[menique], w[indice]]));
        escribir(offP, palma);
        escribir(offH, dh);
        mask['hand$nombre'] = true;
        palmas[nombre] = palma;
      }
    }
  }

  if (_visible(pose, kSsNose, minVisibility)) {
    escribir(kSsOffNose, base.pos(w[kSsNose]));
    escribir(kSsOffMouth, base.pos(_medio([w[kSsMouthL], w[kSsMouthR]])));
    mask['face'] = true;
  }

  final nariz = out.sublist(kSsOffNose, kSsOffNose + 3);
  final boca = out.sublist(kSsOffMouth, kSsOffMouth + 3);
  for (final c in const [
    ['L', kSsContactFaceL, kSsContactChestL],
    ['R', kSsContactFaceR, kSsContactChestR],
  ]) {
    final palma = palmas[c[0]];
    if (palma == null) continue;
    if (mask['face']! &&
        math.min(_largo(_resta(palma, nariz)), _largo(_resta(palma, boca))) <
            kSsThresholdFace) {
      out[kSsOffContact + (c[1] as int)] = 1.0;
    }
    if (_largo(_resta(palma, kSsChest)) < kSsThresholdChest) {
      out[kSsOffContact + (c[2] as int)] = 1.0;
    }
  }
  final pl = palmas['L'], pr = palmas['R'];
  if (pl != null && pr != null && _largo(_resta(pl, pr)) < kSsThresholdHands) {
    out[kSsOffContact + kSsContactHands] = 1.0;
  }

  return SignSpaceFrame(
    version: kSignSpaceVersion,
    mode: base.modo,
    scale: base.escala,
    values: out,
    mask: mask,
  );
}
