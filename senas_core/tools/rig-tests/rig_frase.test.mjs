// Frases (varias señas seguidas) y reproduccion estable: rig_frase.mjs y
// rig_replay.mjs, aportados por la rama app-limpia.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

import {
  armarFrase, esFrameValido, fraseValida, kFraseMaxSegmentos,
  kFraseTransicionMs,
} from '../../assets/avatar_viewer/rig_frase.mjs';
import {
  extraEncuadreAbajo, interpolarFrame, prepararSecuencia,
} from '../../assets/avatar_viewer/rig_replay.mjs';

const segs = JSON.parse(readFileSync(
  new URL('./paridad_cuerpo/frase_prueba.json', import.meta.url), 'utf8'));

const saltoMuneca = (frames, desde, hasta) => {
  let salto = 0;
  for (let i = Math.max(1, desde); i < Math.min(frames.length, hasta); i++) {
    for (const [p, l] of [[30, 24], [31, 27]]) {
      if (frames[i][p] >= .5 && frames[i - 1][p] >= .5) {
        salto = Math.max(salto, Math.hypot(...[0, 1, 2].map(
          (k) => frames[i][l + k] - frames[i - 1][l + k])));
      }
    }
  }
  return salto;
};

for (const [nombre, preparar] of [['copia', undefined],
  ['estable', prepararSecuencia]]) {
  test(`armarFrase (${nombre}): cuadros validos y transiciones sin saltos`, () => {
    const f = armarFrase(segs, preparar);
    assert.ok(f.frames.every((x) => x.length === 152 && x.every(Number.isFinite)));
    const base = f.fps;
    const nT = Math.max(2, Math.round(kFraseTransicionMs / 1000 * base));
    // Largo esperado: por seña, n cuadros (a la tasa comun) + transiciones.
    let esperado = 0;
    const trans = [];
    segs.forEach((sg, i) => {
      if (i > 0) {
        for (let j = 0; j <= nT; j++) trans.push(esperado + j);
        esperado += nT;
      }
      esperado += Math.max(2, Math.round(32 * base / (sg.fps || 30)));
    });
    assert.equal(f.frames.length, esperado);
    let saltoT = 0;
    for (const i of trans) saltoT = Math.max(saltoT, saltoMuneca(f.frames, i, i + 1));
    assert.ok(saltoT <= 0.2, `transicion brusca: ${saltoT}`);
  });
}

test('fraseValida rechaza frases mal formadas', () => {
  assert.equal(fraseValida(segs), true);
  assert.equal(fraseValida([]), false);
  assert.equal(fraseValida(null), false);
  assert.equal(fraseValida([{frames: segs[0].frames.slice(1), fps: 30}]), false);
  const mala = segs[0].frames.map((f) => f.slice());
  mala[3][5] = NaN;
  assert.equal(fraseValida([{frames: mala, fps: 30}]), false);
  assert.equal(fraseValida(Array(kFraseMaxSegmentos + 1).fill(segs[0])), false);
  assert.equal(esFrameValido(new Array(152).fill(0)), true);
  assert.equal(esFrameValido(new Array(151).fill(0)), false);
});

test('interpolarFrame no inventa una mano que solo esta en un cuadro', () => {
  const a = new Array(152).fill(0);
  const b = new Array(152).fill(0);
  a[30] = 1; a[24] = 1;            // mano izquierda solo en A
  const m = interpolarFrame([a, b], 0.25, new Array(152).fill(0));
  assert.equal(m[30], 1);          // mas cerca de A: se queda con A
  assert.equal(m[24], 1);
  const n = interpolarFrame([a, b], 0.75, new Array(152).fill(0));
  assert.equal(n[30], 0);
  b[30] = 1; b[24] = 3;            // ahora en las dos: se mezcla
  const k = interpolarFrame([a, b], 0.5, new Array(152).fill(0));
  assert.ok(Math.abs(k[24] - 2) < 1e-9);
});

test('prepararSecuencia rellena huecos de mano y no toca el original', () => {
  const f = Array.from({length: 8}, () => new Array(152).fill(0));
  for (const t of [0, 1, 2, 5, 6, 7]) {
    f[t][30] = 1;
    f[t][24] = t;
  }
  const copia = f.map((x) => x.slice());
  const out = prepararSecuencia(f);
  assert.deepEqual(f, copia);
  assert.equal(out.length, 8);
  assert.ok(out.every((x) => x[30] === 1), 'los cuadros 3 y 4 se rellenan');
  assert.ok(out.every((x) => x.every(Number.isFinite)));
});

test('extraEncuadreAbajo: 0 sin manos bajas, positivo con la mano muy abajo', () => {
  const m = {hombroY: 1.25, brazo: 0.25};
  const arriba = [new Array(152).fill(0)];
  arriba[0][30] = 1; arriba[0][25] = 0;
  assert.equal(extraEncuadreAbajo(arriba, m, 1, 1.4, 0.34), 0);
  const abajo = [new Array(152).fill(0)];
  abajo[0][30] = 1; abajo[0][25] = -2.5;
  const extra = extraEncuadreAbajo(abajo, m, 1, 1.4, 0.34);
  assert.ok(extra > 0 && extra <= m.brazo);
  assert.equal(extraEncuadreAbajo([], m, 1, 1.4, 0.34), 0);
});
