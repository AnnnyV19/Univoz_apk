import test from 'node:test';
import assert from 'node:assert/strict';

import {
  HOLISTIC_MODEL_URL,
  holisticToTaskResults,
} from '../../assets/avatar_viewer/rig_holistic.mjs';

const pts = (n, x) => Array.from({length: n}, (_, i) => ({x, y: i / n, z: 0,
  visibility: 0.9}));

test('holistic result maps to the separate pose/hand task shapes', () => {
  const result = {
    poseLandmarks: [pts(33, 0.5)],
    poseWorldLandmarks: [pts(33, 0.1)],
    leftHandLandmarks: [pts(21, 0.7)],
    leftHandWorldLandmarks: [pts(21, 0.01)],
    rightHandLandmarks: [pts(21, 0.3)],
    rightHandWorldLandmarks: [pts(21, 0.02)],
    faceLandmarks: [pts(478, 0.5)],
    faceBlendshapes: [{categories: [{categoryName: 'jawOpen', score: 0.6}]}],
  };
  const r = holisticToTaskResults(result);
  assert.equal(r.poseResult.landmarks[0].length, 33);
  assert.equal(r.poseResult.worldLandmarks[0].length, 33);
  assert.equal(r.handResult.landmarks.length, 2);
  // Etiquetas solo informativas: el lado lo decide la cadena del brazo.
  assert.deepEqual(r.handResult.handednesses.map((h) => h[0].categoryName),
    ['Left', 'Right']);
  assert.equal(r.handResult.worldLandmarks[0][0].x, 0.01);
  assert.equal(r.face.landmarks.length, 478);
  assert.deepEqual(r.face.blendshapes, {jawOpen: 0.6});
});

test('holistic result with missing parts yields empty, not broken, shapes', () => {
  const r = holisticToTaskResults({poseLandmarks: [], rightHandLandmarks: [pts(21, .3)]});
  assert.equal(r.poseResult, null);
  assert.equal(r.handResult.landmarks.length, 1);
  assert.equal(r.handResult.handednesses[0][0].categoryName, 'Right');
  assert.equal(r.face, null);
  const empty = holisticToTaskResults(null);
  assert.equal(empty.poseResult, null);
  assert.deepEqual(empty.handResult.landmarks, []);
});

test('holistic model points to the official float16 bundle', () => {
  assert.match(HOLISTIC_MODEL_URL, /holistic_landmarker\.task$/);
});
