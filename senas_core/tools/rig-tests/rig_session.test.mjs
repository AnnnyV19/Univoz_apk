import test from 'node:test';
import assert from 'node:assert/strict';

import {
  SESSION_SCHEMA,
  createSessionRecorder,
  compactLandmarks,
  newSessionId,
} from '../../assets/avatar_viewer/rig_session.mjs';

test('compactLandmarks rounds and keeps visibility when present', () => {
  assert.deepEqual(compactLandmarks([{x: 0.123456, y: 1, z: -0.000049, visibility: 0.98765}]),
    [[0.1235, 1, -0, 0.9877]]);
  assert.deepEqual(compactLandmarks([[0.11111, 0.2, 0.3]]), [[0.1111, 0.2, 0.3]]);
  assert.equal(compactLandmarks(null), null);
  assert.deepEqual(compactLandmarks([{x: 1, y: 2, z: 3}], {indices: [0]}), [[1, 2, 3]]);
});

test('session id is sortable by time and unique', () => {
  const a = newSessionId(new Date('2026-10-02T21:00:00Z'));
  assert.match(a, /^20261002T210000Z-[a-z0-9]{6}$/);
  assert.notEqual(newSessionId(), newSessionId());
});

test('recorder starts with a header, batches lines and flushes to the sink', async () => {
  const chunks = [];
  const rec = createSessionRecorder({
    sessionId: 's1', meta: {platform: 'web'}, flushEvery: 3,
    sink: async (id, lines) => { chunks.push({id, lines}); return true; },
    now: () => 1000,
  });
  rec.frame({t: 1, pose: [[0, 0, 0, 1]]});
  rec.event('camera_start', {fps: 30});
  assert.equal(chunks.length, 1, 'cabecera + 2 lineas = 3 => flush');
  const header = JSON.parse(chunks[0].lines[0]);
  assert.equal(header.kind, 'session_start');
  assert.deepEqual(chunks[0].lines.map((l) => JSON.parse(l).seq), [0, 1, 2]);
  assert.equal(header.schema, SESSION_SCHEMA);
  assert.equal(header.meta.platform, 'web');
  assert.equal(JSON.parse(chunks[0].lines[1]).kind, 'frame');
  assert.equal(JSON.parse(chunks[0].lines[2]).kind, 'event');
  rec.frame({t: 2});
  await rec.close({reason: 'stop'});
  const last = chunks.at(-1).lines.map((l) => JSON.parse(l));
  assert.equal(last.at(-1).kind, 'session_end');
  assert.equal(last.at(-1).frames, 2);
  assert.equal(rec.stats().lines, 5);
});

test('recorder keeps lines when the sink fails and retries later', async () => {
  let fail = true;
  const got = [];
  const rec = createSessionRecorder({sessionId: 's2', flushEvery: 2,
    sink: async (_, lines) => { if (fail) return false; got.push(...lines); return true; }});
  rec.frame({t: 1});
  await rec.flush();
  assert.equal(got.length, 0);
  assert.ok(rec.stats().pending >= 2);
  fail = false;
  await rec.flush();
  assert.equal(got.length, 2);
  assert.equal(rec.stats().pending, 0);
});

test('recorder never grows without bound when the sink is down', async () => {
  const rec = createSessionRecorder({sessionId: 's3', flushEvery: 1000,
    maxPending: 50, sink: async () => false});
  for (let i = 0; i < 200; i++) rec.frame({t: i});
  await rec.flush();
  assert.ok(rec.stats().pending <= 50);
  assert.ok(rec.stats().dropped > 0);
  // el volcado local conserva cabecera aunque se hayan perdido frames
  assert.equal(JSON.parse(rec.exportLines()[0]).kind, 'session_start');
});

test('closeNow hands every pending line plus the end record to a sync sink', () => {
  const beacons = [];
  const rec = createSessionRecorder({sessionId: 's4', flushEvery: 1000,
    sink: async () => false});
  rec.frame({t: 1});
  rec.frame({t: 2});
  assert.equal(rec.closeNow({reason: 'page_unload'},
    (id, lines) => { beacons.push({id, lines}); return true; }), true);
  const kinds = beacons[0].lines.map((l) => JSON.parse(l).kind);
  assert.deepEqual(kinds, ['session_start', 'frame', 'frame', 'session_end']);
  assert.equal(rec.stats().pending, 0);
  assert.equal(rec.closeNow({}, () => true), false, 'solo una vez');
  rec.frame({t: 3});
  assert.equal(rec.stats().frames, 2, 'cerrada no graba');
});

test('closeNow splits large tails into beacon-sized chunks in order', () => {
  const got = [];
  const rec = createSessionRecorder({sessionId: 's5', flushEvery: 10000,
    sink: async () => false});
  for (let i = 0; i < 40; i++) rec.frame({t: i, pad: 'x'.repeat(3000)});
  rec.closeNow({}, (id, lines) => {
    const bytes = lines.reduce((n, l) => n + l.length + 1, 0);
    assert.ok(bytes <= 60000 || lines.length === 1);
    got.push(...lines);
    return true;
  });
  const kinds = got.map((l) => JSON.parse(l).kind);
  assert.equal(kinds[0], 'session_start');
  assert.equal(kinds.at(-1), 'session_end');
  assert.equal(kinds.filter((k) => k === 'frame').length, 40);
});

test('closeNow still records the end when a chunk is refused', () => {
  const got = [];
  const rec = createSessionRecorder({sessionId: 's6', flushEvery: 10000,
    sink: async () => false});
  for (let i = 0; i < 40; i++) rec.frame({t: i, pad: 'x'.repeat(3000)});
  let calls = 0;
  rec.closeNow({}, (id, lines) => {
    calls++;
    if (calls === 1) return false;
    got.push(...lines);
    return true;
  });
  assert.deepEqual(got.map((l) => JSON.parse(l).kind), ['session_end']);
});
