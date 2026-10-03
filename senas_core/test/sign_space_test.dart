import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:senas_core/body_profile.dart';
import 'package:senas_core/sign_space.dart';

const String kSignSpaceGolden = 'test/golden/sign_space_cases.json';

List<List<double>> _pts(Object? raw) => [
      for (final p in raw as List)
        [for (final v in p as List) (v as num).toDouble()],
    ];

void main() {
  final file = File(kSignSpaceGolden);
  if (!file.existsSync()) {
    throw StateError(
        'no encuentro $kSignSpaceGolden — corre python3 tools/gen_golden_sign_space.py');
  }
  final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final tol = (data['tolerance'] as num).toDouble();

  test('version y dimension coinciden con Python', () {
    expect(data['version'], kSignSpaceVersion);
    expect(data['profile_version'], kBodyProfileVersion);
    expect(data['dim'], kSignSpaceDim);
  });

  for (final c in (data['cases'] as List).cast<Map<String, dynamic>>()) {
    test('SignSpaceFrame golden: ${c['name']}', () {
      final perfil = (c['profile'] as Map?)?['measures'] as Map?;
      final got = signSpaceFrame(_pts(c['pose']), _pts(c['pose_mundo']),
          profileMeasures: perfil
              ?.map((k, v) => MapEntry(k as String, (v as num?)?.toDouble())));
      final exp = c['expected'] as Map<String, dynamic>?;
      if (exp == null) {
        expect(got, isNull);
        return;
      }
      expect(got, isNotNull);
      expect(got!.mode, exp['mode']);
      expect(got.mask, Map<String, bool>.from(exp['mask'] as Map));
      expect(got.reconstructed,
          Map<String, bool>.from(exp['reconstructed'] as Map));
      final ev = (exp['values'] as List).cast<num>();
      expect(got.values.length, ev.length);
      for (var i = 0; i < ev.length; i++) {
        expect(got.values[i], closeTo(ev[i].toDouble(), tol), reason: 'dim $i');
      }
    });
  }

  for (final c in (data['profiles'] as List).cast<Map<String, dynamic>>()) {
    test('BodyProfile golden: ${c['name']}', () {
      final frames = [
        for (final f in (c['frames'] as List).cast<Map<String, dynamic>>())
          (_pts(f['pose']), _pts(f['pose_mundo'])),
      ];
      final got = estimateBodyProfile(frames,
          declared: Map<String, String>.from(c['declared'] as Map),
          minSamples: (c['min_samples'] as num).toInt());
      final exp = c['expected'] as Map<String, dynamic>;
      expect(got.samples, exp['samples']);
      expect(
          got.capability, Map<String, String>.from(exp['capability'] as Map));
      for (final e in (exp['measures'] as Map).entries) {
        final v = e.value as num?;
        if (v == null) {
          expect(got.measures[e.key], isNull, reason: e.key as String);
        } else {
          expect(got.measures[e.key], closeTo(v.toDouble(), tol),
              reason: e.key as String);
        }
      }
      // ida y vuelta por JSON (persistencia local del perfil)
      final again = BodyProfile.fromJson(
          jsonDecode(jsonEncode(got.toJson())) as Map<String, dynamic>);
      expect(again.toJson(), got.toJson());
    });
  }

  test('BodyProfile rechaza declaraciones invalidas', () {
    expect(() => estimateBodyProfile(const [], declared: {'cola': 'absent'}),
        throwsArgumentError);
  });

  test('BodyProfile rechaza otra version al cargar', () {
    expect(
        () => BodyProfile.fromJson({'version': '0.9'}), throwsFormatException);
  });

  test('Fast User Capture exige consentimiento y no guarda frames', () {
    final capture = BodyProfileCapture(framesPerPhase: 8);
    expect(() => capture.start(consent: false), throwsStateError);
    final perfil = (data['profiles'] as List).first as Map<String, dynamic>;
    final frames = (perfil['frames'] as List).cast<Map<String, dynamic>>();
    capture.start(consent: true);
    final fases = <String>{};
    for (var i = 0; i < 8 * kBodyCapturePhases.length; i++) {
      final f = frames[i % frames.length];
      if (capture.state == BodyCaptureState.capturing)
        fases.add(capture.phase!);
      capture.push(_pts(f['pose']), _pts(f['pose_mundo']));
    }
    expect(fases, kBodyCapturePhases.map((p) => p.$1).toSet());
    expect(capture.state, BodyCaptureState.done);
    expect(capture.progress, 1.0);
    expect(capture.profile!.samples, 24);
  });
}
