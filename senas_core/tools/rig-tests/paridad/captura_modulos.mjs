// Captura de manos del banco de paridad armada con los modulos de la pagina
// (rig_hand_capture + rig_motion_frame), con la misma forma de salida que
// replay.esperadoDe consume.
import {createHandCapture} from '../../../assets/avatar_viewer/rig_hand_capture.mjs';
import {
  frameQuality, normalizeMotionFrame,
} from '../../../assets/avatar_viewer/rig_motion_frame.mjs';

export function createCapturaModulos() {
  const captura = createHandCapture();
  const process = (frame) => {
    const r = captura.process({
      candidates: frame.candidatas.map((c) => ({
        landmarks: c.landmarks, label: c.label, confidence: c.conf,
      })),
      pose: frame.pose,
      timestampMs: frame.t,
      poseTimestampMs: frame.t - (frame.skewMs ?? 0),
    });
    const vector = normalizeMotionFrame(frame.pose, frame.world, r.left, r.right);
    const render = normalizeMotionFrame(frame.pose, frame.world,
      r.renderLeft ?? r.left, r.renderRight ?? r.right,
      {renderWrists: r.renderWrists});
    return {
      entrada: {
        accepted: r.gate.accepted, unanchored: r.gate.unanchored,
        rejected: r.gate.rejected, passed: r.passed,
        assignment: {mode: r.assignment.mode, sides: r.assignment.sideByIndex},
      },
      usable: r.usable,
      manos: {tracking: r.tracking},
      errCaptura: r.errors,
      vec: vector.vector,
      vecRender: render.vector,
      errVector: vector.errors,
      quality: vector.vector
        ? frameQuality(frame.pose, frame.world, r.left, r.right) : 0,
    };
  };
  return {process};
}
