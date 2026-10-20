// Captura de manos web: lo que antes vivia inline en manosDesdeResultado
// (index.html). Candidatas del detector -> compuerta anti-alucinacion ->
// compuerta de nacimiento -> lado por cadena de brazo -> mano utilizable ->
// seguimiento -> desacuerdo muneca mano/pose. Lo comparten la pagina, el
// banco de paridad (tools/rig-tests/paridad) y el port Kotlin
// (CapturaManos.kt), que debe dar la misma salida frame a frame.
import {createHandBirthGate, gateHandCandidates} from './rig_hand_gate.mjs';
// Imports de una linea: inline_viewer_modules.py los comenta al inlinear.
import {assignHandsByArmChain, classifySourceSkew, createHandTrackCoordinator, resolveAnatomicalHandSide} from './rig_tracking.mjs';
import {coord, finitePoint, handUsable} from './rig_motion_frame.mjs';

export function createHandCapture({birthFrames = 3} = {}) {
  const tracker = createHandTrackCoordinator();
  let birthGate = createHandBirthGate({frames: birthFrames});
  const wristState = {
    left: {frames: 0, reported: false},
    right: {frames: 0, reported: false},
  };

  const reset = () => {
    tracker.reset();
    birthGate = createHandBirthGate({frames: birthFrames});
    for (const state of Object.values(wristState)) {
      state.frames = 0;
      state.reported = false;
    }
  };

  /**
   * candidates: [{landmarks, label, confidence}] tal como salen del detector.
   * pose: landmarks de imagen de la pose usada en este frame (o null).
   * poseTimestampMs: instante de esa pose (skew = |t - poseTimestampMs|).
   * Los errores con `via: 'diagnostico'` la pagina los registra con
   * errorDiagnostico (marcan punto y auditoria); el resto se agrega tal cual.
   */
  const process = ({candidates = [], pose = null, timestampMs = 0,
    poseTimestampMs = null} = {}) => {
    const t = Number(timestampMs);
    const errors = [];
    const gateCandidates = candidates.map((candidate) => ({
      landmarks: candidate.landmarks,
      confidence: Number(candidate.confidence ?? .5),
    }));
    const gate = gateHandCandidates(gateCandidates, pose);
    const passed = birthGate.filter(gateCandidates, gate.accepted, gate.unanchored);
    for (const {code} of gate.rejected) errors.push({stage: 'association', code});

    const kept = passed.map((index) => candidates[index]);
    const leftShoulder = coord(pose?.[11]);
    const rightShoulder = coord(pose?.[12]);
    const shoulderWidth = finitePoint(leftShoulder) && finitePoint(rightShoulder)
      ? Math.max(.05, Math.hypot(leftShoulder.x - rightShoulder.x,
        leftShoulder.y - rightShoulder.y)) : .4;
    const raw = kept.map((candidate) => ({
      landmarks: candidate.landmarks,
      side: String(candidate.label ?? ''),
      confidence: Number(candidate.confidence ?? .5),
    }));
    const assignment = assignHandsByArmChain(raw, {
      leftShoulder,
      rightShoulder,
      leftElbow: coord(pose?.[13]),
      rightElbow: coord(pose?.[14]),
      leftWrist: coord(pose?.[15]),
      rightWrist: coord(pose?.[16]),
      leftWristVisibility: Number(pose?.[15]?.visibility ?? 1),
      rightWristVisibility: Number(pose?.[16]?.visibility ?? 1),
      shoulderWidth,
    });
    const sideAmbiguous = assignment.mode === 'ambiguous';
    if (sideAmbiguous) errors.push({stage: 'association', code: 'hand_side_ambiguous'});

    const usable = [];
    const trackCandidates = raw.map((candidate, index) => {
      const anatomy = resolveAnatomicalHandSide(assignment, index);
      const check = handUsable(candidate.landmarks);
      usable.push(check.ok);
      if (!check.ok) {
        errors.push({stage: 'capture', code: check.code, side: anatomy.side,
          landmark: check.landmark, via: 'diagnostico'});
      }
      return {
        landmarks: check.ok ? candidate.landmarks : null,
        side: check.ok ? anatomy.side : null,
        sideLocked: check.ok && anatomy.sideLocked,
        sideAmbiguous: check.ok && anatomy.sideAmbiguous,
        confidence: candidate.confidence,
      };
    });
    // Sin cadena de brazo confiable el seguimiento no recibe pista de pose
    // (usa ancho de hombros .4 y su propia continuidad).
    const poseHint = assignment.mode === 'pose_arm_chain' ? {
      leftWrist: coord(pose?.[15]),
      rightWrist: coord(pose?.[16]),
      shoulderWidth,
    } : null;
    const tracking = tracker.update(trackCandidates, poseHint, t);
    errors.push(...tracking.diagnostics.errors);

    const continuityHeld = tracking.diagnostics.errors.some((error) =>
      error.code === 'hand_assignment_hysteresis');
    const skewMode = classifySourceSkew(Math.abs(t - (poseTimestampMs ?? t))).mode;
    for (const [side, poseIndex] of [['left', 15], ['right', 16]]) {
      const handWrist = coord(tracking[side].detected?.[0]);
      const poseWrist = coord(pose?.[poseIndex]);
      if (!finitePoint(handWrist) || !finitePoint(poseWrist)) continue;
      const residual = Math.hypot(handWrist.x - poseWrist.x,
        handWrist.y - poseWrist.y) / shoulderWidth;
      // Una pose en cache hasta 120 ms mas vieja que las manos no es una
      // union rota: solo la fusion directa acusa desacuerdo, y solo si
      // persiste 3 frames (una vez por episodio).
      const disagreement = residual > .25 && !continuityHeld && skewMode === 'direct';
      const state = wristState[side];
      if (disagreement) {
        state.frames++;
        if (state.frames >= 3 && !state.reported) {
          state.reported = true;
          errors.push({stage: 'fusion', code: 'wrist_disagreement', side,
            landmark: 0, via: 'diagnostico', status: 'yellow'});
        }
      } else {
        state.frames = 0;
        state.reported = false;
      }
    }
    return {
      gate,
      passed,
      assignment,
      usable,
      sideAmbiguous,
      shoulderWidth,
      tracking,
      errors,
      // El reconocimiento conserva la evidencia cruda del detector; el render
      // del avatar usa las manos estabilizadas.
      left: tracking.left.raw ?? tracking.left.detected,
      right: tracking.right.raw ?? tracking.right.detected,
      renderLeft: tracking.left.renderLandmarks,
      renderRight: tracking.right.renderLandmarks,
      renderWrists: {
        left: tracking.left.renderLandmarks?.[0] ?? null,
        right: tracking.right.renderLandmarks?.[0] ?? null,
      },
    };
  };
  return {process, reset};
}

