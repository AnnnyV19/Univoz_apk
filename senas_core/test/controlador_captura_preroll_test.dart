import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:senas_core/camera_bridge.dart';
import 'package:senas_core/controlador_captura.dart';

/// Camara sin canal nativo: los frames fusionados los empuja el test.
class _CamaraFalsa extends CameraBridge {
  final fusion = StreamController<LandmarkFrame>.broadcast(sync: true);
  final preview = StreamController<LandmarkFrame>.broadcast(sync: true);
  @override
  Stream<LandmarkFrame> get frames => fusion.stream;
  @override
  Stream<LandmarkFrame> get framesPreview => preview.stream;
  @override
  Future<CamaraIniciada> iniciar({bool frontal = true}) async =>
      const CamaraIniciada(1, false);
  @override
  Future<void> detener() async {}
}

/// Frame valido (golden de sign_norm) en el instante [t].
LandmarkFrame _frame(int t) {
  final data = jsonDecode(File('test/golden/golden_cases.json').readAsStringSync())
      as Map<String, dynamic>;
  final f = ((data['cases'] as List).first as Map)['frames'][0] as Map;
  return LandmarkFrame.fromMap({
    't': t,
    'pose': f['pose'],
    'poseMundo': f['pose_mundo'],
    'left': f['left'],
    'right': f['right'],
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('el pre-roll suma lo ultimo antes de empezar y la cola se recorta',
      () async {
    final camara = _CamaraFalsa();
    final ctrl = ControladorCaptura(camara: camara);
    await ctrl.iniciar();
    // 600 ms de frames antes de que el detector diga "empezo".
    for (var t = 0; t <= 600; t += 33) {
      camara.fusion.add(_frame(t));
    }
    ctrl.empezar(preRollMs: 200);
    expect(ctrl.framesGrabados, 7, reason: 'frames de 396 a 594 ms');
    for (var t = 627; t <= 900; t += 33) {
      camara.fusion.add(_frame(t));
    }
    // El detector vio el ultimo movimiento a 660 ms; se conserva 100 ms de
    // cola y se descarta lo quieto que siguio.
    final captura = await ctrl.terminarCaptura(hastaMs: 760);
    expect(captura, isNotNull);
    expect(captura!.framesCrudos.first.timestampMs, 396);
    expect(captura.framesCrudos.last.timestampMs, 759);
    expect(ctrl.framesGrabados, 12);
    ctrl.dispose();
  });

  test('sin pre-roll ni recorte graba solo lo que llega despues', () async {
    final camara = _CamaraFalsa();
    final ctrl = ControladorCaptura(camara: camara);
    await ctrl.iniciar();
    camara.fusion.add(_frame(0));
    ctrl.empezar();
    expect(ctrl.framesGrabados, 0);
    camara.fusion.add(_frame(33));
    camara.fusion.add(_frame(66));
    final captura = await ctrl.terminarCaptura();
    expect(captura!.framesCrudos.map((f) => f.timestampMs), [33, 66]);
    ctrl.dispose();
  });
}
