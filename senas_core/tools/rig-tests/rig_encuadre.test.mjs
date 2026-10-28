import test from 'node:test';
import assert from 'node:assert/strict';

import {calcularEncuadreCodos} from '../../assets/avatar_viewer/rig_encuadre.mjs';

const medidas = {hombroY: 1.25, brazo: 0.25, topeY: 1.56};

test('encuadre de codos mira entre los codos y la cabeza y se acerca', () => {
  const e = calcularEncuadreCodos(medidas, 1, 1.4, 35, 1.6);
  assert.ok(e.y > 1.1 && e.y < 1.5);
  assert.ok(e.dist >= 0.55 && e.dist <= 1.8);
  assert.ok(e.dist < 1.3, 'mas cerca que el encuadre de cintura (1.3)');
});

test('una tarjeta angosta aleja la camara para que quepan los brazos', () => {
  const ancha = calcularEncuadreCodos(medidas, 1, 1.4, 35, 1.8);
  const angosta = calcularEncuadreCodos(medidas, 1, 1.4, 35, 0.6);
  assert.ok(angosta.dist > ancha.dist);
});

test('extraAbajo baja el centro y alarga el encuadre; el tope de distancia se respeta', () => {
  const sin = calcularEncuadreCodos(medidas, 1, 1.4, 35, 1.6, 0);
  const con = calcularEncuadreCodos(medidas, 1, 1.4, 35, 1.6, 0.2);
  assert.ok(con.y < sin.y);
  assert.ok(con.alto > sin.alto);
  const loco = calcularEncuadreCodos(medidas, 1, 1.4, 35, 0.05, 10);
  assert.equal(loco.dist, 1.8);
});
