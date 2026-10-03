import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

import {
  SIGN_SPACE_DIM,
  SIGN_SPACE_VERSION,
  SS,
  createSignSpaceFilter,
  parseSignSpaceFrame,
  parseSignSpaceSequence,
  signSpaceFrame,
} from '../../assets/avatar_viewer/rig_sign_space.mjs';
import {
  BODY_CAPTURE_PHASES,
  BODY_PROFILE_VERSION,
  createBodyProfileCapture,
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
    const got = signSpaceFrame(c.pose, c.pose_mundo, {profile: c.profile ?? null});
    if (c.expected === null) {
      assert.equal(got, null);
      return;
    }
    assert.equal(got.mode, c.expected.mode);
    assert.deepEqual(got.mask, c.expected.mask);
    assert.deepEqual(got.reconstructed, c.expected.reconstructed);
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

test('parseSignSpaceFrame accepts bridge JSON and rejects broken frames', () => {
  const frame = signSpaceFrame(golden.cases[0].pose, golden.cases[0].pose_mundo);
  assert.deepEqual(parseSignSpaceFrame(JSON.parse(JSON.stringify(frame))), frame);
  assert.equal(parseSignSpaceFrame(null), null);
  assert.equal(parseSignSpaceFrame({...frame, version: '0.1'}), null);
  assert.equal(parseSignSpaceFrame({...frame, values: frame.values.slice(1)}), null);
  assert.equal(parseSignSpaceFrame({...frame,
    values: frame.values.map((v, i) => (i === 3 ? NaN : v))}), null);
  assert.equal(parseSignSpaceFrame({...frame, mask: {armL: true}}), null);
});

test('parseSignSpaceSequence pairs one entry per 152D frame', () => {
  const frame = signSpaceFrame(golden.cases[0].pose, golden.cases[0].pose_mundo);
  const track = JSON.parse(JSON.stringify([frame, null, frame]));
  assert.deepEqual(parseSignSpaceSequence(track, 3), [frame, null, frame]);
  assert.equal(parseSignSpaceSequence(track, 4), null, 'longitud distinta');
  assert.equal(parseSignSpaceSequence([null, null], 2), null, 'pista vacia');
  assert.equal(parseSignSpaceSequence([{...frame, version: 'x'}], 1), null);
  assert.equal(parseSignSpaceSequence(undefined, 32), null);
});

test('Fast User Capture needs consent, walks 3 phases and keeps no frames', () => {
  const capture = createBodyProfileCapture({framesPerPhase: 8});
  assert.throws(() => capture.start(), /consentimiento/);
  assert.equal(capture.push(golden.cases[0].pose, golden.cases[0].pose_mundo).state,
    'idle', 'sin start no captura');
  capture.start({consent: true});
  const frames = golden.profiles[0].frames;
  const seen = new Set();
  let status;
  for (let i = 0; i < 8 * BODY_CAPTURE_PHASES.length; i++) {
    const f = frames[i % frames.length];
    status = capture.push(f.pose, f.pose_mundo);
    if (status.state === 'capturing') seen.add(status.phase);
  }
  assert.deepEqual([...seen], BODY_CAPTURE_PHASES.map((p) => p.id));
  assert.equal(status.state, 'done');
  assert.equal(status.progress, 1);
  assert.equal(status.profile.samples, 24);
  assert.ok(Math.abs(status.profile.measures.shoulderWidth -
    golden.profiles[0].expected.measures.shoulderWidth) < 0.01);
});

test('Fast User Capture ignores frames without visible shoulders', () => {
  const capture = createBodyProfileCapture({framesPerPhase: 2});
  capture.start({consent: true});
  const c = golden.cases.find((x) => x.name === 'sin_hombro');
  assert.equal(capture.push(c.pose, c.pose_mundo).progress, 0);
});

const baseFrame = () => signSpaceFrame(golden.cases[0].pose, golden.cases[0].pose_mundo);
const withValues = (frame, fn) => ({...frame, values: frame.values.map(fn),
  mask: {...frame.mask}});

test('SignSpace filter reduces jitter and keeps directions unit length', () => {
  const f = createSignSpaceFilter();
  const frame = baseFrame();
  let seed = 3;
  const noise = () => ((seed = (seed * 16807) % 2147483647) / 2147483647 - 0.5) * 0.06;
  const rawDev = [], outDev = [];
  for (let k = 0; k < 90; k++) {
    const noisy = withValues(frame, (v, i) => (i < 30 ? v + noise() : v));
    const out = f.filter(noisy, k * 33);
    if (k > 30) {
      rawDev.push(Math.abs(noisy.values[SS.OFF_PALM_R] - frame.values[SS.OFF_PALM_R]));
      outDev.push(Math.abs(out.values[SS.OFF_PALM_R] - frame.values[SS.OFF_PALM_R]));
    }
    for (const off of [SS.OFF_UPPER_L, SS.OFF_FORE_R, SS.OFF_HANDDIR_R]) {
      assert.ok(Math.abs(Math.hypot(...out.values.slice(off, off + 3)) - 1) < 1e-9);
    }
  }
  const mean = (xs) => xs.reduce((a, b) => a + b, 0) / xs.length;
  assert.ok(mean(outDev) < mean(rawDev) * 0.6, `${mean(outDev)} vs ${mean(rawDev)}`);
});

test('SignSpace filter follows a real move within 300 ms', () => {
  const f = createSignSpaceFilter();
  const frame = baseFrame();
  for (let k = 0; k < 10; k++) f.filter(frame, k * 33);
  const moved = withValues(frame, (v, i) => (i === SS.OFF_PALM_R ? v + 0.5 : v));
  let out;
  for (let k = 10; k < 20; k++) out = f.filter(moved, k * 33);
  assert.ok(Math.abs(out.values[SS.OFF_PALM_R] - moved.values[SS.OFF_PALM_R]) < 0.05);
});

test('SignSpace filter resets masked groups and holds contacts briefly', () => {
  const f = createSignSpaceFilter({releaseFrames: 2});
  const frame = baseFrame();
  const contact = SS.OFF_CONTACT + SS.C_CHEST_R;
  assert.equal(frame.values[contact], 1);
  f.filter(frame, 0);
  const lost = withValues(frame, (v, i) => (i === contact ? 0 : v));
  assert.equal(f.filter(lost, 33).values[contact], 1, 'histeresis');
  assert.equal(f.filter(lost, 66).values[contact], 0);
  const hidden = {...frame, mask: {...frame.mask, armL: false},
    values: frame.values.map((v, i) => (i < 6 ? 0 : v))};
  assert.deepEqual(f.filter(hidden, 99).values.slice(0, 6), [0, 0, 0, 0, 0, 0]);
  const back = f.filter(frame, 132);
  back.values.slice(0, 6).forEach((v, i) =>
    assert.ok(Math.abs(v - frame.values[i]) < 1e-12, 'reinicia sin arrastre'));
});
