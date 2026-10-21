// ManoIK (aportado por la rama app-limpia) NO esta conectado a este visor
// (docs/17-integracion-app-limpia.md): solo se comprueba que el modulo carga y
// que su algebra basica es coherente.
import test from 'node:test';
import assert from 'node:assert/strict';

import {ManoIK} from '../../assets/avatar_viewer/rig_mano_ik.mjs';

test('ManoIK expone su API y las rotaciones basicas son consistentes', () => {
  for (const nombre of ['crearModelo', 'resolverMano', 'resolverDedoLargo',
    'resolverPulgar', 'rotZ', 'rotY', 'mm', 'aCuaternion']) {
    assert.equal(typeof ManoIK[nombre], 'function', nombre);
  }
  const casi = (a, b) => a.every((v, i) => Math.abs(v - b[i]) < 1e-9);
  assert.ok(casi(ManoIK.mm(ManoIK.rotZ(0), ManoIK.rotY(0)), ManoIK.I3()));
  assert.ok(casi(ManoIK.mm(ManoIK.rotZ(0.4), ManoIK.rotZ(-0.4)), ManoIK.I3()));
  const q = ManoIK.aCuaternion(ManoIK.rotZ(0.4));
  assert.ok(Math.abs(Math.hypot(...q) - 1) < 1e-9, 'cuaternion unitario');
});
