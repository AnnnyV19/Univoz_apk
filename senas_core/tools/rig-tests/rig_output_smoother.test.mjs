import test from 'node:test';
import assert from 'node:assert/strict';

import {
  adaptiveTauMs,
  createOutputSmoother,
  smoothingAlpha,
} from '../../assets/avatar_viewer/rig_avatar_state.mjs';

// Copia de la version anterior (con arreglos por tick) de createOutputSmoother
// y sus ayudas. La nueva (sin asignaciones, docs/15 mejora 1) debe dar los
// mismos cuaterniones.
const finite = (value) => Number.isFinite(Number(value));
function normalizeViejo(q) {
  if (!Array.isArray(q) || q.length !== 4 || !q.every(finite)) return null;
  const norm = Math.hypot(...q);
  return norm > 1e-8 ? q.map((value) => value / norm) : null;
}
function slerpViejo(a, b, t) {
  const qa = normalizeViejo(a);
  let qb = normalizeViejo(b);
  if (!qa) return qb;
  if (!qb) return qa;
  let dot = qa.reduce((sum, value, index) => sum + value * qb[index], 0);
  if (dot < 0) {
    qb = qb.map((value) => -value);
    dot = -dot;
  }
  const progress = Math.max(0, Math.min(1, Number(t) || 0));
  if (dot > .9995) {
    return normalizeViejo(qa.map((value, index) =>
      value + (qb[index] - value) * progress));
  }
  const theta = Math.acos(Math.min(1, dot));
  const sinTheta = Math.sin(theta);
  const wa = Math.sin((1 - progress) * theta) / sinTheta;
  const wb = Math.sin(progress * theta) / sinTheta;
  return qa.map((value, index) => wa * value + wb * qb[index]);
}
const sameViejo = (a, b, eps = 1e-6) => Array.isArray(a) && Array.isArray(b) &&
  a.length === b.length && a.every((value, index) =>
    Math.abs(value - b[index]) <= eps);
const gapViejo = (a, b) => 2 * Math.acos(Math.min(1,
  Math.abs(a.reduce((sum, value, index) => sum + value * b[index], 0))));
function createOutputSmootherViejo() {
  const bones = new Map();
  return {
    step(id, written, dtMs, params) {
      const now = normalizeViejo(written);
      if (!now) return null;
      const bone = bones.get(id);
      if (!bone) {
        bones.set(id, {shown: now, target: now});
        return now.slice();
      }
      if (!sameViejo(now, bone.shown)) bone.target = now;
      const gap = gapViejo(bone.shown, bone.target);
      let alpha = smoothingAlpha(dtMs, adaptiveTauMs(gap, params));
      if (params.maxSpeedRadS && gap > 1e-9) {
        alpha = Math.min(alpha, params.maxSpeedRadS * Number(dtMs) / 1000 / gap);
      }
      bone.shown = alpha >= 1
        ? bone.target.slice() : slerpViejo(bone.shown, bone.target, alpha);
      return bone.shown.slice();
    },
    follow(id, written) {
      const now = normalizeViejo(written);
      if (now) bones.set(id, {shown: now, target: now});
    },
  };
}

// Cuaternion minimo con la forma de THREE.Quaternion que usa el visor.
const cuaternion = (q) => ({x: q[0], y: q[1], z: q[2], w: q[3],
  set(x, y, z, w) { this.x = x; this.y = y; this.z = z; this.w = w; return this; }});