/** Contadores de perf (retenciones, recuperaciones, swaps, volteos). */
export function countHandEvents(counters, tracking) {
  const errors = tracking?.diagnostics?.errors ?? [];
  return {
    handHolds: (counters.handHolds ?? 0) + errors.filter((error) =>
      error.code === 'hand_position_held' || error.code === 'hand_surface_flip').length,
    handRecoveries: (counters.handRecoveries ?? 0) + ['left', 'right'].filter((side) =>
      tracking[side]?.recoveryFrames === 2 && errors.some((error) =>
        error.side === side && error.code === 'hand_recovered')).length,
    handSwaps: (counters.handSwaps ?? 0) + errors.filter((error) =>
      error.code === 'hand_identity_swap').length,
    surfaceFlips: (tracking?.left?.surfaceChanges ?? 0) +
      (tracking?.right?.surfaceChanges ?? 0),
  };
}

/**
 * Seguimiento de la captura nativa (Android, CapturaManos.kt) con la forma
 * que countHandEvents espera: `handTrack` es sourceMeta.hand_track (estado
 * por lado) y `errors`, sourceMeta.errors. Null si no hay seguimiento.
 */
export function nativeTracking(handTrack, errors = []) {
  if (!handTrack || typeof handTrack !== 'object') return null;
  const side = (s) => ({
    state: s?.state ?? 'LOST',
    surface: s?.surface ?? null,
    recoveryFrames: Number(s?.recovery_frames ?? 0),
    surfaceChanges: Number(s?.surface_changes ?? 0),
  });
  return {
    left: side(handTrack.left),
    right: side(handTrack.right),
    diagnostics: {errors: Array.isArray(errors) ? errors : []},
  };
}
