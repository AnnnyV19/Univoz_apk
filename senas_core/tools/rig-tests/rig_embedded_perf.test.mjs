import test from 'node:test';
import assert from 'node:assert/strict';

import {createEmbeddedPerf} from '../../assets/avatar_viewer/rig_embedded_perf.mjs';

test('drain is null until a frame arrives', () => {
  const perf = createEmbeddedPerf();
  perf.renderTick();
  assert.equal(perf.drain(), null);
});

test('one second of frames becomes a perf event and resets', () => {
  const perf = createEmbeddedPerf();
  for (let i = 1; i <= 30; i++) {
    perf.frameReceived({frameId: i, receivedAtMs: i * 33, inferMs: 20,
      hasHand: i % 2 === 0, tier: 'medio', thermal: 1});
    perf.frameRendered({frameId: i, renderedAtMs: i * 33 + 10});
  }
  for (let i = 0; i < 30; i++) perf.renderTick();
  const out = perf.drain({safety_codes: {angular_velocity_exceeded: 2}});
  assert.deepEqual(out.fps, {input: 30, inference: 30, tracking: 15, pose: 30, render: 30});
  assert.equal(out.latency_ms.length, 30);
  assert.equal(out.latency_ms[0], 30);
  assert.equal(out.tier, 'medio');
  assert.equal(out.thermal, 1);
  assert.equal(out.infer_ms_p95, 20);
  assert.deepEqual(out.safety_codes, {angular_velocity_exceeded: 2});
  assert.equal(perf.drain(), null);
});

test('a frame rendered twice counts latency once', () => {
  const perf = createEmbeddedPerf();
  perf.frameReceived({frameId: 1, receivedAtMs: 100, inferMs: 5});
  perf.frameRendered({frameId: 1, renderedAtMs: 110});
  perf.frameRendered({frameId: 1, renderedAtMs: 126});
  assert.deepEqual(perf.drain().latency_ms, [15]);
});

test('garbage inference and thermal values are ignored', () => {
  const perf = createEmbeddedPerf();
  perf.frameReceived({frameId: 1, receivedAtMs: 0, inferMs: 'x', thermal: 'hot', tier: 7});
  perf.frameRendered({frameId: 1, renderedAtMs: 5});
  const out = perf.drain();
  assert.deepEqual(out.latency_ms, [5]);
  assert.equal(out.infer_ms_p95, null);
  assert.equal(out.thermal, null);
  assert.equal(out.tier, null);
});

test('pending frames are bounded', () => {
  const perf = createEmbeddedPerf();
  for (let i = 1; i <= 100; i++) perf.frameReceived({frameId: i, receivedAtMs: i});
  perf.frameRendered({frameId: 1, renderedAtMs: 200});
  perf.frameRendered({frameId: 100, renderedAtMs: 200});
  assert.deepEqual(perf.drain().latency_ms, [100]);
});
