// Estado del avatar y transiciones suaves de pose.
//
// El visor decidia "volver a reposo" escribiendo la pose de reposo de golpe
// (mano perdida, stream sin frames, fin de reproduccion) y saltaba de reposo
// a la pose en vivo al reaparecer la mano. Aqui vive la parte pura: que
// estado tiene el avatar y como mezclar cuaterniones en el tiempo. El visor
// pone los huesos (THREE) y llama step() una vez por render.

const finite = (value) => Number.isFinite(Number(value));

export const AVATAR_STATES = Object.freeze([
  'REST', 'TRACKING', 'HOLD', 'RETURNING', 'NO_SIGNAL', 'PLAYBACK',
]);

// Factor de suavizado independiente del framerate: misma respuesta a 15,
// 60 o 144 Hz. tau = tiempo para cubrir ~63 % del camino.
export function smoothingAlpha(dtMs, tauMs) {
  const dt = Number(dtMs);
  const tau = Number(tauMs);
  if (!finite(dt) || dt <= 0) return 0;
  if (!finite(tau) || tau <= 0) return 1;
  return 1 - Math.exp(-dt / tau);
}

// Rampa 0..1 con arranque y llegada suaves (smoothstep).
export function blendWeight(elapsedMs, durationMs) {
  const duration = Number(durationMs);
  if (!finite(duration) || duration <= 0) return 1;
  const x = Math.max(0, Math.min(1, Number(elapsedMs) / duration));
  return x * x * (3 - 2 * x);
}

/**
 * Prioridad: reproduccion > sin senal > volviendo a reposo > gracia de mano
 * perdida > siguiendo > reposo. Solo describe; no mueve huesos.
 */
export function avatarStateFrom({
  playing = false, streamLive = false, streamStale = false,
  returning = false, holding = false, tracking = false,
} = {}) {
  if (playing) return 'PLAYBACK';
  if (streamLive && streamStale) return 'NO_SIGNAL';
  if (returning) return 'RETURNING';
  if (holding) return 'HOLD';
  if (tracking) return 'TRACKING';
  return 'REST';
}

export function createAvatarStateTracker({onChange = null} = {}) {
  let state = 'REST';
  let sinceMs = null;
  return {
    update(flags, nowMs) {
      const next = avatarStateFrom(flags);
      if (next === state) return {state, changed: false, sinceMs};
      const previous = state;
      state = next;
      sinceMs = finite(nowMs) ? Number(nowMs) : null;
      onChange?.({from: previous, to: next, t: sinceMs});
      return {state, changed: true, previous, sinceMs};
    },
    get state() { return state; },
    reset() { state = 'REST'; sinceMs = null; },
  };
}

// El render (60-144 Hz) corre mas rapido que el tracking (12-30 FPS) y
// antes resolvia el mismo frame en cada tick: IK, dedos y palma repetidos
// para escribir la misma pose (compuertas, filtros y longitudes ya
// deduplican por frame). Clave del frame: {frame, frameId, timestampMs,
// view, retarget, rig}; un tick con la misma clave que el ultimo frame
// resuelto no vuelve a resolver. El suavizado de salida y las transiciones
// siguen corriendo en cada tick.
export function shouldSolveFrame(previous, next) {
  if (!previous || !next) return true;
  return previous.frame !== next.frame || previous.frameId !== next.frameId ||
    previous.timestampMs !== next.timestampMs || previous.view !== next.view ||
    previous.retarget !== next.retarget || previous.rig !== next.rig;
}

function normalize(q) {
  if (!Array.isArray(q) || q.length !== 4 || !q.every(finite)) return null;
  const norm = Math.hypot(...q);
  return norm > 1e-8 ? q.map((value) => value / norm) : null;
}

export function slerpQuaternion(a, b, t) {
  const qa = normalize(a);
  let qb = normalize(b);
  if (!qa) return qb;
  if (!qb) return qa;
  let dot = qa.reduce((sum, value, index) => sum + value * qb[index], 0);
  if (dot < 0) {
    qb = qb.map((value) => -value);
    dot = -dot;
  }
  const progress = Math.max(0, Math.min(1, Number(t) || 0));
  if (dot > .9995) {
    return normalize(qa.map((value, index) =>
      value + (qb[index] - value) * progress));
  }
  const theta = Math.acos(Math.min(1, dot));
  const sinTheta = Math.sin(theta);
  const wa = Math.sin((1 - progress) * theta) / sinTheta;
  const wb = Math.sin(progress * theta) / sinTheta;
  return qa.map((value, index) => wa * value + wb * qb[index]);
}

