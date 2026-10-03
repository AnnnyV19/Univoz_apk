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
