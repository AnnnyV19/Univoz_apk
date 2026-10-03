import test from 'node:test';
import assert from 'node:assert/strict';

import {
  createHandBirthGate,
  gateHandCandidates,
} from '../../assets/avatar_viewer/rig_hand_gate.mjs';

// Persona de frente en coordenadas de imagen: hombros a 0.2 de ancho.
function pose({leftWrist = [0.62, 0.70], rightWrist = [0.38, 0.70],
  wristVis = 0.9} = {}) {
  const p = Array.from({length: 33}, () => ({x: .5, y: .5, z: 0, visibility: .9}));
  p[11] = {x: 0.60, y: 0.40, z: 0, visibility: .99};
  p[12] = {x: 0.40, y: 0.40, z: 0, visibility: .99};
  p[13] = {x: 0.62, y: 0.55, z: 0, visibility: .9};
  p[14] = {x: 0.38, y: 0.55, z: 0, visibility: .9};
  p[15] = {x: leftWrist[0], y: leftWrist[1], z: 0, visibility: wristVis};
  p[16] = {x: rightWrist[0], y: rightWrist[1], z: 0, visibility: wristVis};
  return p;
}

// Mano: muneca en (x, y), nudillo medio `size` mas arriba.
function hand(x, y, size = 0.06, confidence = 0.9) {
  const lm = Array.from({length: 21}, (_, i) => ({x: x + (i % 5) * size * 0.1,
    y: y - size * (0.3 + (i % 4) * 0.25), z: 0}));
  lm[0] = {x, y, z: 0};
  lm[9] = {x, y: y - size, z: 0};
  return {landmarks: lm, side: '', confidence};
}

test('accepts hands at the pose wrists', () => {
  const r = gateHandCandidates([hand(0.62, 0.70), hand(0.38, 0.70)], pose());
  assert.deepEqual(r.accepted, [0, 1]);
  assert.deepEqual(r.rejected, []);
});

test('drops a duplicate detection of the same hand, keeps the stronger', () => {
  const r = gateHandCandidates([hand(0.62, 0.70, 0.06, 0.6),
    hand(0.625, 0.705, 0.06, 0.95)], pose());
  assert.deepEqual(r.accepted, [1]);
  assert.deepEqual(r.rejected, [{index: 0, code: 'hand_duplicate'}]);
});

test('rejects a hand far from both visible arms (face, background)', () => {
  const r = gateHandCandidates([hand(0.50, 0.20)], pose());
  assert.deepEqual(r.accepted, []);
  assert.equal(r.rejected[0].code, 'hand_far_from_arm');
});

test('rejects implausible hand sizes', () => {
  const tiny = gateHandCandidates([hand(0.62, 0.70, 0.005)], pose());
  assert.equal(tiny.rejected[0].code, 'hand_scale_implausible');
  const huge = gateHandCandidates([hand(0.62, 0.70, 0.30)], pose());
  assert.equal(huge.rejected[0].code, 'hand_scale_implausible');
});

test('hands with no visible pose wrist pass as unanchored', () => {
  const r = gateHandCandidates([hand(0.50, 0.20)], pose({wristVis: 0.1}));
  assert.deepEqual(r.accepted, [0]);
  assert.deepEqual(r.unanchored, [0]);
});

test('without shoulders the gate does not block (fallback to old path)', () => {
  const p = pose();
  p[11].visibility = 0.1;
  const r = gateHandCandidates([hand(0.5, 0.2)], p);
  assert.deepEqual(r.accepted, [0]);
});

test('birth gate needs consecutive frames for unanchored hands only', () => {
  const gate = createHandBirthGate({frames: 3});
  const c = [hand(0.5, 0.2)];
  assert.deepEqual(gate.filter(c, [0], [0]), []);
  assert.deepEqual(gate.filter(c, [0], [0]), []);
  assert.deepEqual(gate.filter(c, [0], [0]), [0]);
  // una mano anclada al brazo pasa al instante
  assert.deepEqual(gate.filter([hand(0.62, 0.70)], [0], []), [0]);
  // si la mano sin ancla salta de lugar, vuelve a contar
  const g2 = createHandBirthGate({frames: 2});
  g2.filter([hand(0.5, 0.2)], [0], [0]);
  assert.deepEqual(g2.filter([hand(0.8, 0.8)], [0], [0]), []);
});
