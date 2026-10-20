// Candado del banco de paridad de manos: reproducir el fixture con la
// captura web actual debe dar exactamente la salida guardada. Si falla, la
// captura web cambio: regenerar con gen_paridad_manos.mjs (y revisar el
// resumen) o corregir el cambio. Kotlin (ParidadManosTest) sigue al fixture.
import test from 'node:test';
import assert from 'node:assert/strict';

import {crearCaptura} from './paridad/captura_actual.mjs';
import {esperadoDe, frameDeEntrada} from './paridad/replay.mjs';
import {leerJsonl} from './paridad/sesion_jsonl.mjs';

const ruta = process.env.PARIDAD_FIXTURE ??
  new URL('../../test/golden/paridad_manos.jsonl.gz', import.meta.url).pathname;
const lineas = leerJsonl(ruta);
const tramos = new Map();
for (const l of lineas) {
  if (!tramos.has(l.tramo)) tramos.set(l.tramo, []);
  tramos.get(l.tramo).push(l);
}

test('el fixture de paridad cubre sesiones reales y escenarios sinteticos', () => {
  assert.ok(lineas.length > 800, `${lineas.length} frames`);
  assert.ok([...tramos.keys()].some((t) => t.startsWith('dnrzh8-')));
  assert.ok([...tramos.keys()].some((t) => t.startsWith('sint-')));
});

for (const [tramo, frames] of tramos) {
  test(`captura web reproduce ${tramo}`, () => {
    const captura = crearCaptura();
    for (const l of frames) {
      const frame = frameDeEntrada(l.in);
      const esp = esperadoDe(frame, captura.process(frame),
        {conVector: 'vec' in l.esp});
      assert.deepStrictEqual(esp, l.esp, `${tramo} frame ${l.i}`);
    }
  });
}