const same = (a, b, eps = 1e-6) => Array.isArray(a) && Array.isArray(b) &&
  a.length === b.length && a.every((value, index) =>
    Math.abs(value - b[index]) <= eps);

/**
 * Transiciones con clave, por hueso (id). Dos modos:
 * - con `to`: va de `from` a una pose fija (reposo). Si otro codigo escribe
 *   el hueso durante la mezcla (tracking volvio), ese hueso sale de la
 *   transicion: manda el tracking.
 * - sin `to` (crossfade): va de `from` a lo que el visor escribio en ese
 *   render. Si nadie reescribio el hueso, se usa el ultimo objetivo visto.
 * Un hueso pertenece a una sola transicion: la mas nueva gana.
 */
export function createPoseTransitions({durationMs = 250} = {}) {
  const transitions = new Map();

  const removeBone = (id, exceptKey) => {
    for (const [key, item] of transitions) {
      if (key === exceptKey) continue;
      item.bones.delete(id);
      if (!item.bones.size) transitions.delete(key);
    }
  };

  return {
    start(key, {from, to = null, nowMs, durationMs: duration = durationMs}) {
      const bones = new Map();
      for (const [id, quaternion] of Object.entries(from ?? {})) {
        const start = normalize(quaternion);
        if (!start) continue;
        const target = to ? normalize(to[id]) : null;
        if (to && !target) continue;
        removeBone(id, key);
        bones.set(id, {from: start, to: target, lastWritten: start,
          lastTarget: target ?? start});
      }
      if (!bones.size) {
        transitions.delete(key);
        return false;
      }
      transitions.set(key, {startMs: Number(nowMs), durationMs: duration,
        fixed: !!to, bones});
      return true;
    },
    cancel(key) {
      transitions.delete(key);
    },
    has(key) {
      return transitions.has(key);
    },
    // El hueso esta en alguna transicion activa (ya se mueve suave).
    owns(id) {
      // Sin transiciones (lo normal) no se crea el iterador en cada render.
      if (!transitions.size) return false;
      for (const item of transitions.values()) {
        if (item.bones.has(id)) return true;
      }
      return false;
    },
    get size() {
      return transitions.size;
    },
    keys() {
      return [...transitions.keys()];
    },
    // current(id) -> cuaternion actual del hueso [x, y, z, w].
    step(nowMs, current) {
      const writes = [];
      const done = [];
      for (const [key, item] of transitions) {
        const weight = blendWeight(Number(nowMs) - item.startMs, item.durationMs);
        for (const [id, bone] of item.bones) {
          const now = normalize(current?.(id));
          const externo = now && !same(now, bone.lastWritten);
          if (item.fixed && externo) {
            item.bones.delete(id);
            continue;
          }
          if (!item.fixed && externo) bone.lastTarget = now;
          const target = item.fixed ? bone.to : bone.lastTarget;
          const quaternion = weight >= 1
            ? target.slice() : slerpQuaternion(bone.from, target, weight);
          bone.lastWritten = quaternion;
          writes.push({id, quaternion});
        }
        if (weight >= 1 || !item.bones.size) {
          transitions.delete(key);
          done.push(key);
        }
      }
      return {writes, done};
    },
    reset() {
      transitions.clear();
    },
  };
}

// Suavizado de salida a ritmo de render (estilo VTuber). La pose escrita
// por el tracking cambia solo cuando llega un frame de camara (15-30/s) y
// el render va a 60-144 Hz: sin esto el avatar avanza a saltos. Cada render
// la pose mostrada avanza hacia la escrita con alpha = 1 - exp(-dt/tau); tau
// es adaptativo: distancia chica (temblor) = tauMax, mucho suavizado;
// distancia grande (movimiento real) = tauMin, poco retraso.
export function adaptiveTauMs(gapRad, {tauMinMs, tauMaxMs, fastRad}) {
  const k = Math.max(0, Math.min(1, Number(gapRad) / Number(fastRad)));
  return tauMaxMs + (tauMinMs - tauMaxMs) * k;
}

