// Volteos de palma de un cuadro y anticipacion de manos (rig_replay.mjs),
// integracion-final 2026-10-27. La referencia en Python es
// univoz/herramientas/auditoria_manos (volteos.py).
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {gunzipSync} from 'node:zlib';

import {anticiparManos, kAnticipaMs, repararVolteosPalma}
  from '../../assets/avatar_viewer/rig_replay.mjs';

const kShapeL = 32, kPresL = 30, kPresR = 31;

// Mano izquierda abierta; [flip] la gira 180 grados sobre el eje de los dedos.
function frameMano(flip = false) {
  const f = new Array(152).fill(0);
  f[0] = -0.5; f[3] = 0.5; f[6] = -0.6; f[7] = -0.5; f[30] = 1;
  const pts = [];
  for (let d = 0; d < 5; d++) {
    for (let j = 0; j < 4; j++) {
      pts.push([(d - 2) * 0.2, 0.4 + j * 0.25, 0.05 * j]);
    }
  }
  pts.forEach(([x, y, z], i) => {
    f[kShapeL + i * 3] = flip ? -x : x;
    f[kShapeL + i * 3 + 1] = y;
    f[kShapeL + i * 3 + 2] = flip ? -z : z;
  });
  return f;
}

test('un volteo de un cuadro se repara y solo cambia la forma', () => {
  const F = Array.from({length: 12}, (_, k) => frameMano(k === 6));
  const antes = F.map((f) => f.slice());
  const n = repararVolteosPalma(F);
  assert.equal(n, 1);
  assert.deepEqual(F[6].slice(kShapeL, kShapeL + 60),
    antes[5].slice(kShapeL, kShapeL + 60));
  for (let k = 0; k < F.length; k++) {
    assert.deepEqual(F[k].slice(0, 32), antes[k].slice(0, 32));
  }
});

test('sin volteos no cambia nada', () => {
  const F = Array.from({length: 10}, () => frameMano());
  const antes = JSON.stringify(F);
  assert.equal(repararVolteosPalma(F), 0);
  assert.equal(JSON.stringify(F), antes);
});

test('paridad con la referencia en Python', () => {
  const casos = JSON.parse(gunzipSync(readFileSync(
    new URL('./paridad_volteos.json.gz', import.meta.url))).toString('utf8'));
  let max = 0;
  for (const c of casos) {
    const F = c.ent.map((f) => f.slice());
    assert.equal(repararVolteosPalma(F), c.n, c.g);
    for (let k = 0; k < F.length; k++) {
      for (let d = 0; d < 152; d++) {
        max = Math.max(max, Math.abs(F[k][d] - c.sal[k][d]));
      }
    }
  }
  assert.ok(max < 1e-5, `diferencia ${max}`);
});

test('anticipacion: la mano que aparece viaja antes y no pisa datos reales', () => {
  const F = Array.from({length: 32}, (_, k) => {
    const f = new Array(152).fill(0);
    f[0] = -0.5; f[3] = 0.5; f[6] = -0.6; f[7] = -0.5; f[kPresL] = 1;
    f[25] = 0.2 + k * 0.001;
    if (k >= 20) {
      f[kPresR] = 1; f[9] = 0.6; f[10] = -0.4; f[27] = 0.3 + k * 0.01;
      f[28] = 0.15; f[92] = 0.1 * k;
    }
    return f;
  });
  const orig = JSON.stringify(F);
  const A = anticiparManos(F, 30);
  const n = Math.round(kAnticipaMs / 1000 * 30);
  assert.equal(JSON.stringify(F), orig, 'no toca la entrada');
  for (let k = 0; k < 32; k++) {
    if (k >= 20 || k < 20 - n) {
      assert.deepEqual(A[k], F[k], `cuadro ${k}`);
    } else {
      assert.equal(A[k][kPresR], 1);
      assert.equal(A[k][27], F[20][27]);
      assert.equal(A[k][28], F[20][28]);
      assert.equal(A[k][25], F[k][25], 'la otra mano no cambia');
    }
  }
});
