import test from 'node:test';
import assert from 'node:assert/strict';

import {
  createRigSafetyGate,
  quaternionFromEuler,
} from '../../assets/avatar_viewer/rig_safety.mjs';

const valid = (overrides = {}) => ({
  jointId: 'leftIndexProximal',
  frameId: 1,
  timestampMs: 1000,
  nowMs: 1000,
  rotation: [0, 0, 0],
  ...overrides,
});

test('Safety Gate rejects non-finite transforms and freezes only local joint', () => {
  const gate = createRigSafetyGate();
  assert.equal(gate.check(valid()).accepted, true);
  const bad = gate.check(valid({frameId: 2, timestampMs: 1033, nowMs: 1033,
    rotation: [NaN, 0, 0]}));
  assert.equal(bad.accepted, false);
  assert.equal(bad.state, 'FROZEN');
  assert.equal(bad.action, 'freeze_local');
  assert.deepEqual(bad.value, [0, 0, 0]);
  assert.equal(bad.code, 'non_finite_transform');
  assert.equal(gate.check(valid({jointId: 'rightIndexProximal', frameId: 2,
    timestampMs: 1033, nowMs: 1033, rotation: [.2, 0, 0]})).accepted, true);
});

test('Safety Gate validates lengths, limits, speed, stage and hand identity', () => {
  const common = {referenceBoneLength: 1, boneLength: 1};
  const length = createRigSafetyGate({boneLengthTolerance: .1});
  length.check(valid(common));
  assert.equal(length.check(valid({frameId: 2, timestampMs: 1033, nowMs: 1033,
    ...common, boneLength: 1.3})).code, 'bone_length_drift');

  const limits = createRigSafetyGate({jointLimits: {min: [-.5, -.5, -.5],
    max: [.5, .5, .5]}});
  limits.check(valid());
  assert.equal(limits.check(valid({frameId: 2, timestampMs: 1033, nowMs: 1033,
    rotation: [.6, 0, 0]})).code, 'joint_limit_violation');

  const speed = createRigSafetyGate({maxAngularVelocityRadS: 1});
  speed.check(valid());
  assert.equal(speed.check(valid({frameId: 2, timestampMs: 1033, nowMs: 1033,
    rotation: [1, 0, 0]})).code, 'angular_velocity_exceeded');

  const stage = createRigSafetyGate({maxSourceSkewMs: 50});
  stage.check(valid());
  assert.equal(stage.check(valid({frameId: 2, timestampMs: 1033, nowMs: 1033,
    sourceSkewMs: 90})).code, 'stage_desync');

  const hand = createRigSafetyGate();
  hand.check(valid({handId: 'left'}));
  assert.equal(hand.check(valid({frameId: 2, timestampMs: 1033, nowMs: 1033,
    handId: 'right'})).code, 'hand_identity_swap');

  const parent = createRigSafetyGate();
  parent.check(valid({parentId: 'leftHand'}));
  assert.equal(parent.check(valid({frameId: 2, timestampMs: 1033, nowMs: 1033,
    parentId: 'rightHand'})).code, 'parent_frame_mismatch');
});

test('Safety Gate detects stale frames and quaternion sign flips', () => {
  const stale = createRigSafetyGate({maxAgeMs: 100});
  assert.equal(stale.check(valid({nowMs: 1201})).code, 'stale_frame');

  const gate = createRigSafetyGate();
  const q = quaternionFromEuler([.2, 0, 0]);
  assert.equal(gate.check(valid({quaternion: q})).accepted, true);
  const flipped = q.map((value) => -value);
  const result = gate.check(valid({frameId: 2, timestampMs: 1033, nowMs: 1033,
    quaternion: flipped}));
  assert.equal(result.accepted, true);
  assert.ok(result.anomalies.includes('quaternion_flip'));
  assert.ok(result.quaternion[3] > 0);
});

