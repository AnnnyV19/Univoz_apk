import 'package:test/test.dart';

import 'package:senas_core/camera_bridge.dart';
import 'package:senas_core/sign_norm.dart';

List<double> _validPose() {
  final pose = List<double>.filled(33 * 4, 0);
  for (var i = 0; i < 33; i++) pose[i * 4 + 3] = .8;
  pose[11 * 4] = .3;
  pose[11 * 4 + 1] = .4;
  pose[12 * 4] = .7;
  pose[12 * 4 + 1] = .4;
  return pose;
}

List<double> _validWorldPose() {
  final world = List<double>.filled(33 * 3, 0);
  void point(int index, double x, double y, double z) {
    world[index * 3] = x;
    world[index * 3 + 1] = y;
    world[index * 3 + 2] = z;
  }

  point(11, -.2, .5, 0);
  point(12, .2, .5, 0);
  // Brazos conectados: normalizeFrame descarta segmentos imposibles.
  point(13, -.25, .25, 0);
  point(14, .25, .25, 0);
  point(15, -.25, .02, 0);
  point(16, .25, .02, 0);
  point(23, -.15, 0, 0);
  point(24, .15, 0, 0);
  return world;
}

/// Mano abierta plausible con la muneca en (x, y), plana (21 x 3).
List<double> _mano(double x, double y) {
  const forma = [
    [0.0, 0.0], [-.06, -.05], [-.11, -.10], [-.14, -.16], [-.16, -.22],
    [-.04, -.08], [-.05, -.16], [-.06, -.24], [-.06, -.32], [0.0, -.10],
    [0.0, -.20], [0.0, -.30], [0.0, -.40], [.04, -.09], [.06, -.18],
    [.07, -.26], [.08, -.34], [.08, -.06], [.11, -.13], [.13, -.19],
    [.14, -.24],
  ];
  return [
    for (final p in forma) ...[x + p[0] * .6, y + p[1] * .6, 0.0],
  ];
}

