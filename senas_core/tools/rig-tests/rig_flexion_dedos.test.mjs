// Flexion de dedos con signo (rig_manos.mjs, flexionesConSigno).
import test from 'node:test';
import assert from 'node:assert/strict';

import {flexionesConSigno} from '../../assets/avatar_viewer/rig_manos.mjs';

// Mano derecha con la palma hacia la camara y los dedos hacia arriba, en
// coordenadas de sign_norm (x,y de imagen, y hacia abajo; z de MediaPipe,
// negativa = hacia la camara = hacia el lado de la palma). Cada dedo: nudillo
// en la palma y tres falanges que giran `flex` (rad) hacia la palma y se abren
// `abre` (rad) de lado.
const xs = [0.35, 0.12, -0.1, -0.3];   // indice ... meñique
function mano({flex = [[0, 0, 0], [0, 0, 0], [0, 0, 0], [0, 0, 0]], abre = [0.35, 0.05, -0.1, -0.3],
  pulgar = true} = {}) {
  const P = [];
  // pulgar (cualquier cosa razonable)
  if (pulgar) P.push([0.3, -0.2, 0], [0.5, -0.35, 0], [0.62, -0.5, 0], [0.7, -0.62, 0]);
  for (let d = 0; d < 4; d++) {
    const nud = [xs[d], -1, 0];
    P.push(nud);
    let dir = [Math.sin(abre[d]), -Math.cos(abre[d]), 0];
    let p = nud;
    let total = 0;
    for (let k = 0; k < 3; k++) {
      total += flex[d][k];
      // girar hacia -z (palma) desde la direccion del dedo
      const v = [dir[0] * Math.cos(total), dir[1] * Math.cos(total), -Math.sin(total)];
      p = [p[0] + 0.35 * v[0], p[1] + 0.35 * v[1], p[2] + 0.35 * v[2]];
      P.push(p);
    }
  }
  return P;
}
const espejo = (P) => P.map(([x, y, z]) => [-x, y, z]);
const cerca = (a, b, tol = 0.03) => assert.ok(Math.abs(a - b) < tol, `${a} vs ${b}`);

test('dedos derechos aunque se abran de lado: flexion 0', () => {
  const f = flexionesConSigno(mano(), 'right');
  // el nudillo del indice sale abierto ~20°: antes eso se doblaba hacia la palma
  for (const d of f) for (const x of d) cerca(x, 0, 0.02);
});

test('flexion real hacia la palma se conserva', () => {
  const flex = [[0.4, 0.9, 0.5], [0, 0, 0], [1.2, 1.4, 0.6], [0.2, 0.1, 0]];
  const f = flexionesConSigno(mano({flex}), 'right');
  cerca(f[0][1], 0.9, 0.05);
  cerca(f[2][0], 1.2, 0.08);
  cerca(f[1][2], 0, 0.02);
});

test('punta hacia atras (hiperextension) queda recta, no doblada', () => {
  const flex = [[0, 0, -0.35], [0, 0, -0.3], [0, 0, -0.25], [0, 0, -0.3]];
  const f = flexionesConSigno(mano({flex}), 'right');
  for (const d of f) assert.equal(d[2], 0);
});

test('mano izquierda (espejo anatomico) da lo mismo', () => {
  const flex = [[0.3, 0.8, 0.4], [0, 0.2, 0], [0.5, 0, 0], [0, 0, 0]];
  const der = flexionesConSigno(mano({flex}), 'right');
  const izq = flexionesConSigno(espejo(mano({flex})), 'left');
  for (let d = 0; d < 4; d++) for (let k = 0; k < 3; k++) cerca(izq[d][k], der[d][k], 1e-9);
});

test('toma espejada (quiralidad al reves): se detecta y la flexion sigue bien', () => {
  const flex = [[0.6, 1.0, 0.5], [0.7, 1.1, 0.5], [0.7, 1.0, 0.4], [0.6, 0.9, 0.4]];
  const f = flexionesConSigno(espejo(mano({flex})), 'right');
  cerca(f[1][1], 1.1, 0.05);
  cerca(f[3][0], 0.6, 0.08);
});

test('mano degenerada o incompleta: null', () => {
  assert.equal(flexionesConSigno(null, 'right'), null);
  assert.equal(flexionesConSigno(mano().slice(0, 10), 'right'), null);
  const P = mano(); P[5] = [NaN, 0, 0];
  assert.equal(flexionesConSigno(P, 'right'), null);
});