test('Safety Gate audit events preserve numeric frame timestamp', () => {
  const events = [];
  const gate = createRigSafetyGate({onAudit: (event) => events.push(event)});
  gate.check(valid({frameId: 9, timestampMs: 1099, nowMs: 1099}));
  assert.equal(events[0].frame, 9);
  assert.equal(events[0].timestampMs, 1099);
});

test('Safety Gate recovers gradually without teleport and treats duplicate frame idempotently', () => {
  const gate = createRigSafetyGate({recoveryFrames: 3,
    maxAngularVelocityRadS: 100});
  gate.check(valid());
  const frozen = gate.check(valid({frameId: 2, timestampMs: 1033, nowMs: 1033,
    rotation: [NaN, 0, 0]}));
  assert.equal(frozen.applied, false);
  const first = gate.check(valid({frameId: 3, timestampMs: 1066, nowMs: 1066,
    rotation: [.6, 0, 0]}));
  const duplicate = gate.check(valid({frameId: 3, timestampMs: 1066, nowMs: 1066,
    rotation: [.6, 0, 0]}));
  assert.equal(first.state, 'RECOVERING');
  assert.ok(first.value[0] < .6);
  assert.deepEqual(duplicate, first);
  const second = gate.check(valid({frameId: 4, timestampMs: 1099, nowMs: 1099,
    rotation: [.6, 0, 0]}));
  const third = gate.check(valid({frameId: 5, timestampMs: 1132, nowMs: 1132,
    rotation: [.6, 0, 0]}));
  assert.ok(first.value[0] < second.value[0]);
  assert.ok(second.value[0] < third.value[0]);
  assert.equal(third.state, 'VALID');
});

const handQ = (angle) => ({jointId: 'left:hand',
  quaternion: [Math.sin(angle / 2), 0, 0, Math.cos(angle / 2)]});
const at = (frameId, extra = {}) => valid({frameId,
  timestampMs: 1000 + (frameId - 1) * 66, nowMs: 1000 + (frameId - 1) * 66,
  ...extra});
const angleOf = (q) => 2 * Math.acos(Math.min(1, Math.abs(q[3])));

test('Safety Gate clamps fast real turns to max velocity instead of freezing', () => {
  const gate = createRigSafetyGate({maxAngularVelocityRadS: 20,
    maxStepRad: 100 * Math.PI / 180, palmFlipRad: 120 * Math.PI / 180});
  gate.check(at(1, handQ(0)));
  const fast = gate.check(at(2, handQ(1.6)));
  assert.equal(fast.accepted, true);
  assert.ok(fast.anomalies.includes('angular_velocity_clamped'));
  const step = 20 * .066 + .02;
  assert.ok(Math.abs(angleOf(fast.quaternion) - step) < 1e-6);
  const next = gate.check(at(3, handQ(1.6)));
  assert.ok(Math.abs(angleOf(next.quaternion) - 1.6) < 1e-6);
});

test('Safety Gate rejects one-frame palm flips and accepts a sustained flip gradually', () => {
  const gate = createRigSafetyGate({maxAngularVelocityRadS: 20,
    maxStepRad: 100 * Math.PI / 180, palmFlipRad: 120 * Math.PI / 180,
    recoveryMs: 100});
  gate.check(at(1, handQ(0)));
  const flip = gate.check(at(2, handQ(Math.PI * .9)));
  assert.equal(flip.accepted, false);
  assert.equal(flip.code, 'palm_flip');
  const back = gate.check(at(3, handQ(.05)));
  assert.equal(back.accepted, true);

  const held = createRigSafetyGate({maxAngularVelocityRadS: 20,
    palmFlipRad: 120 * Math.PI / 180, recoveryMs: 100});
  held.check(at(1, handQ(0)));
  assert.equal(held.check(at(2, handQ(Math.PI * .9))).code, 'palm_flip');
  const confirmed = held.check(at(3, handQ(Math.PI * .9)));
  assert.equal(confirmed.accepted, true);
  assert.ok(confirmed.anomalies.includes('palm_flip_confirmed'));
  assert.equal(confirmed.state, 'RECOVERING');
  assert.ok(angleOf(confirmed.quaternion) < Math.PI * .9);

  const finger = createRigSafetyGate({maxAngularVelocityRadS: 20,
    palmFlipRad: 120 * Math.PI / 180});
  finger.check(at(1));
  assert.equal(finger.check(at(2, {rotation: [2.5, 0, 0]})).code,
    'angular_velocity_exceeded');
});