void main() {
  test('LandmarkFrame lee la captura web de Android y su calidad', () {
    final frame = LandmarkFrame.fromMap({
      't': 50,
      'pose': _validPose(),
      'poseMundo': _validWorldPose(),
      'left': _mano(.35, .8),
      'right': null,
      // Render estabilizado 0.05 a la derecha de la deteccion cruda.
      'renderLeft': [
        for (final (i, v) in _mano(.35, .8).indexed) i % 3 == 0 ? v + .05 : v,
      ],
      'pose_t': 50,
      'hands_t': 50,
      'hands_in': {
        'candidates': [
          {'lm': _mano(.35, .8), 'label': 'Left', 'conf': .9},
        ],
        'accepted': [0],
        'unanchored': [],
        'rejected': [],
        'passed': [0],
        'assignment': {'mode': 'pose_arm_chain', 'sides': ['left']},
        'usable': [true],
      },
      'track': {
        'left': {'state': 'TRACKING', 'surface': 'palm'},
        'right': {'state': 'LOST', 'surface': null},
      },
      'pose_ran': true,
    });
    expect(frame.handsIn!['assignment']['mode'], 'pose_arm_chain');
    expect(frame.track!['left']['surface'], 'palm');
    expect(frame.poseRan, isTrue);
    // Calidad web: 0.75 * visibilidad media del cuerpo + 0.25 * manos
    // (una mano: 0.82).
    expect(frame.calidad, closeTo(.8 * .75 + .82 * .25, 1e-12));
    final reconocimiento = frame.normalize()!;
    final render = frame.normalizeForRender()!;
    // El render mueve solo la ubicacion de la mano hacia la muneca
    // estabilizada; la forma y el vector de reconocimiento no cambian.
    expect(render[kOffLocL], isNot(closeTo(reconocimiento[kOffLocL], 1e-6)));
    expect(render.sublist(kOffShapeL), reconocimiento.sublist(kOffShapeL));
    final json = frame.toJson();
    expect(json['hands_in'], isNotNull);
    expect(json['pose_ran'], isTrue);
    expect(json['quality'], closeTo(frame.calidad, 1e-12));
  });

  test('LandmarkFrameV1 conserva landmarks y metadata en JSON', () {
    final frame = LandmarkFrame.fromMap({
      't': 1234,
      'pose': _validPose(),
      'poseMundo': _validWorldPose(),
      'left': List<double>.filled(21 * 3, 0.2),
      'right': null,
      'renderLeft': List<double>.filled(21 * 3, 0.25),
      'renderRight': List<double>.filled(21 * 3, 0.3),
      'pose_t': 1200,
      'hands_t': 1234,
      'source_skew_ms': 34,
      'association': {'left_state': 'TRACKING', 'right_state': 'OCCLUDED'},
      'errors': [
        {'stage': 'association', 'code': 'hand_occluded', 'side': 'right'}
      ],
    });

    final json = frame.toJson();
    expect(json['schema'], 'LandmarkFrameV1');
    expect(json['t'], 1234);
    expect((json['pose'] as List).length, 33);
    expect(frame.visibilidadMin, closeTo(0.8, 1e-12));
    expect(frame.poseTimestampMs, 1200);
    expect(frame.handsTimestampMs, 1234);
    expect(frame.sourceSkewMs, 34);
    expect(frame.normalizeForRender(), hasLength(152));
    expect(frame.association['right_state'], 'OCCLUDED');
    expect(frame.errors.single['code'], 'hand_occluded');
    final restored = LandmarkFrame.fromMap(
        json.map((key, value) => MapEntry<Object?, Object?>(key, value)));
    expect(restored.pose, frame.pose);
    expect(restored.left, frame.left);
    expect(restored.renderRight, frame.renderRight);
  });

  test('skew de 50/120/121 ms controla proyeccion y rechazo', () {
    LandmarkFrame frame(int skew) => LandmarkFrame.fromMap({
          't': 1000,
          'pose': _validPose(),
          'poseMundo': _validWorldPose(),
          'source_skew_ms': skew,
        });

    expect(frame(50).requiereProyeccionRender, isFalse);
    expect(frame(50).fusionAceptada, isTrue);
    expect(frame(120).requiereProyeccionRender, isTrue);
    expect(frame(120).fusionAceptada, isTrue);
    expect(frame(121).fusionAceptada, isFalse);
  });

  test('LandmarkFrameV1 detecta frame incompleto sin inventar datos', () {
    final frame = LandmarkFrame.fromMap({'t': 1, 'pose': null});

    expect(frame.normalize(), isNull);
    expect(frame.esValido, isFalse);
    expect(frame.toJson()['left'], isNull);
  });

  test('LandmarkFrame entrega SignSpaceFrame para el avatar sin tocar 152D',
      () {
    final frame = LandmarkFrame.fromMap({
      't': 10,
      'pose': _validPose(),
      'poseMundo': _validWorldPose(),
      'left': null,
      'right': null,
      'pose_t': 10,
      'hands_t': 10,
    });
    final ss = frame.signSpace();
    expect(ss, isNotNull);
    expect(ss!.values, hasLength(35));
    expect(ss.values.every((v) => v.isFinite), isTrue);
    expect(frame.normalize(), hasLength(152));
  });

  test('LandmarkFrame no entrega SignSpaceFrame si la fusion falla', () {
    final frame = LandmarkFrame.fromMap({
      't': 10,
      'pose': _validPose(),
      'poseMundo': _validWorldPose(),
      'left': null,
      'right': null,
      'pose_t': 10,
      'hands_t': 400,
    });
    expect(frame.signSpace(), isNull);
  });

  test('LandmarkFrame lee cara y manos metricas de la captura Holistic', () {
    final frame = LandmarkFrame.fromMap({
      't': 10,
      'pose': _validPose(),
      'poseMundo': _validWorldPose(),
      'left': List<double>.filled(21 * 3, 0.2),
      'right': null,
      'leftWorld': List<double>.filled(21 * 3, 0.01),
      'face': List<double>.filled(kFaceKeypoints.length * 3, 0.5),
      'capture_mode': 'holistic',
      'image_w': 480,
      'image_h': 640,
      'pose_t': 10,
      'hands_t': 10,
    });
    expect(frame.captureMode, 'holistic');
    expect(frame.imageAspect, closeTo(480 / 640, 1e-9));
    expect(frame.face, hasLength(kFaceKeypoints.length));
    expect(frame.leftWorld, hasLength(21));
    expect(frame.rightWorld, isNull);
    final json = frame.toJson();
    expect(json['capture_mode'], 'holistic');
    expect(json['face'], hasLength(17));
  });

  test('fromMap lee nivel, inferencia y estado térmico del nativo', () {
    final f = LandmarkFrame.fromMap(
        {'t': 1, 'tier': 'bajo', 'infer_ms': 41.5, 'thermal': 2});
    expect(f.tier, 'bajo');
    expect(f.inferMs, 41.5);
    expect(f.thermal, 2);
    final json = f.toJson();
    expect(json['tier'], 'bajo');
    expect(json['infer_ms'], 41.5);
    expect(json['thermal'], 2);

    // Plugin viejo o API < 29: campos ausentes o de tipo equivocado.
    final viejo = LandmarkFrame.fromMap({'t': 1, 'tier': 3, 'thermal': null});
    expect(viejo.tier, isNull);
    expect(viejo.inferMs, isNull);
    expect(viejo.thermal, isNull);
    expect(viejo.toJson().containsKey('tier'), isFalse);
  });
}