// Parametros del suavizado de salida por grupo de huesos. Es el UNICO
// suavizado de la pose en vivo (el One Euro 152D, la zona muerta y su
// calibrador se quitaron). Medido con sesiones reales a 12 FPS contra la
// pose cruda: anade ~22 ms de retraso en brazos y munecas (antes ~49 ms) y el
// temblor en reposo queda en ~1.3x el de antes. tauMaxMs es la perilla: mas
// bajo = menos retraso y mas temblor. Dedos: la forma de la mano en LSM
// necesita respuesta rapida.
const kGrados = Math.PI / 180;
export const kGruposSuavizado = {
  cuerpo: {tauMinMs: 36, tauMaxMs: 60, fastRad: 15 * kGrados,
    maxSpeedRadS: 360 * kGrados},
  brazo: {tauMinMs: 30, tauMaxMs: 60, fastRad: 20 * kGrados,
    maxSpeedRadS: 900 * kGrados},
  mano: {tauMinMs: 30, tauMaxMs: 60, fastRad: 25 * kGrados,
    maxSpeedRadS: 720 * kGrados},
  dedos: {tauMinMs: 15, tauMaxMs: 45, fastRad: 20 * kGrados,
    maxSpeedRadS: 1440 * kGrados},
};

// Modos del toggle de desarrollador "Suavizado del avatar" (window.
// configurarSuavizado). Cualquier otro valor cae a 'normal'.
export const kModosSuavizado = ['normal', 'off'];
export const normalizarModoSuavizado = (modo) =>
  kModosSuavizado.includes(modo) ? modo : 'normal';

// Las cuentas de abajo son las de normalize/slerpQuaternion/quaternionGap
// con escalares y buffers reutilizados: mismas operaciones en el mismo
// orden y sin crear arreglos por tick. Solo el salto de huesos quietos
// (kQuietoEps) se aparta de la version con arreglos, en menos de 1e-9.

// normalize(q) escrito en out; false si no es un cuaternion valido.
function normalizeInto(out, x, y, z, w) {
  if (!finite(x) || !finite(y) || !finite(z) || !finite(w)) return false;
  const norm = Math.hypot(x, y, z, w);
  if (!(norm > 1e-8)) return false;
  out[0] = x / norm;
  out[1] = y / norm;
  out[2] = z / norm;
  out[3] = w / norm;
  return true;
}

const gapOf = (a, b) => 2 * Math.acos(Math.min(1,
  Math.abs(a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3])));

// slerpQuaternion(a, b, t) escrito en out (out puede ser a); a y b ya son
// cuaterniones validos. false si el resultado no se pudo normalizar.
function slerpInto(out, a, b, t) {
  const na = Math.hypot(a[0], a[1], a[2], a[3]);
  const ax = a[0] / na, ay = a[1] / na, az = a[2] / na, aw = a[3] / na;
  const nb = Math.hypot(b[0], b[1], b[2], b[3]);
  let bx = b[0] / nb, by = b[1] / nb, bz = b[2] / nb, bw = b[3] / nb;
  let dot = ax * bx + ay * by + az * bz + aw * bw;
  if (dot < 0) {
    bx = -bx; by = -by; bz = -bz; bw = -bw;
    dot = -dot;
  }
  const progress = Math.max(0, Math.min(1, Number(t) || 0));
  if (dot > .9995) {
    return normalizeInto(out, ax + (bx - ax) * progress,
      ay + (by - ay) * progress, az + (bz - az) * progress,
      aw + (bw - aw) * progress);
  }
  const theta = Math.acos(Math.min(1, dot));
  const sinTheta = Math.sin(theta);
  const wa = Math.sin((1 - progress) * theta) / sinTheta;
  const wb = Math.sin(progress * theta) / sinTheta;
  out[0] = wa * ax + wb * bx;
  out[1] = wa * ay + wb * by;
  out[2] = wa * az + wb * bz;
  out[3] = wa * aw + wb * bw;
  return true;
}

