import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:senas_core/body_profile.dart';
import 'package:senas_core/camera_bridge.dart';
import 'package:senas_core/muestras_locales.dart';
import 'package:senas_core/sesion_captura.dart';

void main() {
  test('id de sesion ordenable por fecha', () {
    expect(nuevoIdSesion(DateTime.utc(2026, 10, 2, 21, 0, 0)),
        matches(RegExp(r'^20261002T210000Z-[a-z0-9]{6}$')));
  });

  test('cabecera, seq, lotes y cierre como rig_session.mjs', () async {
    final lotes = <List<String>>[];
    final s = SesionCaptura(
      sessionId: 's1',
      meta: {'platform': 'android'},
      flushEvery: 3,
      sumidero: (id, l) async {
        lotes.add(l);
        return true;
      },
      ahora: () => 1000,
    );
    s.frame({'t': 1});
    s.evento('camera_start', {'fps': 30});
    await Future<void>.delayed(Duration.zero);
    expect(lotes, hasLength(1));
    final regs = lotes.first.map((l) => jsonDecode(l) as Map).toList();
    expect(regs.map((r) => r['kind']), ['session_start', 'frame', 'event']);
    expect(regs.map((r) => r['seq']), [0, 1, 2]);
    expect(regs.first['schema'], kSessionSchema);
    s.frame({'t': 2});
    await s.cerrar(razon: 'stop');
    final fin = jsonDecode(lotes.last.last) as Map;
    expect(fin['kind'], 'session_end');
    expect(fin['frames'], 2);
    s.frame({'t': 3});
    expect(s.stats['frames'], 2, reason: 'cerrada no graba');
  });

  test('si el sumidero falla conserva y reintenta; cola acotada', () async {
    var falla = true;
    final recibidas = <String>[];
    final s = SesionCaptura(
      sessionId: 's2',
      flushEvery: 1000,
      maxPending: 50,
      sumidero: (id, l) async {
        if (falla) return false;
        recibidas.addAll(l);
        return true;
      },
    );
    for (var i = 0; i < 200; i++) {
      s.frame({'t': i});
    }
    expect(await s.flush(), isFalse);
    expect(s.stats['pending'], lessThanOrEqualTo(50));
    expect(s.stats['dropped'], greaterThan(0));
    falla = false;
    expect(await s.flush(), isTrue);
    expect(jsonDecode(recibidas.first)['kind'], 'session_start');
  });

  test('sumidero de archivo anexa JSONL', () async {
    final dir = await Directory.systemTemp.createTemp('sesion');
    final sink = sumideroArchivo(Directory('${dir.path}/sesiones'));
    await sink('abc123', ['{"a":1}']);
    await sink('abc123', ['{"a":2}', '{"a":3}']);
    final lineas =
        await File('${dir.path}/sesiones/abc123.jsonl').readAsLines();
    expect(lineas, ['{"a":1}', '{"a":2}', '{"a":3}']);
    await dir.delete(recursive: true);
  });

  test('frameDeSesion compacta un LandmarkFrame', () {
    final pose = List<double>.filled(33 * 4, 0);
    for (var i = 0; i < 33; i++) {
      pose[i * 4 + 3] = .8;
    }
    pose[11 * 4] = .3123456;
    final f = LandmarkFrame.fromMap({
      't': 7,
      'pose': pose,
      'poseMundo': null,
      'left': null,
      'right': null,
      'capture_mode': 'holistic',
      'errors': [
        {'stage': 'association', 'code': 'hand_duplicate'}
      ],
    });
    final r = frameDeSesion(f, id: 1);
    expect(r['mode'], 'holistic');
    expect((r['pose'] as List)[11][0], .3123);
    expect(r['errors'], ['hand_duplicate']);
    expect(r['vec'], isNull);
    expect(jsonEncode(r), isNotEmpty);
  });

  test('frameDeSesion de Android usa el esquema de sesion web', () {
    final lm = List<double>.generate(63, (i) => .4 + i * 1e-5 + 1.23456e-7);
    final f = LandmarkFrame.fromMap({
      't': 70,
      'pose': null,
      'poseMundo': null,
      'left': lm,
      'right': null,
      'pose_t': 40,
      'hands_t': 70,
      'infer_ms': 81.25,
      'tier': 'alto',
      'capture_mode': 'holistic',
      'hands_in': {
        'candidates': [
          {'lm': lm, 'label': 'Left', 'conf': .912345},
        ],
        'accepted': [0],
        'unanchored': [],
        'rejected': [
          [1, 'hand_duplicate'],
        ],
        'passed': [0],
        'assignment': {'mode': 'fallback', 'sides': [null]},
        'usable': [true],
      },
      'track': {
        'left': {'state': 'TRACKING', 'surface': 'palm'},
        'right': {'state': 'LOST', 'surface': null},
      },
      'pose_ran': false,
    });
    final r = frameDeSesion(f, id: 3);
    final hands = r['hands'] as Map<String, dynamic>;
    final cand = (hands['candidates'] as List).single as Map<String, dynamic>;
    // Mismo formato que index.html (compactLandmarks a 4 cifras, conf a 3)
    // para que replay_sesion.mjs reproduzca la captura del telefono.
    expect((cand['lm'] as List).first, [.4, .4, .4]);
    expect(cand['label'], 'Left');
    expect(cand['conf'], .912);
    expect(hands['accepted'], [0]);
    expect(hands['rejected'], [
      {'index': 1, 'code': 'hand_duplicate'}
    ]);
    expect(hands['passed'], [0]);
    expect(hands['assignment'], {'mode': 'fallback', 'sides': [null]});
    expect(r['tracked'], {
      'left': true,
      'right': false,
      'left_surface': 'palm',
      'right_surface': null,
      'left_state': 'TRACKING',
      'right_state': 'LOST',
    });
    expect(r['pose_ran'], isFalse);
    expect(r['skew_ms'], 30);
    expect(r['ms'], {'infer': 81.25});
    expect(r['tier'], 'alto');
    expect(r['quality'], 0.0);
    expect(jsonEncode(r), isNotEmpty);
  });

  test('Ajustes persiste consentimiento y perfil corporal', () {
    final perfil = estimateBodyProfile(const []);
    final a = Ajustes(consentimientoSesion: true, perfilCorporal: perfil);
    final b = Ajustes.fromJson(jsonDecode(jsonEncode(a.toJson())) as Map<String, dynamic>);
    expect(b.consentimientoSesion, isTrue);
    expect(b.perfilCorporal!.toJson(), perfil.toJson());
    final viejo = Ajustes.fromJson({'body_profile': {'version': '0.1'}});
    expect(viejo.perfilCorporal, isNull, reason: 'version vieja se vuelve a medir');
    expect(viejo.consentimientoSesion, isFalse);
  });
}
