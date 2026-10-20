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

const quaternionGap = (a, b) => 2 * Math.acos(Math.min(1,
  Math.abs(a.reduce((sum, value, index) => sum + value * b[index], 0))));

/**
 * Un estado por hueso (id). step(id, escrito, dtMs, params) devuelve la pose
 * a mostrar. Si nadie reescribio el hueso desde el ultimo step (el valor
 * actual es el que mostramos), el objetivo sigue siendo el ultimo visto.
 */
export function createOutputSmoother() {
  const bones = new Map();
  return {
    step(id, written, dtMs, params) {
      const now = normalize(written);
      if (!now) return null;
      const bone = bones.get(id);
      if (!bone) {
        bones.set(id, {shown: now, target: now});
        return now.slice();
      }
      if (!same(now, bone.shown)) bone.target = now;
      const gap = quaternionGap(bone.shown, bone.target);
      let alpha = smoothingAlpha(dtMs, adaptiveTauMs(gap, params));
      // Tope de velocidad: un giro enorme (volteo, salto de IK) se ve como
      // giro rapido y no como salto de un render.
      if (params.maxSpeedRadS && gap > 1e-9) {
        alpha = Math.min(alpha, params.maxSpeedRadS * Number(dtMs) / 1000 / gap);
      }
      bone.shown = alpha >= 1
        ? bone.target.slice() : slerpQuaternion(bone.shown, bone.target, alpha);
      return bone.shown.slice();
    },
    // Sin suavizar (reproduccion, flag apagado): seguir la pose escrita para
    // que al volver no haya salto.
    follow(id, written) {
      const now = normalize(written);
      if (now) bones.set(id, {shown: now, target: now});
    },
    reset() {
      bones.clear();
    },
    get size() {
      return bones.size;
    },
  };
}
