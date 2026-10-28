// Separador de manos (aportado por la rama app-limpia) contra la referencia en
// Python (paridad_cuerpo/casos_par.json, 150 pares). Regenerar con
// univoz/herramientas/cuerpo/simulacion/gen_casos_par.py.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

import {SeparadorManos} from '../../assets/avatar_viewer/rig_manos.mjs';

const casos = JSON.parse(readFileSync(
  new URL('./paridad_cuerpo/casos_par.json', import.meta.url), 'utf8'));

test('SeparadorManos coincide con la referencia Python en los 150 pares', () => {
  assert.ok(casos.length >= 150);
  let fallas = 0;
  let conPases = 0;
  for (const [i, c] of casos.entries()) {
    const r = SeparadorManos.resolverPar(c.es, c.previos, c.prevPar);
    const m = {delta: 0, giro: 0, sh: 0, psi: 0};
    for (let l = 0; l < 2; l++) {
      m.delta = Math.max(m.delta,
        ...r.res[l].delta.map((v, j) => Math.abs(v - c.out.delta[l][j])));
      m.giro = Math.max(m.giro, Math.abs(r.res[l].giro - c.out.giro[l]));
      m.sh = Math.max(m.sh,
        ...r.sh[l].map((v, j) => Math.abs(v - c.out.sh[l][j])));
    }
    if (c.out.psi !== null && r.psi !== null) {
      const d = Math.abs(r.psi - c.out.psi);
      m.psi = Math.min(d, Math.abs(2 * Math.PI - d));
    } else if ((c.out.psi === null) !== (r.psi === null)) {
      m.psi = 99;
    }
    if (r.pases > 0) conPases++;
    if (m.delta > 1e-6 || m.giro > 1e-6 || m.sh > 1e-6 || m.psi > 1e-9 ||
        r.pases !== c.out.pases || r.limitado !== c.out.limitado) {
      fallas++;
      if (fallas <= 3) console.log('caso', i, m, r.pases, c.out.pases);
    }
  }
  assert.equal(fallas, 0);
  assert.ok(conPases > 0, 'el conjunto debe incluir pares que se separan');
});