// Hueco por componente bajo el cual el hueso ya llego a su objetivo: el
// slerp lo moveria menos que esto, asi que se deja quieto (docs/15 mejora 1).
const kQuietoEps = 1e-10;

/**
 * Un estado por hueso (id). step(id, escrito, dtMs, params) devuelve la pose
 * a mostrar. Si nadie reescribio el hueso desde el ultimo step (el valor
 * actual es el que mostramos), el objetivo sigue siendo el ultimo visto.
 * stepQuaternion/followQuaternion hacen lo mismo leyendo y escribiendo un
 * cuaternion THREE en su lugar, sin crear arreglos (render a 60-144 Hz).
 */
export function createOutputSmoother() {
  const bones = new Map();
  // Escrito normalizado del paso en curso (un solo buffer para todos).
  const now = new Float64Array(4);

  // Avanza el hueso con el escrito ya normalizado en `now`.
  const advance = (id, dtMs, params) => {
    let bone = bones.get(id);
    if (!bone) {
      bone = {shown: Float64Array.from(now), target: Float64Array.from(now),
        settled: true};
      bones.set(id, bone);
      return bone;
    }
    const {shown, target} = bone;
    if (Math.abs(now[0] - shown[0]) > 1e-6 || Math.abs(now[1] - shown[1]) > 1e-6 ||
        Math.abs(now[2] - shown[2]) > 1e-6 || Math.abs(now[3] - shown[3]) > 1e-6) {
      target.set(now);
    }
    const gap = gapOf(shown, target);
    let alpha = smoothingAlpha(dtMs, adaptiveTauMs(gap, params));
    // Tope de velocidad: un giro enorme (volteo, salto de IK) se ve como
    // giro rapido y no como salto de un render.
    if (params.maxSpeedRadS && gap > 1e-9) {
      alpha = Math.min(alpha, params.maxSpeedRadS * Number(dtMs) / 1000 / gap);
    }
    if (alpha >= 1) shown.set(target);
    else slerpInto(shown, shown, target, alpha);
    bone.settled = Math.abs(target[0] - shown[0]) <= kQuietoEps &&
      Math.abs(target[1] - shown[1]) <= kQuietoEps &&
      Math.abs(target[2] - shown[2]) <= kQuietoEps &&
      Math.abs(target[3] - shown[3]) <= kQuietoEps;
    return bone;
  };

  const followNow = (id) => {
    const bone = bones.get(id);
    if (!bone) {
      bones.set(id, {shown: Float64Array.from(now),
        target: Float64Array.from(now), settled: true});
      return;
    }
    bone.shown.set(now);
    bone.target.set(now);
    bone.settled = true;
  };

  return {
    step(id, written, dtMs, params) {
      if (!Array.isArray(written) || written.length !== 4 ||
          !normalizeInto(now, written[0], written[1], written[2], written[3])) {
        return null;
      }
      return Array.from(advance(id, dtMs, params).shown);
    },
    // Igual que step, sobre un cuaternion THREE (x, y, z, w, set). Devuelve
    // true si escribio la pose mostrada en q. Un hueso que ya llego a su
    // objetivo y que nadie reescribio no se toca.
    stepQuaternion(id, q, dtMs, params) {
      const bone = bones.get(id);
      if (bone?.settled) {
        const {shown} = bone;
        if (q.x === shown[0] && q.y === shown[1] && q.z === shown[2] &&
            q.w === shown[3]) return false;
      }
      if (!normalizeInto(now, q.x, q.y, q.z, q.w)) return false;
      const {shown} = advance(id, dtMs, params);
      q.set(shown[0], shown[1], shown[2], shown[3]);
      return true;
    },
    // Sin suavizar (reproduccion, flag apagado): seguir la pose escrita para
    // que al volver no haya salto.
    follow(id, written) {
      if (Array.isArray(written) && written.length === 4 &&
          normalizeInto(now, written[0], written[1], written[2], written[3])) {
        followNow(id);
      }
    },
    followQuaternion(id, q) {
      if (normalizeInto(now, q.x, q.y, q.z, q.w)) followNow(id);
    },
    reset() {
      bones.clear();
    },
    get size() {
      return bones.size;
    },
  };
}
