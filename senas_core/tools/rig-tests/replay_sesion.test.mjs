import test from 'node:test';
import assert from 'node:assert/strict';

import {leerJsonl} from './paridad/sesion_jsonl.mjs';
import {compararSesion} from './paridad/replay_sesion.mjs';
import {crearCaptura} from './paridad/captura_actual.mjs';

// Sesion "de telefono" sintetica: entradas y decisiones del fixture de
// paridad escritas con el esquema que registra sesion_captura.dart.
function sesionDesdeFixture(tramo) {
  const lineas = leerJsonl(new URL('../../test/golden/paridad_manos.jsonl.gz',
    import.meta.url).pathname).filter((l) => l.tramo === tramo);
  const registros = [{seq: 0, kind: 'session_start', meta: {}}];
  for (const l of lineas) {
    const e = l.esp;
    registros.push({
      seq: registros.length, kind: 'frame', t: l.in.t, mode: 'holistic',
      skew_ms: l.in.skew, pose: l.in.pose, world: l.in.world,
      hands: {
        candidates: l.in.cand.map((c) => ({lm: c.lm, label: c.label, conf: c.conf})),
        accepted: e.gate.accepted, unanchored: e.gate.unanchored,
        rejected: e.gate.rejected.map(([index, code]) => ({index, code})),
        passed: e.gate.passed, assignment: e.assign, usable: e.usable,
      },
      tracked: {
        left: e.left.raw != null || e.left.detected != null,
        right: e.right.raw != null || e.right.detected != null,
        left_surface: e.left.surface, right_surface: e.right.surface,
        left_state: e.left.state, right_state: e.right.state,
      },
    });
  }
  return registros;
}

test('a phone session that matches the web replays without mismatches', () => {
  const r = compararSesion(sesionDesdeFixture('sint-cruce'), crearCaptura);
  assert.ok(r.frames > 20);
  assert.equal(r.desajustes.length, 0, JSON.stringify(r.desajustes.slice(0, 3)));
  assert.equal(r.porCampo['tracked.left_state'].iguales, r.frames);
});

test('a phone session that diverges from the web is reported by field', () => {
  const registros = sesionDesdeFixture('sint-cruce');
  registros[5].tracked.left_state = 'LOST';
  registros[7].hands.assignment = {mode: 'ambiguous', sides: [null, null]};
  const r = compararSesion(registros, crearCaptura);
  const campos = new Set(r.desajustes.map((d) => d.campo));
  assert.ok(campos.has('tracked.left_state'));
  assert.ok(campos.has('assignment.mode'));
  assert.equal(r.desajustes[0].seq, 5);
});