// Generador determinista (sin Math.random: la prueba debe repetirse igual).
function aleatorio(semilla) {
  let s = semilla >>> 0;
  return () => {
    s = (s + 0x6D2B79F5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
function cuaternionAleatorio(rnd, base = null, escala = 1) {
  const q = base ? base.map((v) => v + (rnd() - .5) * escala)
    : [rnd() - .5, rnd() - .5, rnd() - .5, rnd() - .5];
  const n = Math.hypot(...q);
  return q.map((v) => v / n);
}

const kGrados = Math.PI / 180;
const kGrupos = [
  {tauMinMs: 40, tauMaxMs: 90, fastRad: 15 * kGrados, maxSpeedRadS: 360 * kGrados},
  {tauMinMs: 30, tauMaxMs: 80, fastRad: 20 * kGrados, maxSpeedRadS: 900 * kGrados},
  {tauMinMs: 30, tauMaxMs: 90, fastRad: 25 * kGrados, maxSpeedRadS: 720 * kGrados},
  {tauMinMs: 15, tauMaxMs: 45, fastRad: 20 * kGrados, maxSpeedRadS: 1440 * kGrados},
];
// NaN en los dos (escritura invalida que ninguno corrige) cuenta como igual.
const diferencia = (a, b) => Math.max(...a.map((v, i) =>
  Number.isNaN(v) && Number.isNaN(b[i]) ? 0 : Math.abs(v - b[i])));

// 42 huesos x 3000 ticks como en el visor: el tracking reescribe algunos
// huesos cada ~4 ticks (ruido, giros grandes, signo opuesto, valores
// invalidos), otros quedan quietos (llegan al objetivo y se saltan) y a ratos
// se sigue la pose sin suavizar (plantilla/transicion).
function simular(semilla, alAplicar) {
  const rnd = aleatorio(semilla);
  const huesos = Array.from({length: 42}, (_, i) => ({id: `h${i}`,
    params: kGrupos[i % kGrupos.length], quieto: i % 3 === 0,
    objetivo: cuaternionAleatorio(rnd)}));
  for (let tick = 0; tick < 3000; tick++) {
    const dt = tick % 97 === 0 ? 0 : 1000 / 60 + (rnd() - .5) * 4;
    const frameNuevo = tick % 4 === 0;
    const seguir = tick % 500 > 480;
    for (const h of huesos) {
      let escrito = null;
      if (frameNuevo && !(h.quieto && tick > 200)) {
        const r = rnd();
        if (r < .02) h.objetivo = cuaternionAleatorio(rnd);
        else if (r < .04) h.objetivo = h.objetivo.map((v) => -v);
        else h.objetivo = cuaternionAleatorio(rnd, h.objetivo, .02);
        escrito = r > .995 ? [NaN, 0, 0, 1] : h.objetivo;
      }
      alAplicar(h, escrito, dt, seguir);
    }
  }
}

test('in-place smoother matches the previous array implementation (1e-9)', () => {
  for (const semilla of [1, 7, 2026]) {
    const viejo = createOutputSmootherViejo();
    const nuevo = createOutputSmoother();
    const nuevoArreglos = createOutputSmoother();
    const huesoViejo = new Map();
    const huesoNuevo = new Map();
    let peor = 0;
    let saltados = 0;
    simular(semilla, (h, escrito, dt, seguir) => {
      // Visor viejo: lee el hueso, step/follow, escribe con q.set(...).
      const qv = huesoViejo.get(h.id) ?? cuaternion([0, 0, 0, 1]);
      const qn = huesoNuevo.get(h.id) ?? cuaternion([0, 0, 0, 1]);
      huesoViejo.set(h.id, qv);
      huesoNuevo.set(h.id, qn);
      if (escrito) {
        qv.set(...escrito);
        qn.set(...escrito);
      }
      const leido = [qv.x, qv.y, qv.z, qv.w];
      if (seguir) {
        viejo.follow(h.id, leido);
        nuevo.followQuaternion(h.id, qn);
        nuevoArreglos.follow(h.id, leido);
        return;
      }
      const mostrado = viejo.step(h.id, leido, dt, h.params);
      if (mostrado) qv.set(...mostrado);
      if (!nuevo.stepQuaternion(h.id, qn, dt, h.params)) saltados++;
      const arreglo = nuevoArreglos.step(h.id, leido, dt, h.params);
      if (mostrado) {
        assert.ok(arreglo, 'step devuelve pose cuando la vieja devuelve');
        peor = Math.max(peor, diferencia(mostrado, arreglo));
      } else {
        assert.equal(arreglo, null);
      }
      peor = Math.max(peor, diferencia([qv.x, qv.y, qv.z, qv.w],
        [qn.x, qn.y, qn.z, qn.w]));
    });
    assert.ok(peor < 1e-9, `semilla ${semilla}: diferencia ${peor}`);
    // Los huesos quietos llegan al objetivo y dejan de calcularse.
    assert.ok(saltados > 1000, `semilla ${semilla}: saltados ${saltados}`);
  }
});

test('a settled bone that someone rewrites is smoothed again', () => {
  const params = kGrupos[1];
  const smoother = createOutputSmoother();
  const q = cuaternion([0, 0, 0, 1]);
  smoother.stepQuaternion('arm', q, 16, params);
  for (let i = 0; i < 5; i++) {
    assert.equal(smoother.stepQuaternion('arm', q, 16, params), false);
  }
  const giro = [Math.sin(.2), 0, 0, Math.cos(.2)];
  q.set(...giro);
  assert.equal(smoother.stepQuaternion('arm', q, 16, params), true);
  // Avanza hacia el giro sin saltar en un render.
  assert.ok(q.x > 0 && q.x < giro[0] * .5, `x=${q.x}`);
  smoother.followQuaternion('arm', cuaternion(giro));
  assert.equal(smoother.size, 1);
});
