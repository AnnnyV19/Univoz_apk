import test from 'node:test';
import assert from 'node:assert/strict';

import {
  adaptiveTauMs,
  avatarStateFrom,
  blendWeight,
  createAvatarStateTracker,
  createOutputSmoother,
  createPoseTransitions,
  shouldSolveFrame,
  slerpQuaternion,
  smoothingAlpha,
} from '../../assets/avatar_viewer/rig_avatar_state.mjs';

const qx = (angle) => [Math.sin(angle / 2), 0, 0, Math.cos(angle / 2)];
const angleOf = (q) => 2 * Math.acos(Math.min(1, Math.abs(q[3])));

test('smoothing alpha is framerate independent', () => {
  const after = (stepMs, totalMs, tauMs) => {
    let value = 0;
    for (let t = 0; t < totalMs; t += stepMs) {
      value += smoothingAlpha(stepMs, tauMs) * (1 - value);
    }
    return value;
  };
  assert.ok(Math.abs(after(16, 160, 50) - after(8, 160, 50)) < 1e-9);
  assert.ok(Math.abs(after(66, 264, 50) - after(33, 264, 50)) < 1e-9);
  assert.equal(smoothingAlpha(0, 50), 0);
  assert.equal(smoothingAlpha(16, 0), 1);
  assert.ok(Math.abs(smoothingAlpha(24 * Math.LN2, 24) - .5) < 1e-12);
});

test('blend weight eases from 0 to 1', () => {
  assert.equal(blendWeight(0, 200), 0);
  assert.equal(blendWeight(100, 200), .5);
  assert.equal(blendWeight(250, 200), 1);
  assert.ok(blendWeight(20, 200) < .2 * .5);
});

test('avatar state priority and change events', () => {
  assert.equal(avatarStateFrom({}), 'REST');
  assert.equal(avatarStateFrom({tracking: true}), 'TRACKING');
  assert.equal(avatarStateFrom({tracking: true, holding: true}), 'HOLD');
  assert.equal(avatarStateFrom({tracking: true, returning: true}), 'RETURNING');
  assert.equal(avatarStateFrom({streamLive: true, streamStale: true,
    returning: true}), 'NO_SIGNAL');
  assert.equal(avatarStateFrom({playing: true, streamStale: true}), 'PLAYBACK');

  const events = [];
  const tracker = createAvatarStateTracker({onChange: (e) => events.push(e)});
  assert.equal(tracker.update({tracking: true}, 10).changed, true);
  assert.equal(tracker.update({tracking: true}, 20).changed, false);
  tracker.update({}, 30);
  assert.deepEqual(events.map((e) => [e.from, e.to, e.t]),
    [['REST', 'TRACKING', 10], ['TRACKING', 'REST', 30]]);
});

test('slerp follows the short arc', () => {
  const half = slerpQuaternion(qx(0), qx(1), .5);
  assert.ok(Math.abs(angleOf(half) - .5) < 1e-9);
  const flipped = slerpQuaternion(qx(0), qx(1).map((v) => -v), .5);
  assert.ok(Math.abs(angleOf(flipped) - .5) < 1e-9);
});

test('rest transition eases to target and yields bones written by tracking', () => {
  const transitions = createPoseTransitions({durationMs: 200});
  const bones = {arm: qx(1), hand: qx(.5)};
  transitions.start('left', {from: {...bones}, to: {arm: qx(0), hand: qx(0)},
    nowMs: 0});
  const read = (id) => bones[id];
  const apply = ({writes}) => {
    for (const {id, quaternion} of writes) bones[id] = quaternion;
  };
  apply(transitions.step(100, read));
  assert.ok(Math.abs(angleOf(bones.arm) - .5) < 1e-9);
  bones.hand = qx(.3); // el tracking volvio y escribio la mano
  apply(transitions.step(150, read));
  assert.ok(Math.abs(angleOf(bones.hand) - .3) < 1e-12);
  assert.ok(angleOf(bones.arm) < .5);
  const last = transitions.step(200, read);
  apply(last);
  assert.deepEqual(last.done, ['left']);
  assert.ok(angleOf(bones.arm) < 1e-9);
  assert.equal(transitions.size, 0);
});

test('crossfade blends from snapshot to the pose written each render', () => {
  const transitions = createPoseTransitions({durationMs: 100});
  const bones = {arm: qx(0)};
  transitions.start('play', {from: {arm: qx(0)}, nowMs: 0});
  bones.arm = qx(1); // la reproduccion escribio su primer frame
  let result = transitions.step(50, (id) => bones[id]);
  bones.arm = result.writes[0].quaternion;
  assert.ok(Math.abs(angleOf(bones.arm) - .5) < 1e-9);
  // Render sin nueva escritura: el objetivo sigue siendo el ultimo visto.
  result = transitions.step(75, (id) => bones[id]);
  bones.arm = result.writes[0].quaternion;
  assert.ok(angleOf(bones.arm) > .5 && angleOf(bones.arm) < 1);
  bones.arm = qx(1.2);
  result = transitions.step(100, (id) => bones[id]);
  assert.ok(Math.abs(angleOf(result.writes[0].quaternion) - 1.2) < 1e-9);
  assert.deepEqual(result.done, ['play']);
});

