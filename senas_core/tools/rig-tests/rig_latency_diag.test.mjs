import test from 'node:test';
import assert from 'node:assert/strict';

import {
  createLatencyDiag,
  createSeries,
} from '../../assets/avatar_viewer/rig_latency_diag.mjs';

test('series summary gives p50, p95 and max', () => {
  const s = createSeries();
  for (let i = 1; i <= 100; i++) s.push(i);
  assert.deepEqual(s.summary(), {n: 100, p50: 50, p95: 95, max: 100});
});

test('empty series has null percentiles', () => {
  assert.deepEqual(createSeries().summary(), {n: 0, p50: null, p95: null, max: null});
});

test('series is a ring: the oldest samples fall out', () => {
  const s = createSeries(4);
  for (let i = 1; i <= 10; i++) s.push(i);
  assert.equal(s.size, 4);
  assert.deepEqual(s.summary(), {n: 4, p50: 8, p95: 10, max: 10});
});

test('series ignores non-finite values', () => {
  const s = createSeries();
  s.push(NaN);
  s.push(Infinity);
  s.push(5);
  assert.equal(s.size, 1);
});

test('shown latency is received -> first tick after it', () => {
  const d = createLatencyDiag();
  d.frameApplied(1, 1000, 2);
  d.tickDone(3, 1016);
  d.tickDone(3, 1033); // el mismo frame ya se vio: no cuenta de nuevo
  const out = d.drain(2000);
  assert.equal(out.frames_in, 1);
  assert.equal(out.ticks, 2);
  assert.equal(out.shown_ms.n, 1);
  assert.equal(out.shown_ms.max, 16);
  assert.equal(out.apply_ms.max, 2);
  assert.equal(out.superseded, 0);
});

test('a frame replaced before any render counts as superseded', () => {
  const d = createLatencyDiag();
  d.frameApplied(1, 1000, 1);
  d.frameApplied(2, 1010, 1);
  d.tickDone(2, 1020);
  const out = d.drain(2000);
  assert.equal(out.superseded, 1);
  assert.equal(out.shown_ms.max, 10); // mide el frame 2, el que se vio
});

test('drain resets the window and reports its length', () => {
  const d = createLatencyDiag();
  d.frameApplied(1, 1000, 1);
  d.tickDone(1, 1005);
  assert.equal(d.drain(2000).window_ms, 1000);
  d.frameApplied(2, 2500, 1);
  const out = d.drain(3000);
  assert.equal(out.frames_in, 1);
  assert.equal(out.ticks, 0);
  assert.equal(out.window_ms, 1000);
  assert.equal(out.apply_ms.n, 1);
});
