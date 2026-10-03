import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

import {
  mirrorMotionFrame,
  mirrorSignSpaceFrame,
} from '../../assets/avatar_viewer/rig_mirror.mjs';
import {SS, signSpaceFrame} from '../../assets/avatar_viewer/rig_sign_space.mjs';

const norm = JSON.parse(readFileSync(
  new URL('../../test/golden/golden_cases.json', import.meta.url), 'utf8'));
const space = JSON.parse(readFileSync(
  new URL('../../test/golden/sign_space_cases.json', import.meta.url), 'utf8'));

test('mirrorMotionFrame matches Python mirror_frame golden', () => {
  for (const c of norm.cases) {
    const got = mirrorMotionFrame(c.expected_frames[0]);
    got.forEach((v, i) => assert.ok(
      Math.abs(v - c.expected_mirror_frame0[i]) <= norm.tolerance, `${c.name} ${i}`));
  }
});

test('mirrorMotionFrame twice is identity and rejects bad frames', () => {
  const v = norm.cases[0].expected_frames[1];
  assert.deepEqual(mirrorMotionFrame(mirrorMotionFrame(v)), v);
  assert.equal(mirrorMotionFrame([1, 2, 3]), null);
});

test('mirrorSignSpaceFrame swaps sides, negates x and keeps contacts', () => {
  const c = space.cases.find((x) => x.name === 'toca_boca');
  const f = signSpaceFrame(c.pose, c.pose_mundo);
  const m = mirrorSignSpaceFrame(f);
  // la palma derecha que toca la boca pasa a ser la izquierda
  assert.equal(m.values[SS.OFF_CONTACT + SS.C_FACE_L], 1);
  assert.equal(m.values[SS.OFF_CONTACT + SS.C_FACE_R], 0);
  assert.equal(m.values[SS.OFF_PALM_L], -f.values[SS.OFF_PALM_R]);
  assert.equal(m.values[SS.OFF_PALM_L + 1], f.values[SS.OFF_PALM_R + 1]);
  assert.equal(m.values[SS.OFF_PALM_L + 2], f.values[SS.OFF_PALM_R + 2]);
  assert.equal(m.values[SS.OFF_NOSE], -f.values[SS.OFF_NOSE]);
  assert.deepEqual(mirrorSignSpaceFrame(m).values, f.values);
  const hidden = space.cases.find((x) => x.name === 'codo_oculto');
  const h = mirrorSignSpaceFrame(signSpaceFrame(hidden.pose, hidden.pose_mundo));
  assert.equal(h.mask.armR, false);
  assert.equal(h.mask.armL, true);
  assert.equal(mirrorSignSpaceFrame(null), null);
});

test('mirrorSignSpaceFrame swaps reconstructed arms too', () => {
  const c = space.cases.find((x) => x.name === 'codo_oculto_con_perfil');
  const f = signSpaceFrame(c.pose, c.pose_mundo, {profile: c.profile});
  assert.deepEqual(f.reconstructed, {armL: false, armR: true});
  assert.deepEqual(mirrorSignSpaceFrame(f).reconstructed, {armL: true, armR: false});
});