test('newest transition owns a shared bone', () => {
  const transitions = createPoseTransitions({durationMs: 100});
  transitions.start('hand', {from: {hand: qx(1)}, to: {hand: qx(0)}, nowMs: 0});
  transitions.start('arm', {from: {hand: qx(1), arm: qx(1)},
    to: {hand: qx(0), arm: qx(0)}, nowMs: 0});
  assert.equal(transitions.has('hand'), false);
  assert.equal(transitions.has('arm'), true);
});

test('adaptive tau goes from heavy smoothing on jitter to low lag on real motion', () => {
  const params = {tauMinMs: 30, tauMaxMs: 80, fastRad: 20 * Math.PI / 180};
  assert.equal(adaptiveTauMs(0, params), 80);
  assert.equal(adaptiveTauMs(10 * Math.PI / 180, params), 55);
  assert.equal(adaptiveTauMs(Math.PI, params), 30);
});

test('output smoother spreads a camera step over renders and keeps the target', () => {
  const params = {tauMinMs: 30, tauMaxMs: 80, fastRad: 20 * Math.PI / 180};
  const smoother = createOutputSmoother();
  let written = qx(0);
  assert.deepEqual(smoother.step('arm', written, 16, params), qx(0));
  // Llega un frame de camara con 40 grados de giro; el render va a 144 Hz
  // y el tracking reescribe el mismo objetivo en cada render.
  written = qx(40 * Math.PI / 180);
  const shown = [];
  for (let i = 0; i < 10; i++) {
    shown.push(angleOf(smoother.step('arm', written, 1000 / 144, params)));
  }
  for (let i = 1; i < shown.length; i++) assert.ok(shown[i] > shown[i - 1]);
  assert.ok(shown[0] < 40 * Math.PI / 180 * .3, 'no salta en un render');
  // Render sin reescritura: el valor actual es el mostrado, sigue al objetivo.
  let current = qx(shown.at(-1));
  for (let i = 0; i < 60; i++) {
    current = smoother.step('arm', current, 1000 / 144, params);
  }
  assert.ok(Math.abs(angleOf(current) - 40 * Math.PI / 180) < 1e-3);
});

test('output smoother damps alternating jitter and follow() avoids jumps', () => {
  const params = {tauMinMs: 30, tauMaxMs: 80, fastRad: 20 * Math.PI / 180};
  const smoother = createOutputSmoother();
  const amp = 2 * Math.PI / 180;
  smoother.step('hand', qx(0), 16, params);
  let maxShown = 0;
  for (let frame = 0; frame < 60; frame++) {
    const written = qx(frame % 2 ? amp : -amp);
    for (let r = 0; r < 4; r++) {
      const q = smoother.step('hand', written, 1000 / 60, params);
      if (frame > 20) maxShown = Math.max(maxShown, angleOf(q));
    }
  }
  assert.ok(maxShown < amp * .75, `temblor atenuado: ${maxShown}`);
  smoother.follow('hand', qx(1));
  assert.ok(Math.abs(angleOf(smoother.step('hand', qx(1), 16, params)) - 1) < 1e-9);
});

test('output smoother caps angular speed per render', () => {
  const params = {tauMinMs: 30, tauMaxMs: 80, fastRad: 20 * Math.PI / 180,
    maxSpeedRadS: 720 * Math.PI / 180};
  const smoother = createOutputSmoother();
  smoother.step('hand', qx(0), 16, params);
  const target = qx(Math.PI * .9);
  let previous = 0;
  let renders = 0;
  for (; renders < 100; renders++) {
    const angle = angleOf(smoother.step('hand', target, 1000 / 60, params));
    assert.ok(angle - previous <= 12 * Math.PI / 180 + 1e-9, 'max 12 grados por render');
    previous = angle;
    if (Math.abs(angle - Math.PI * .9) < 1e-3) break;
  }
  // 162 grados a 720 grados/s: al menos ~13 renders a 60 Hz.
  assert.ok(renders >= 13, `renders ${renders}`);
});

test('a live frame is solved once, not on every render tick', () => {
  const frame = new Array(152).fill(0);
  const rig = {};
  const clave = {frame, frameId: 7, timestampMs: 1000, view: 'interlocutor',
    retarget: 'legacy', rig};
  assert.equal(shouldSolveFrame(null, clave), true);
  const resuelto = {...clave};
  // Mismo frame en el siguiente render: no se vuelve a resolver.
  assert.equal(shouldSolveFrame(resuelto, {...clave}), false);
  // Frame nuevo (id, tiempo o arreglo) o cambio de vista/retarget/avatar.
  assert.equal(shouldSolveFrame(resuelto, {...clave, frameId: 8}), true);
  assert.equal(shouldSolveFrame(resuelto, {...clave, timestampMs: 1033}), true);
  assert.equal(shouldSolveFrame(resuelto, {...clave, frame: frame.slice()}), true);
  assert.equal(shouldSolveFrame(resuelto, {...clave, view: 'espejo'}), true);
  assert.equal(shouldSolveFrame(resuelto, {...clave, retarget: 'anchors'}), true);
  assert.equal(shouldSolveFrame(resuelto, {...clave, rig: {}}), true);
  // Escritura fuera de aplicarFrame (reposo, calibracion, filtros
  // reiniciados): el visor invalida la clave y el mismo frame se resuelve.
  assert.equal(shouldSolveFrame(null, {...clave}), true);
  assert.equal(shouldSolveFrame(undefined, {...clave}), true);
});
