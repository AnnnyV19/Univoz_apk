import test from 'node:test';
import assert from 'node:assert/strict';

import {
  FACE_IDX,
  blendshapesToVrmExpressions,
  headRotationFromFace,
  mirrorFaceSignals,
} from '../../assets/avatar_viewer/rig_face.mjs';

// Cara sintetica en coordenadas de la persona (metros aprox.): +x su
// izquierda vista por camara (derecha de la imagen), +y arriba, +z hacia
// la camara. Se rota y se pasa a coordenadas de imagen de MediaPipe.
function face({yaw = 0, pitch = 0, roll = 0} = {}) {
  const base = {
    [FACE_IDX.RIGHT_EYE_OUTER]: [-0.045, 0.03, 0],
    [FACE_IDX.LEFT_EYE_OUTER]: [0.045, 0.03, 0],
    [FACE_IDX.FOREHEAD]: [0, 0.09, 0],
    [FACE_IDX.CHIN]: [0, -0.09, 0],
    [FACE_IDX.NOSE_TIP]: [0, 0, 0.03],
  };
  const rot = ([x, y, z]) => {
    // roll (z), luego pitch (x, mirar arriba = +), luego yaw (y, girar a
    // su izquierda = nariz hacia +x)
    let c = Math.cos(roll), s = Math.sin(roll);
    [x, y] = [c * x - s * y, s * x + c * y];
    c = Math.cos(pitch); s = Math.sin(pitch);
    [y, z] = [c * y + s * z, -s * y + c * z];
    c = Math.cos(yaw); s = Math.sin(yaw);
    [x, z] = [c * x + s * z, -s * x + c * z];
    return [x, y, z];
  };
  const out = Array.from({length: 478}, () => ({x: .5, y: .5, z: 0}));
  for (const [i, p] of Object.entries(base)) {
    const [x, y, z] = rot(p);
    out[i] = {x: 0.5 + x, y: 0.5 - y, z: -z};
  }
  return out;
}

const close = (a, b, tol = 1e-6) => assert.ok(Math.abs(a - b) < tol, `${a} vs ${b}`);

test('head rotation recovers yaw, pitch and roll of a synthetic face', () => {
  const r0 = headRotationFromFace(face());
  close(r0.yaw, 0); close(r0.pitch, 0); close(r0.roll, 0);
  close(headRotationFromFace(face({yaw: 0.4})).yaw, 0.4);
  close(headRotationFromFace(face({pitch: 0.3})).pitch, 0.3);
  close(headRotationFromFace(face({roll: -0.25})).roll, -0.25);
  const mix = headRotationFromFace(face({yaw: -0.3, pitch: 0.2, roll: 0.1}));
  close(mix.yaw, -0.3, 1e-6); close(mix.pitch, 0.2, 1e-6); close(mix.roll, 0.1, 1e-6);
});

test('head rotation corrects non-square video aspect', () => {
  const f = face({yaw: 0.35}).map((p) => ({...p, x: 0.5 + (p.x - 0.5) / (4 / 3),
    z: p.z / (4 / 3)}));
  close(headRotationFromFace(f, {aspect: 4 / 3}).yaw, 0.35);
});

test('head rotation rejects incomplete faces', () => {
  assert.equal(headRotationFromFace(null), null);
  assert.equal(headRotationFromFace(face().slice(0, 100)), null);
});

test('blendshapes map to clamped VRM 1.0 expressions', () => {
  const e = blendshapesToVrmExpressions({
    eyeBlinkLeft: 0.9, eyeBlinkRight: 0.1, jawOpen: 0.7,
    mouthPucker: 0.2, mouthFunnel: 0.5, mouthSmileLeft: 0.6,
    mouthSmileRight: 0.4, browInnerUp: 1.4, browDownLeft: 0.2,
    browDownRight: 0.4,
  });
  assert.equal(e.blinkLeft, 0.9);
  assert.equal(e.blinkRight, 0.1);
  assert.equal(e.aa, 0.7);
  assert.equal(e.ou, 0.5);
  close(e.happy, 0.5);
  assert.ok(e.surprised <= 1);
  close(e.angry, 0.3);
  assert.deepEqual(blendshapesToVrmExpressions(null), {});
});

test('mirror swaps eyes and negates yaw and roll', () => {
  const m = mirrorFaceSignals({blinkLeft: 1, blinkRight: 0, aa: .5},
    {yaw: .2, pitch: .1, roll: -.3});
  assert.deepEqual(m.expressions, {blinkLeft: 0, blinkRight: 1, aa: .5});
  assert.deepEqual(m.head, {yaw: -.2, pitch: .1, roll: .3});
});