test('Safety Gate soft deadband damps sub-threshold jitter without steps', () => {
  const deadband = 1.5 * Math.PI / 180;
  const gate = createRigSafetyGate({angularDeadbandRad: deadband});
  gate.check(at(1, handQ(0)));
  const jitter = gate.check(at(2, handQ(deadband / 2)));
  assert.ok(Math.abs(angleOf(jitter.quaternion) - deadband / 8) < 1e-6);
  const big = gate.check(at(3, handQ(.2)));
  assert.ok(Math.abs(angleOf(big.quaternion) - .2) < 1e-6);
});

test('Safety Gate audits bone length drift without freezing in audit mode', () => {
  const gate = createRigSafetyGate({boneLengthTolerance: .1,
    boneLengthMode: 'audit'});
  gate.check(valid({referenceBoneLength: 1, boneLength: 1}));
  const drift = gate.check(at(2, {referenceBoneLength: 1, boneLength: 1.3}));
  assert.equal(drift.accepted, true);
  assert.ok(drift.anomalies.includes('bone_length_drift'));
});

test('Safety Gate recovery by time lasts the same at 15 and 60 FPS', () => {
  const run = (stepMs) => {
    const gate = createRigSafetyGate({recoveryMs: 100,
      maxAngularVelocityRadS: 100});
    gate.check(valid());
    gate.check(valid({frameId: 2, timestampMs: 1000 + stepMs,
      nowMs: 1000 + stepMs, rotation: [NaN, 0, 0]}));
    let frames = 0;
    let result;
    do {
      frames += 1;
      const t = 1000 + stepMs * (frames + 1);
      result = gate.check(valid({frameId: frames + 2, timestampMs: t, nowMs: t,
        rotation: [.6, 0, 0]}));
    } while (result.state !== 'VALID' && frames < 50);
    return frames * stepMs;
  };
  assert.ok(Math.abs(run(66) - run(16)) <= 66);
});

test('Safety Gate recovers a confirmed palm flip over its own longer time', () => {
  const gate = createRigSafetyGate({maxAngularVelocityRadS: 20,
    palmFlipRad: 120 * Math.PI / 180, recoveryMs: 100,
    palmFlipRecoveryMs: 250});
  gate.check(at(1, handQ(0)));
  assert.equal(gate.check(at(2, handQ(Math.PI * .9))).code, 'palm_flip');
  const states = [];
  for (let frame = 3; frame < 10; frame++) {
    const r = gate.check(at(frame, handQ(Math.PI * .9)));
    states.push([r.state, angleOf(r.quaternion)]);
  }
  // 66 ms por frame: 250 ms = 4 frames de recuperacion, no 2.
  assert.deepEqual(states.slice(0, 3).map(([s]) => s),
    ['RECOVERING', 'RECOVERING', 'RECOVERING']);
  assert.equal(states[3][0], 'VALID');
  for (let i = 1; i < 4; i++) assert.ok(states[i][1] > states[i - 1][1]);
  // La siguiente recuperacion normal vuelve a 100 ms.
  gate.check(at(10, {jointId: 'left:hand', rotation: [NaN, 0, 0]}));
  const r1 = gate.check(at(11, handQ(Math.PI * .9)));
  const r2 = gate.check(at(12, handQ(Math.PI * .9)));
  assert.equal(r1.state, 'RECOVERING');
  assert.equal(r2.state, 'VALID');
});
