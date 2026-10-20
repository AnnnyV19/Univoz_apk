import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('Android usa la captura de manos de la web (CapturaManos)', () {
    final source = File(
      'android/app/src/main/kotlin/com/univoz/senas/LandmarkEngine.kt',
    ).readAsStringSync();
    final coordinator = File(
      'android/app/src/main/kotlin/com/univoz/senas/HandTrackCoordinator.kt',
    ).readAsStringSync();
    final captura = File(
      'android/app/src/main/kotlin/com/univoz/senas/CapturaManos.kt',
    ).readAsStringSync();
    final plugin = File(
      'android/app/src/main/kotlin/com/univoz/senas/LandmarkPlugin.kt',
    ).readAsStringSync();
    final appPlugin = File(
      '../univoz/android/app/src/main/kotlin/LandmarkPlugin.kt',
    ).readAsStringSync();

    // El comportamiento lo fija ParidadManosTest (JUnit) contra el fixture
    // que genera la web; aqui solo que el engine delega y no reimplementa.
    expect(
        File('android/app/src/test/kotlin/com/univoz/senas/'
                'ParidadManosTest.kt')
            .existsSync(),
        isTrue);
    expect(File('test/golden/paridad_manos.jsonl.gz').existsSync(), isTrue);
    expect(source, contains('private val captura = CapturaManos()'));
    expect(source, contains('captura.process(candidatas, pose'));
    // Reconocimiento con la evidencia cruda aunque el seguimiento retenga.
    expect(source, contains('r.left,'));
    expect(source, contains('"pose_pending"'));
    for (final viejo in [
      'renderAt(',
      'poseTieneCadenaBrazo',
      'asignarLadosCadena',
      'MIN_POSE_WRIST_VISIBILITY',
      'private fun ladoFisicoMano(',
      'private fun ladoPorMunecaPose(',
    ]) {
      expect(source, isNot(contains(viejo)), reason: viejo);
    }
    expect(captura, contains('fun assignHandsByArmChain('));
    expect(captura, contains('abs(normal - crossed) >= margin'));
    expect(captura, contains('if (assignment.mode == "pose_arm_chain")'));
    expect(captura, contains('fun handUsable('));
    expect(coordinator, contains('sideAmbiguous'));
    expect(coordinator, contains('hand_side_ambiguous'));
    expect(coordinator, contains('hand_surface_ambiguous'));
    expect(coordinator, contains('gateAssignmentMode'));
    expect(plugin, contains('rotationDegrees'));
    expect(plugin, contains('payload["hands_in"] = f.handsIn'));
    for (final implementation in [plugin, appPlugin]) {
      expect(implementation, contains('sessionToken'));
      expect(implementation, contains('camera_start_cancelled'));
      expect(implementation, contains('camera_permission'));
      expect(implementation, contains('limpiarRecursos'));
    }
  });

  test('CameraX keeps hand cadence and halves pose workload', () {
    final source = File(
      'android/app/src/main/kotlin/com/univoz/senas/LandmarkPlugin.kt',
    ).readAsStringSync();
    expect(source, contains('INTERVALO_MIN_POSE_NS = 66_000_000L'));
    // La resolucion de analisis sale del nivel por dispositivo; el nivel
    // alto conserva 360x480 (DeviceTier.kt).
    expect(source, contains('Size(cfg.analisisAncho, cfg.analisisAlto)'));
    final tier = File(
      'android/app/src/main/kotlin/com/univoz/senas/DeviceTier.kt',
    ).readAsStringSync();
    expect(tier, contains('Nivel.ALTO -> TierConfig(360, 480, 30, true, 100.0)'));
    expect(source, contains('STRATEGY_KEEP_ONLY_LATEST'));
    expect(source, contains('"espejo" to false'));
  });
}
