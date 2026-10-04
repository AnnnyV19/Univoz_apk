import test from 'node:test';
import assert from 'node:assert/strict';

import {
  createHolisticWorkerClient,
  holisticWorkerMain,
  holisticWorkerSource,
  holisticWorkerSupported,
} from '../../assets/avatar_viewer/rig_holistic_worker.mjs';

const pts = (n) => Array.from({length: n}, (_, i) => ({x: i, y: 0, z: 0}));

// Worker simulado: corre holisticWorkerMain en el mismo hilo con un
// MediaPipe falso, conectando los dos extremos de postMessage.
function fakeWorker({failModels = [], failImport = false, detectThrows = false} = {}) {
  const creados = [];
  const scope = {postMessage: null, onmessage: null};
  const vision = {
    FilesetResolver: {forVisionTasks: async (wasm) => ({wasm})},
    HolisticLandmarker: {
      createFromOptions: async (fileset, opts) => {
        creados.push(opts);
        if (failModels.includes(opts.baseOptions.modelAssetPath)) {
          throw new Error('no gpu for ' + opts.baseOptions.modelAssetPath);
        }
        return {
          detectForVideo: (frame, t) => {
            if (detectThrows) throw new Error('webgl lost');
            return {poseLandmarks: [pts(33)], leftHandLandmarks: [pts(21)],
              faceBlendshapes: [{categories: [{categoryName: 'jawOpen',
                score: 0.5, index: 3, displayName: ''}]}],
              t, frameId: frame.id, extra: () => {}};
          },
          close: () => { scope.closed = true; },
        };
      },
    },
  };
  holisticWorkerMain(scope, async (url) => {
    if (failImport) throw new Error('offline ' + url);
    return vision;
  });
  const worker = {
    onmessage: null, onerror: null, terminated: false, transfers: [],
    postMessage(data, transfer) {
      this.transfers.push(transfer ?? null);
      queueMicrotask(() => scope.onmessage({data}));
    },
    terminate() { this.terminated = true; },
  };
  scope.postMessage = (data) => queueMicrotask(() => worker.onmessage?.({data}));
  return {worker, scope, creados};
}

const opciones = (fake, extra = {}) => ({
  bundleUrl: 'https://cdn/vision_bundle.mjs', wasmUrl: 'https://cdn/wasm',
  models: ['http://local/holistic.task', 'https://remote/holistic.task'],
  options: {minPoseDetectionConfidence: 0.4},
  createWorker: () => fake.worker, ...extra,
});

test('init uses GPU and the first model that loads', async () => {
  const fake = fakeWorker({failModels: ['http://local/holistic.task']});
  const client = createHolisticWorkerClient(opciones(fake));
  const ready = await client.init();
  assert.equal(ready.model, 'https://remote/holistic.task');
  assert.equal(ready.failures.length, 1);
  assert.ok(fake.creados.every((o) => o.baseOptions.delegate === 'GPU'));
  assert.equal(fake.creados[0].runningMode, 'VIDEO');
  assert.equal(fake.creados[0].minPoseDetectionConfidence, 0.4);
});

test('init rejects when no model loads on GPU or bundle import fails', async () => {
  const sinGpu = fakeWorker({failModels: ['http://local/holistic.task',
    'https://remote/holistic.task']});
  await assert.rejects(createHolisticWorkerClient(opciones(sinGpu)).init(),
    (e) => e.failures.length === 2);
  const offline = fakeWorker({failImport: true});
  await assert.rejects(createHolisticWorkerClient(opciones(offline)).init(),
    /offline/);
});

test('detect returns a plain, cloneable result and closes the frame', async () => {
  const fake = fakeWorker();
  const client = createHolisticWorkerClient(opciones(fake));
  await client.init();
  let cerrado = false;
  const frame = {id: 7, close: () => { cerrado = true; }};
  const {result, ms} = await client.detect(frame, 1234);
  assert.equal(result.poseLandmarks[0].length, 33);
  assert.equal(result.leftHandLandmarks[0].length, 21);
  assert.deepEqual(result.rightHandLandmarks, []);
  assert.deepEqual(result.faceBlendshapes,
    [{categories: [{categoryName: 'jawOpen', score: 0.5}]}]);
  assert.equal(result.extra, undefined);
  assert.doesNotThrow(() => structuredClone(result));
  assert.ok(Number.isFinite(ms) && ms >= 0);
  assert.ok(cerrado, 'el ImageBitmap se libera en el worker');
  assert.deepEqual(fake.worker.transfers.at(-1), [frame]);
});

test('detect errors reject only that frame', async () => {
  const fake = fakeWorker({detectThrows: true});
  const client = createHolisticWorkerClient(opciones(fake));
  await client.init();
  await assert.rejects(client.detect({id: 1}, 1), /webgl lost/);
  assert.equal(client.pending, 0);
});

test('worker crash and close reject pending detects', async () => {
  const fake = fakeWorker();
  const client = createHolisticWorkerClient(opciones(fake));
  await client.init();
  fake.scope.onmessage = () => {};  // el worker deja de responder
  const p = client.detect({id: 1}, 1);
  fake.worker.onerror({message: 'boom', preventDefault() {}});
  await assert.rejects(p, /boom/);

  const p2 = client.detect({id: 2}, 2);
  client.close();
  await assert.rejects(p2, /cerrado/);
  assert.ok(fake.worker.terminated);
  let cerrado = false;
  await assert.rejects(client.detect({close: () => { cerrado = true; }}, 3),
    /cerrado/);
  assert.ok(cerrado, 'un frame enviado tras close se libera');
});

test('init times out if the worker never answers', async () => {
  const fake = fakeWorker();
  fake.scope.onmessage = () => {};
  const client = createHolisticWorkerClient(opciones(fake, {initTimeoutMs: 10}));
  await assert.rejects(client.init(), /timeout/);
});

test('worker source is self-contained and parses as a module', async () => {
  const src = holisticWorkerSource();
  assert.match(src, /^\(function holisticWorkerMain\(scope, importar\)/);
  assert.match(src, /\)\(self, \(url\) => import\(url\)\);\n$/);
  // Se evalua aislado: cualquier referencia externa fallaria al llamarlo.
  const aislado = new Function('self', 'return ' +
    src.replace(/\(self, \(url\) => import\(url\)\);\n$/, ''))();
  const scope = {postMessage() {}};
  aislado(scope, async () => ({}));
  assert.equal(typeof scope.onmessage, 'function');
});

test('support check needs module workers, OffscreenCanvas and ImageBitmap', () => {
  const base = {Worker: function () {}, OffscreenCanvas: function () {},
    createImageBitmap: () => {}, Blob: function () {},
    URL: {createObjectURL: () => ''}};
  assert.equal(holisticWorkerSupported(base), true);
  assert.equal(holisticWorkerSupported({...base, OffscreenCanvas: undefined}), false);
  assert.equal(holisticWorkerSupported({}), false);
});
