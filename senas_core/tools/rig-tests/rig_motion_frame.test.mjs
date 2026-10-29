import test from 'node:test';
import assert from 'node:assert/strict';

import {
  frameQuality,
  handUsable,
  normalizeMotionFrame,
  poseGeometry,
} from '../../assets/avatar_viewer/rig_motion_frame.mjs';

const coord = (x, y, z = 0, visibility = 1) => ({x, y, z, visibility});

function validHand() {
  const p = Array.from({length: 21}, () => coord(.5, .6));
  p[0] = coord(.50, .70);
  p[1] = coord(.44, .65); p[2] = coord(.39, .60);
  p[3] = coord(.36, .54); p[4] = coord(.34, .48);
  p[5] = coord(.46, .62); p[6] = coord(.45, .54);
  p[7] = coord(.44, .46); p[8] = coord(.44, .38);
  p[9] = coord(.50, .60); p[10] = coord(.50, .50);
  p[11] = coord(.50, .40); p[12] = coord(.50, .30);
  p[13] = coord(.54, .61); p[14] = coord(.56, .52);
  p[15] = coord(.57, .44); p[16] = coord(.58, .36);
  p[17] = coord(.58, .64); p[18] = coord(.61, .57);
  p[19] = coord(.63, .51); p[20] = coord(.64, .46);
  return p;
}

function validPoseWorld() {
  const p = Array.from({length: 33}, () => coord(0, 0, 0));
  p[11] = coord(-.2, 1, 0); p[12] = coord(.2, 1, 0);
  p[13] = coord(-.42, .7, 0); p[14] = coord(.42, .7, 0);
  p[15] = coord(-.55, .4, 0); p[16] = coord(.55, .4, 0);
  p[23] = coord(-.15, 0, 0); p[24] = coord(.15, 0, 0);
  return p;
}

function validPoseImage() {
  const p = Array.from({length: 33}, () => coord(.5, .5, 0));
  p[11] = coord(.4, .35); p[12] = coord(.6, .35);
  p[13] = coord(.3, .5); p[14] = coord(.7, .5);
  p[15] = coord(.25, .65); p[16] = coord(.75, .65);
  p[23] = coord(.43, 1.20); p[24] = coord(.57, 1.20);
  return p;
}

test('hand usability accepts a plausible hand and names each rejection', () => {
  assert.deepEqual(handUsable(validHand()), {ok: true, code: null, landmark: null});
  assert.equal(handUsable(validHand().slice(0, 20)).code, 'hand_landmarks_incomplete');
  const nan = validHand(); nan[7] = coord(NaN, .5);
  assert.deepEqual(handUsable(nan), {ok: false, code: 'point_non_finite', landmark: 7});
  const wrist = validHand(); wrist[0] = coord(1.02, .7);
  assert.equal(handUsable(wrist).code, 'wrist_out_of_frame');
  const fuera = validHand().map((p, i) => i > 4 ? coord(p.x + .9, p.y) : p);
  assert.equal(handUsable(fuera).code, 'hand_out_of_frame');
  const tiny = validHand().map((p) => coord(.5 + (p.x - .5) * .05, .7 + (p.y - .7) * .05));
  assert.deepEqual(handUsable(tiny), {ok: false, code: 'hand_scale_invalid', landmark: 9});
  const outside = validHand(); outside[12] = coord(1.4, .3);
  assert.equal(handUsable(outside).ok, false);
  const jump = validHand(); jump[12] = coord(.5, .02);
  assert.deepEqual(handUsable(jump), {ok: false, code: 'hand_segment_invalid', landmark: 12});
});

test('pose geometry rejects disconnected or unsafe bodies with a reason', () => {
  const image = validPoseImage();
  assert.equal(poseGeometry(image, validPoseWorld()).ok, true);
  const broken = validPoseWorld(); broken[15] = coord(8, 8, 8);
  assert.deepEqual(poseGeometry(image, broken),
    {ok: false, code: 'pose_segment_invalid', landmark: 15});
  const hombro = validPoseImage(); hombro[11] = coord(-.3, .35);
  assert.equal(poseGeometry(hombro, validPoseWorld()).code, 'shoulder_out_of_frame');
  const tenue = validPoseImage(); tenue[12] = coord(.6, .35, 0, .1);
  assert.equal(poseGeometry(tenue, validPoseWorld()).code, 'pose_anchor_unsafe');
  const juntos = validPoseWorld(); juntos[12] = coord(-.2, 1, 0);
  assert.equal(poseGeometry(image, juntos).code, 'hombros-degenerados');
  const tronco = validPoseWorld(); tronco[23] = coord(-.15, .98, 0); tronco[24] = coord(.15, .98, 0);
  assert.equal(poseGeometry(image, tronco).code, 'tronco-invalido');
  assert.equal(poseGeometry(null, validPoseWorld()).code, 'pose-formato');
});

