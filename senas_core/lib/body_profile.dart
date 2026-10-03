/// BodyProfileV1: medidas del cuerpo del usuario + modelo de capacidad.
///
/// Espejo exacto de tools/body_profile.py (golden en
/// test/golden/sign_space_cases.json). Vive fuera de 152D y de
/// SignSpaceFrame: es el CapabilityMask externo. Local, versionado y
/// borrable; nunca guarda video ni landmarks crudos, solo medianas.
library body_profile;

import 'dart:math' as math;

import 'sign_space.dart';

const String kBodyProfileVersion = '1.0.0';
const int kBpMinSamples = 20;
const double _kOkRatio = 0.6;
const double _kSeenRatio = 0.1;

const List<String> kBpLimbs = ['armL', 'armR', 'handL', 'handR'];

/// `absent` solo puede venir declarado por el usuario.
const List<String> kBpStatuses = ['ok', 'partial', 'not_observed', 'absent'];

const List<String> kBpMeasures = [
  'shoulderWidth',
  'upperL',
  'upperR',
  'foreL',
  'foreR',
  'handL',
  'handR',
  'neck',
];

class BodyProfile {
  final String version;
  final int samples;
  final Map<String, double?> measures;
  final Map<String, double?> rom;
  final Map<String, String> capability;
  final Map<String, String> declared;

  const BodyProfile({
    required this.version,
    required this.samples,
    required this.measures,
    required this.rom,
    required this.capability,
    required this.declared,
  });

  Map<String, dynamic> toJson() => {
        'version': version,
        'samples': samples,
        'measures': measures,
        'rom': rom,
        'capability': capability,
        'declared': declared,
      };

  static BodyProfile fromJson(Map<String, dynamic> json) {
    if (json['version'] != kBodyProfileVersion) {
      throw FormatException('BodyProfile version ${json['version']}');
    }
    Map<String, double?> nums(Object? m) => {
          for (final e in (m as Map).entries)
            e.key as String: (e.value as num?)?.toDouble(),
        };
    Map<String, String> strs(Object? m) => {
          for (final e in (m as Map).entries)
            e.key as String: e.value as String,
        };
    return BodyProfile(
      version: json['version'] as String,
      samples: (json['samples'] as num).toInt(),
      measures: nums(json['measures']),
      rom: nums(json['rom']),
      capability: strs(json['capability']),
      declared: strs(json['declared']),
    );
  }
}

double _dist(List<double> a, List<double> b) =>
    math.sqrt((a[0] - b[0]) * (a[0] - b[0]) +
        (a[1] - b[1]) * (a[1] - b[1]) +
        (a[2] - b[2]) * (a[2] - b[2]));

double? _mediana(List<double> xs) {
  if (xs.isEmpty) return null;
  final s = [...xs]..sort();
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) * 0.5;
}

List<double> _medio(List<double> a, List<double> b) =>
    [for (var i = 0; i < 3; i++) (a[i] + b[i]) * 0.5];

