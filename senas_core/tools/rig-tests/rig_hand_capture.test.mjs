import test from 'node:test';
import assert from 'node:assert/strict';

import {
  countHandEvents,
  createHandCapture,
  nativeTracking,
} from '../../assets/avatar_viewer/rig_hand_capture.mjs';

const coord = (x, y, z = 0, visibility = 1) => ({x, y, z, visibility});

// Mano plausible con la muneca en (x, y).
function hand(x, y) {
  const forma = [[0, 0], [-.06, -.05], [-.11, -.10], [-.14, -.16], [-.16, -.22],
    [-.04, -.08], [-.05, -.16], [-.06, -.24], [-.06, -.32], [0, -.10],
    [0, -.20], [0, -.30], [0, -.40], [.04, -.09], [.06, -.18], [.07, -.26],
    [.08, -.34], [.08, -.06], [.11, -.13], [.13, -.19], [.14, -.24]];
  return forma.map(([dx, dy], i) => coord(x + dx * .4, y + dy * .4,
    i === 0 ? 0 : -.02 - i * .001, 0));
}

// Pose con munecas en (.30, .70) izquierda anatomica y (.70, .70) derecha.
function pose({wristVis = 1} = {}) {
  const p = Array.from({length: 33}, () => coord(.5, .5));
  p[11] = coord(.62, .35); p[12] = coord(.38, .35);
  p[13] = coord(.68, .55); p[14] = coord(.32, .55);
  p[15] = coord(.70, .70, 0, wristVis); p[16] = coord(.30, .70, 0, wristVis);
  return p;
}

const frame = (t, candidatas, extra = {}) => ({
  pose: pose(), timestampMs: t, poseTimestampMs: t, ...extra,
  candidates: candidatas.map(([x, y, label, confidence = 1]) =>
    ({landmarks: hand(x, y), label, confidence})),
});

test('two hands near their wrists get anatomical sides and raw landmarks', () => {
  const captura = createHandCapture();
  let r;
  for (let i = 0; i < 4; i++) {
    r = captura.process(frame(1000 + i * 33,
      [[.70, .70, 'Left'], [.30, .70, 'Right']]));
  }
  assert.equal(r.assignment.mode, 'pose_arm_chain');
  assert.deepEqual(r.assignment.sideByIndex, ['left', 'right']);
  assert.equal(r.tracking.left.state, 'TRACKING');
  assert.equal(r.left, r.tracking.left.raw);
  assert.equal(r.renderWrists.left, r.tracking.left.renderLandmarks[0]);
  assert.deepEqual(r.usable, [true, true]);
});

test('gate rejections are association errors without side', () => {
  const captura = createHandCapture();
  const r = captura.process(frame(1000, [[.70, .70, 'Left'], [.701, .701, 'Left', .5]]));
  assert.ok(r.gate.rejected.some((e) => e.code === 'hand_duplicate'));
  assert.ok(r.errors.some((e) => e.stage === 'association' &&
    e.code === 'hand_duplicate' && e.side == null));
});

test('an unusable hand reaches the tracker without landmarks', () => {
  const captura = createHandCapture();
  const malo = hand(.70, .70);
  malo[12] = coord(.70, .0); // falange imposible
  for (let i = 0; i < 4; i++) {
    const r = captura.process({pose: pose(), timestampMs: 1000 + i * 33,
      poseTimestampMs: 1000 + i * 33,
      candidates: [{landmarks: malo, label: 'Left', confidence: 1}]});
    if (i === 3) {
      assert.deepEqual(r.usable, [false]);
      assert.equal(r.tracking.left.detected, null);
      assert.ok(r.errors.some((e) => e.stage === 'capture' &&
        e.code === 'hand_segment_invalid' && e.side === 'left' && e.landmark === 12));
      assert.ok(r.errors.some((e) => e.code === 'hand_landmarks_invalid'));
    }
  }
});

test('wrist disagreement needs 3 direct frames and is reported once', () => {
  const desfasada = (t, skew) => {
    const f = frame(t, [[.80, .70, 'Left']]);
    f.poseTimestampMs = t - skew;
    return f;
  };
  const captura = createHandCapture();
  const reportes = [];
  for (let i = 0; i < 8; i++) {
    const r = captura.process(desfasada(1000 + i * 33, 0));
    reportes.push(r.errors.filter((e) => e.code === 'wrist_disagreement').length);
  }
  assert.equal(reportes.reduce((a, b) => a + b, 0), 1);
  assert.equal(reportes.indexOf(1) >= 2, true);
  // Con pose 80 ms mas vieja (proyeccion) no se acusa desacuerdo.
  const proyectada = createHandCapture();
  for (let i = 0; i < 8; i++) {
    const r = proyectada.process(desfasada(1000 + i * 33, 80));
    assert.equal(r.errors.some((e) => e.code === 'wrist_disagreement'), false);
  }
});

test('countHandEvents accumulates holds, recoveries, swaps and surface flips', () => {
  const tracking = {
    left: {recoveryFrames: 2, surfaceChanges: 1},
    right: {recoveryFrames: 0, surfaceChanges: 2},
    diagnostics: {errors: [
      {code: 'hand_position_held', side: 'left'},
      {code: 'hand_surface_flip', side: 'right'},
      {code: 'hand_recovered', side: 'left'},
      {code: 'hand_identity_swap', side: 'right'},
    ]},
  };
  const c = countHandEvents({handHolds: 1, handRecoveries: 0, handSwaps: 0,
    surfaceFlips: 0}, tracking);
  assert.deepEqual(c, {handHolds: 3, handRecoveries: 1, handSwaps: 1, surfaceFlips: 3});
});

test('native (Android) tracking feeds the same counters', () => {
  // sourceMeta.hand_track y sourceMeta.errors de CapturaManos.kt.
  const tracking = nativeTracking({
    left: {state: 'TRACKING', recovery_frames: 2, surface_changes: 1},
    right: {state: 'OCCLUDED', recovery_frames: 0, surface_changes: 0},
  }, [
    {stage: 'association', code: 'hand_recovered', side: 'left'},
    {stage: 'association', code: 'hand_position_held', side: 'right'},
  ]);
  assert.deepEqual(countHandEvents({}, tracking),
    {handHolds: 1, handRecoveries: 1, handSwaps: 0, surfaceFlips: 1});
  assert.equal(nativeTracking(null, []), null);
});