test('motion frame drops unusable hands with their side and keeps the body', () => {
  const image = validPoseImage();
  const world = validPoseWorld();
  const ok = normalizeMotionFrame(image, world, validHand(), null);
  assert.equal(ok.vector.length, 152);
  assert.equal(ok.vector[30], 1); // presencia izquierda
  assert.deepEqual(ok.errors, []);
  const rota = validHand(); rota[12] = coord(.5, .02);
  const r = normalizeMotionFrame(image, world, rota, validHand());
  assert.equal(r.vector[30], 0);
  assert.equal(r.vector[31], 1);
  assert.deepEqual(r.errors, [{stage: 'capture', code: 'hand_segment_invalid',
    side: 'left', landmark: 12}]);
  assert.equal(r.validation, 'mano-geometria');
});

test('motion frame without a usable body returns null with the cause', () => {
  const tenue = validPoseImage();
  tenue[11] = coord(.4, .35, 0, .3);
  const r = normalizeMotionFrame(tenue, validPoseWorld(), validHand(), null);
  assert.equal(r.vector, null);
  assert.deepEqual(r.errors.map((e) => e.code), ['shoulder_confidence_low']);
  assert.equal(normalizeMotionFrame(null, null, null, null).errors[0].code, 'pose_format');
});

test('render wrists shift only the render hand location, bounded to 0.75', () => {
  const image = validPoseImage();
  const world = validPoseWorld();
  const base = normalizeMotionFrame(image, world, validHand(), null).vector;
  const cerca = normalizeMotionFrame(image, world, validHand(), null,
    {renderWrists: {left: coord(.27, .65)}}).vector;
  assert.notEqual(cerca[24], base[24]);
  assert.ok(Math.abs(cerca[24] - base[24]) < .75);
  const lejos = normalizeMotionFrame(image, world, validHand(), null,
    {renderWrists: {left: coord(5, .65)}}).vector;
  assert.ok(Math.abs(Math.abs(lejos[24] - base[24]) - .75) < 1e-12);
  assert.deepEqual(cerca.slice(32), base.slice(32)); // forma igual
});

test('frame quality mixes body visibility and hand presence like the web lab', () => {
  const image = validPoseImage();
  const world = validPoseWorld();
  assert.equal(frameQuality(image, world, validHand(), validHand()), 1);
  assert.ok(Math.abs(frameQuality(image, world, validHand(), null) -
    (.75 + .82 * .25)) < 1e-12);
  assert.ok(Math.abs(frameQuality(image, world, null, null) - (.75 + .65 * .25)) < 1e-12);
  assert.equal(frameQuality(null, world, null, null), 0);
});

test('golden of Python and Dart: same vectors and rejection reasons', async () => {
  // test/golden/golden_cases.json lo genera tools/gen_golden.py (sign_norm.py)
  // y lo verifica tambien sign_norm_test.dart: web, Python y Dart iguales.
  const {readFileSync} = await import('node:fs');
  const golden = JSON.parse(readFileSync(new URL('../../test/golden/golden_cases.json',
    import.meta.url), 'utf8'));
  const cerca = (a, b) => a.length === b.length &&
    a.every((v, k) => Math.abs(v - b[k]) < golden.tolerance);
  for (const c of golden.cases) {
    c.frames.forEach((f, i) => {
      const r = normalizeMotionFrame(f.pose, f.pose_mundo, f.left, f.right);
      assert.ok(r.vector && cerca(r.vector, c.expected_frames[i]), `${c.name} frame ${i}`);
    });
  }
  assert.ok(golden.validaciones.length >= 8);
  for (const c of golden.validaciones) {
    const f = c.frame;
    const r = normalizeMotionFrame(f.pose, f.pose_mundo, f.left, f.right,
      {renderWrists: f.render_wrists ?? null});
    assert.deepEqual(r.errors.map((e) => [e.stage, e.code, e.side, e.landmark]),
      c.motivos, c.name);
    if (c.expected == null) assert.equal(r.vector, null, c.name);
    else assert.ok(r.vector && cerca(r.vector, c.expected), c.name);
  }
});

test('no usable pose: the held body plus live hands keeps moving wrist and fingers', () => {
  // Mismo contrato que AlimentadorAvatar (avatar_vivo.dart): la pose nueva no
  // sirve (hombros fuera de cuadro), se reusa la del ultimo frame valido y se
  // le ponen las manos de ahora.
  const image = validPoseImage();
  const world = validPoseWorld();
  const nueva = validPoseImage(); nueva[11] = coord(.4, .35, 0, .1);
  assert.equal(normalizeMotionFrame(nueva, world, validHand(), null).vector, null);

  const antes = normalizeMotionFrame(image, world, validHand(), null).vector;
  // Mano que se mueve: muñeca 0.1 a la derecha en imagen y el indice doblado.
  const mano = validHand().map((p, i) => i === 8 ? coord(p.x + .1, p.y + .12) : p);
  const muneca = coord(.60, .70);
  const ahora = normalizeMotionFrame(image, world, mano, null,
    {renderWrists: {left: muneca, right: null}}).vector;
  assert.deepEqual(ahora.slice(0, 24), antes.slice(0, 24)); // cuerpo sostenido
  assert.equal(ahora[30], 1);
  assert.notDeepEqual(ahora.slice(24, 27), antes.slice(24, 27)); // la muñeca sigue
  assert.notDeepEqual(ahora.slice(32, 92), antes.slice(32, 92)); // y los dedos
});
