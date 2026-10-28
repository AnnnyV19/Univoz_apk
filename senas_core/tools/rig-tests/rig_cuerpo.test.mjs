// Separador de cuerpo (aportado por la rama app-limpia) contra la referencia
// en Python (paridad_cuerpo/casos_cuerpo.json, 200 casos; coincide a 1e-6).
// Regenerar con univoz/herramientas/cuerpo/simulacion/gen_casos.py.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

import {SeparadorCuerpo} from '../../assets/avatar_viewer/rig_cuerpo.mjs';

const casos = JSON.parse(readFileSync(
  new URL('./paridad_cuerpo/casos_cuerpo.json', import.meta.url), 'utf8'));

test('SeparadorCuerpo coincide con la referencia Python en los 200 casos', () => {
  assert.ok(casos.length >= 200);
  let fallas = 0;
  for (const [i, c] of casos.entries()) {
    const r = SeparadorCuerpo.resolver(c.e, c.previo);
    const dd = Math.max(...r.delta.map((v, j) => Math.abs(v - c.out.delta[j])));
    const ok = Math.abs(r.empuje - c.out.empuje) <= 1e-6 && dd <= 1e-6 &&
      Math.abs(r.giro - c.out.giro) <= 1e-6 && r.iter === c.out.iter;
    if (!ok) {
      fallas++;
      if (fallas <= 3) console.log('caso', i, r.empuje, c.out.empuje, dd);
    }
  }
  assert.equal(fallas, 0);
});

test('SeparadorCuerpo nunca cambia la altura de la muneca pedida', () => {
  let probados = 0;
  for (const c of casos) {
    const r = SeparadorCuerpo.resolver(c.e, c.previo);
    if (!(r.empuje > 0)) continue;
    // El empuje es horizontal: la componente sobre "arriba" no cambia.
    const arr = c.e.arriba;
    const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
    const r0 = Math.hypot(...c.e.delta);
    const rr0 = Math.min(c.e.radioMax, Math.max(c.e.radioMin, r0));
    const base = c.e.delta.map((v) => v * rr0 / Math.max(r0, 1e-9));
    assert.ok(Math.abs(dot(r.delta, arr) - dot(base, arr)) < 1e-6);
    probados++;
  }
  assert.ok(probados > 0);
});