/// [frames]: pares (pose de imagen con visibility, worldLandmarks).
BodyProfile estimateBodyProfile(
  Iterable<(List<List<double>>?, List<List<double>>?)> frames, {
  Map<String, String> declared = const {},
  int minSamples = kBpMinSamples,
  double minVisibility = kSsMinVisibility,
}) {
  for (final e in declared.entries) {
    if (!kBpLimbs.contains(e.key) || !kBpStatuses.contains(e.value)) {
      throw ArgumentError('declaracion invalida: ${e.key}=${e.value}');
    }
  }

  final muestras = {for (final k in kBpMeasures) k: <double>[]};
  final alcance = {'armL': <double>[], 'armR': <double>[]};
  final vistos = {for (final k in kBpLimbs) k: 0};
  var n = 0;

  bool vis(List<List<double>> pose, int i) =>
      pose[i].length >= 4 && pose[i][3] >= minVisibility;

  for (final (pose, w) in frames) {
    if (pose == null || w == null || pose.length < 33 || w.length < 33) {
      continue;
    }
    if (!vis(pose, kSsLShoulder) || !vis(pose, kSsRShoulder)) continue;
    n++;
    muestras['shoulderWidth']!.add(_dist(w[kSsLShoulder], w[kSsRShoulder]));
    for (final l in const [
      ['L', kSsLShoulder, kSsLElbow, kSsLWrist, kSsLPinky, kSsLIndex],
      ['R', kSsRShoulder, kSsRElbow, kSsRWrist, kSsRPinky, kSsRIndex],
    ]) {
      final lado = l[0] as String;
      final hombro = l[1] as int, codo = l[2] as int, muneca = l[3] as int;
      final menique = l[4] as int, indice = l[5] as int;
      if (vis(pose, codo) && vis(pose, muneca)) {
        final brazo = _dist(w[hombro], w[codo]);
        final antebrazo = _dist(w[codo], w[muneca]);
        muestras['upper$lado']!.add(brazo);
        muestras['fore$lado']!.add(antebrazo);
        vistos['arm$lado'] = vistos['arm$lado']! + 1;
        if (brazo + antebrazo > 1e-6) {
          alcance['arm$lado']!
              .add(_dist(w[hombro], w[muneca]) / (brazo + antebrazo));
        }
      }
      if (vis(pose, muneca)) {
        muestras['hand$lado']!
            .add(_dist(w[muneca], _medio(w[menique], w[indice])));
        vistos['hand$lado'] = vistos['hand$lado']! + 1;
      }
    }
    if (vis(pose, kSsNose)) {
      muestras['neck']!.add(_dist(_medio(w[kSsLShoulder], w[kSsRShoulder]),
          _medio(w[kSsMouthL], w[kSsMouthR])));
    }
  }

  final medidas = {
    for (final e in muestras.entries)
      e.key: e.value.length >= minSamples ? _mediana(e.value) : null,
  };

  final capacidad = <String, String>{};
  for (final limb in kBpLimbs) {
    final dec = declared[limb];
    if (dec != null) {
      capacidad[limb] = dec;
      continue;
    }
    final ratio = n > 0 ? vistos[limb]! / n : 0.0;
    if (n >= minSamples && ratio >= _kOkRatio) {
      capacidad[limb] = 'ok';
    } else if (n >= minSamples && ratio < _kSeenRatio) {
      capacidad[limb] = 'not_observed';
    } else {
      capacidad[limb] = 'partial';
    }
  }

  final rom = {
    for (final e in alcance.entries)
      e.key: e.value.length >= minSamples ? e.value.reduce(math.max) : null,
  };

  return BodyProfile(
    version: kBodyProfileVersion,
    samples: n,
    measures: medidas,
    rom: rom,
    capability: capacidad,
    declared: Map.of(declared),
  );
}

/// Fases guiadas de Fast User Capture (mismas que rig_body_profile.mjs).
const List<(String, String)> kBodyCapturePhases = [
  ('neutral', 'Quieto, brazos relajados a los lados'),
  ('arms_forward', 'Estira los brazos al frente y muevelos despacio'),
  ('hands', 'Abre y cierra las manos frente al pecho'),
];

enum BodyCaptureState { idle, capturing, done }

/// Fast User Capture: junta frames validos en 3 poses guiadas y estima el
/// perfil. Exige consentimiento explicito y descarta los frames al terminar:
/// solo sobrevive el [BodyProfile].
class BodyProfileCapture {
  final int framesPerPhase;
  final Map<String, String> declared;
  final double minVisibility;

  BodyCaptureState _state = BodyCaptureState.idle;
  int _phase = 0;
  int _count = 0;
  List<(List<List<double>>, List<List<double>>)> _frames = [];
  BodyProfile? _profile;

  BodyProfileCapture({
    this.framesPerPhase = 45,
    this.declared = const {},
    this.minVisibility = kSsMinVisibility,
  });

  BodyCaptureState get state => _state;
  String? get phase =>
      _phase < kBodyCapturePhases.length ? kBodyCapturePhases[_phase].$1 : null;
  String? get instruction =>
      _phase < kBodyCapturePhases.length ? kBodyCapturePhases[_phase].$2 : null;
  double get progress => _state == BodyCaptureState.done
      ? 1.0
      : (_phase * framesPerPhase + _count) /
          (kBodyCapturePhases.length * framesPerPhase);
  BodyProfile? get profile => _profile;

  void start({required bool consent}) {
    if (!consent) throw StateError('consentimiento requerido');
    _state = BodyCaptureState.capturing;
    _phase = 0;
    _count = 0;
    _frames = [];
    _profile = null;
  }

  void push(List<List<double>>? pose, List<List<double>>? world) {
    if (_state != BodyCaptureState.capturing) return;
    if (pose == null || world == null || pose.length < 33) return;
    bool vis(int i) => pose[i].length >= 4 && pose[i][3] >= minVisibility;
    if (!vis(kSsLShoulder) || !vis(kSsRShoulder)) return;
    _frames.add((pose, world));
    _count++;
    if (_count < framesPerPhase) return;
    _phase++;
    _count = 0;
    if (_phase >= kBodyCapturePhases.length) {
      _profile = estimateBodyProfile(_frames,
          declared: declared,
          minSamples: math.min(kBpMinSamples, framesPerPhase),
          minVisibility: minVisibility);
      _frames = []; // no se conservan landmarks
      _state = BodyCaptureState.done;
      _phase = kBodyCapturePhases.length - 1;
    }
  }

  void cancel() {
    _state = BodyCaptureState.idle;
    _frames = [];
  }
}
