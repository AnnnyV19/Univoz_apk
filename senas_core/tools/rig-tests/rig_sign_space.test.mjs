import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

import {
  SIGN_SPACE_DIM,
  SIGN_SPACE_VERSION,
  SS,
  signSpaceFrame,
} from '../../assets/avatar_viewer/rig_sign_space.mjs';
import {
  BODY_PROFILE_VERSION,
  estimateBodyProfile,
  parseBodyProfile,
} from '../../assets/avatar_viewer/rig_body_profile.mjs';
import {
  createAvatarRigProfile,
  retargetArm,
} from '../../assets/avatar_viewer/rig_retarget.mjs';

const golden = JSON.parse(readFileSync(
  new URL('../../test/golden/sign_space_cases.json', import.meta.url), 'utf8'));
const tol = golden.tolerance;

test('golden version and dimension match Python', () => {
  assert.equal(golden.version, SIGN_SPACE_VERSION);
  assert.equal(golden.profile_version, BODY_PROFILE_VERSION);
  assert.equal(golden.dim, SIGN_SPACE_DIM);
});

for (const c of golden.cases) {
  test(`SignSpaceFrame golden: ${c.name}`, () => {
    const got = signSpaceFrame(c.pose, c.pose_mundo);
    if (c.expected === null) {
      assert.equal(got, null);
      return;
    }
    assert.equal(got.mode, c.expected.mode);
    assert.deepEqual(got.mask, c.expected.mask);
    got.values.forEach((value, i) =>
      assert.ok(Math.abs(value - c.expected.values[i]) <= tol, `dim ${i}`));
  });
}

test('SignSpaceFrame accepts MediaPipe JS landmark objects', () => {
  const c = golden.cases[0];
  const asObjects = (pts) => pts.map(([x, y, z, visibility]) =>
    ({x, y, z, visibility}));
  const got = signSpaceFrame(asObjects(c.pose), asObjects(c.pose_mundo));
  got.values.forEach((value, i) =>
    assert.ok(Math.abs(value - c.expected.values[i]) <= tol));
});

for (const c of golden.profiles) {
  test(`BodyProfile golden: ${c.name}`, () => {
    const got = estimateBodyProfile(
      c.frames.map((f) => [f.pose, f.pose_mundo]),
      {declared: c.declared, minSamples: c.min_samples});
    assert.equal(got.samples, c.expected.samples);
    assert.deepEqual(got.capability, c.expected.capability);
    for (const [k, v] of Object.entries(c.expected.measures)) {
      if (v === null) assert.equal(got.measures[k], null, k);
      else assert.ok(Math.abs(got.measures[k] - v) <= tol, k);
    }
    assert.deepEqual(parseBodyProfile(JSON.stringify(got)), got);
  });
}

test('BodyProfile rejects invalid declarations and foreign versions', () => {
  assert.throws(() => estimateBodyProfile([], {declared: {tail: 'absent'}}),
    RangeError);
  assert.equal(parseBodyProfile('{"version":"0.9"}'), null);
  assert.equal(parseBodyProfile('not json'), null);
});

// Avatar estilizado: hombros anchos, brazos cortos, cabeza grande.
const avatar = createAvatarRigProfile({
  shoulderL: [-0.21, 0, 0], shoulderR: [0.21, 0, 0],
  upperL: 0.24, upperR: 0.24, foreL: 0.22, foreR: 0.22,
  nose: [0, 0.30, 0.11], mouth: [0, 0.24, 0.10],
});
const sub = (a, b) => a.map((v, i) => v - b[i]);
const norm = (a) => Math.hypot(...a);

test('retarget keeps hand-to-mouth contact for any body proportions', () => {
  for (const c of golden.contact_cases) {
    const frame = signSpaceFrame(c.pose, c.pose_mundo);
    assert.equal(frame.values[SS.OFF_CONTACT + SS.C_FACE_R], 1, c.name);
    const arm = retargetArm(frame, avatar, 'R');
    assert.equal(arm.anchor, 'mouth', c.name);
    const userOffset = sub(frame.values.slice(SS.OFF_PALM_R, SS.OFF_PALM_R + 3),
      frame.values.slice(SS.OFF_MOUTH, SS.OFF_MOUTH + 3));
    const avatarOffset = sub(arm.palm, avatar.anchors.mouth)
      .map((v) => v / avatar.shoulderWidth);
    // error < 5 % del ancho de hombros del avatar
    assert.ok(norm(sub(avatarOffset, userOffset)) < 0.05, c.name);
    // el codo queda a un brazo del hombro y la muneca al alcance
    assert.ok(Math.abs(norm(sub(arm.elbow, avatar.shoulders.R)) - 0.24) < 1e-9);
    assert.ok(norm(sub(arm.wrist, avatar.shoulders.R)) <= 0.46);
  }
});

test('retarget far from the body follows limb directions on avatar bones', () => {
  const frame = signSpaceFrame(golden.cases[0].pose, golden.cases[0].pose_mundo);
  const arm = retargetArm(frame, avatar, 'L'); // brazo izquierdo colgando
  assert.equal(arm.anchor, null);
  assert.equal(arm.anchorWeight, 0);
  const dir = sub(arm.wrist, avatar.shoulders.L);
  assert.ok(dir[1] < -0.40, 'cuelga hacia abajo');
  assert.ok(norm(dir) <= 0.46 + 1e-9);
});

test('retarget returns null when the arm is masked out', () => {
  const c = golden.cases.find((x) => x.name === 'codo_oculto');
  const frame = signSpaceFrame(c.pose, c.pose_mundo);
  assert.equal(frame.mask.armL, false);
  assert.equal(retargetArm(frame, avatar, 'L'), null);
  assert.notEqual(retargetArm(frame, avatar, 'R'), null);
});

test('avatar profile rejects degenerate rigs', () => {
  assert.throws(() => createAvatarRigProfile({shoulderL: [0, 0, 0],
    shoulderR: [0, 0, 0], upperL: 1, upperR: 1, foreL: 1, foreR: 1}), RangeError);
});
