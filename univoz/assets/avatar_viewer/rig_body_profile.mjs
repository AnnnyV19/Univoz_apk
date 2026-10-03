// BodyProfileV1: medidas del cuerpo + modelo de capacidad (CapabilityMask
// externo). Espejo exacto de tools/body_profile.py y lib/body_profile.dart.
// Local, versionado y borrable: solo medianas, nunca video ni landmarks.

export const BODY_PROFILE_VERSION = '1.0.0';
export const BODY_PROFILE_LIMBS = Object.freeze(['armL', 'armR', 'handL', 'handR']);
export const BODY_PROFILE_STATUSES = Object.freeze(
  ['ok', 'partial', 'not_observed', 'absent']);
export const BODY_PROFILE_STORAGE_KEY = 'univoz.bodyProfile.v1';

const MIN_SAMPLES = 20;
const OK_RATIO = 0.6;
const SEEN_RATIO = 0.1;
const MIN_VISIBILITY = 0.5;
const I = {NOSE: 0, MOUTH_L: 9, MOUTH_R: 10, L_SHOULDER: 11, R_SHOULDER: 12,
  L_ELBOW: 13, R_ELBOW: 14, L_WRIST: 15, R_WRIST: 16, L_PINKY: 17,
  R_PINKY: 18, L_INDEX: 19, R_INDEX: 20};

const pt = (p) => Array.isArray(p) ? [+p[0], +p[1], +p[2]] :
  [+p?.x, +p?.y, +p?.z];
const visibility = (p) => Array.isArray(p) ? (p.length >= 4 ? +p[3] : NaN) :
  +(p?.visibility ?? NaN);
const dist = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]);
const mid = (a, b) => [0, 1, 2].map((i) => (a[i] + b[i]) * 0.5);

function median(xs) {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) * 0.5;
}

/**
 * @param {Array<[pose, poseWorld]>} frames
 * @param {{declared?: object, minSamples?: number, minVisibility?: number}} options
 */
export function estimateBodyProfile(frames, {
  declared = {},
  minSamples = MIN_SAMPLES,
  minVisibility = MIN_VISIBILITY,
} = {}) {
  for (const [k, v] of Object.entries(declared)) {
    if (!BODY_PROFILE_LIMBS.includes(k) || !BODY_PROFILE_STATUSES.includes(v)) {
      throw new RangeError(`declaracion invalida: ${k}=${v}`);
    }
  }
  const samples = {shoulderWidth: [], upperL: [], upperR: [], foreL: [],
    foreR: [], handL: [], handR: [], neck: []};
  const reach = {armL: [], armR: []};
  const seen = {armL: 0, armR: 0, handL: 0, handR: 0};
  let n = 0;

  for (const [pose, world] of frames) {
    if (!Array.isArray(pose) || !Array.isArray(world) || pose.length < 33 ||
        world.length < 33) continue;
    const vis = (i) => visibility(pose[i]) >= minVisibility;
    if (!vis(I.L_SHOULDER) || !vis(I.R_SHOULDER)) continue;
    const w = world.map(pt);
    n += 1;
    samples.shoulderWidth.push(dist(w[I.L_SHOULDER], w[I.R_SHOULDER]));
    for (const [side, shoulder, elbow, wrist, pinky, index] of [
      ['L', I.L_SHOULDER, I.L_ELBOW, I.L_WRIST, I.L_PINKY, I.L_INDEX],
      ['R', I.R_SHOULDER, I.R_ELBOW, I.R_WRIST, I.R_PINKY, I.R_INDEX],
    ]) {
      if (vis(elbow) && vis(wrist)) {
        const upper = dist(w[shoulder], w[elbow]);
        const fore = dist(w[elbow], w[wrist]);
        samples[`upper${side}`].push(upper);
        samples[`fore${side}`].push(fore);
        seen[`arm${side}`] += 1;
        if (upper + fore > 1e-6) {
          reach[`arm${side}`].push(dist(w[shoulder], w[wrist]) / (upper + fore));
        }
      }
      if (vis(wrist)) {
        samples[`hand${side}`].push(dist(w[wrist], mid(w[pinky], w[index])));
        seen[`hand${side}`] += 1;
      }
    }
    if (vis(I.NOSE)) {
      samples.neck.push(dist(mid(w[I.L_SHOULDER], w[I.R_SHOULDER]),
        mid(w[I.MOUTH_L], w[I.MOUTH_R])));
    }
  }

  const measures = Object.fromEntries(Object.entries(samples).map(([k, v]) =>
    [k, v.length >= minSamples ? median(v) : null]));
  const capability = {};
  for (const limb of BODY_PROFILE_LIMBS) {
    if (declared[limb]) {
      capability[limb] = declared[limb];
      continue;
    }
    const ratio = n ? seen[limb] / n : 0;
    if (n >= minSamples && ratio >= OK_RATIO) capability[limb] = 'ok';
    else if (n >= minSamples && ratio < SEEN_RATIO) capability[limb] = 'not_observed';
    else capability[limb] = 'partial';
  }
  const rom = Object.fromEntries(Object.entries(reach).map(([k, v]) =>
    [k, v.length >= minSamples ? Math.max(...v) : null]));

  return {version: BODY_PROFILE_VERSION, samples: n, measures, rom, capability,
    declared: {...declared}};
}

/** Valida un perfil cargado de almacenamiento; null si no sirve. */
export function parseBodyProfile(raw) {
  try {
    const value = typeof raw === 'string' ? JSON.parse(raw) : raw;
    if (!value || value.version !== BODY_PROFILE_VERSION) return null;
    if (!value.measures || !value.capability) return null;
    return value;
  } catch (_) {
    return null;
  }
}

export const BODY_CAPTURE_PHASES = Object.freeze([
  {id: 'neutral', instruction: 'Quieto, brazos relajados a los lados'},
  {id: 'arms_forward', instruction: 'Estira los brazos al frente y muevelos despacio'},
  {id: 'hands', instruction: 'Abre y cierra las manos frente al pecho'},
]);

/**
 * Fast User Capture: guia las 3 poses y junta frames validos (hombros
 * visibles). Sin consentimiento explicito no arranca. Al terminar estima el
 * perfil; nunca guarda los frames, solo el perfil resultante.
 */
export function createBodyProfileCapture({
  framesPerPhase = 45,
  declared = {},
  minVisibility = MIN_VISIBILITY,
} = {}) {
  let state = 'idle';
  let phase = 0;
  let count = 0;
  let frames = [];
  let profile = null;

  const status = () => ({
    state,
    phase: BODY_CAPTURE_PHASES[phase]?.id ?? null,
    instruction: BODY_CAPTURE_PHASES[phase]?.instruction ?? null,
    progress: state === 'done' ? 1 :
      (phase * framesPerPhase + count) / (BODY_CAPTURE_PHASES.length * framesPerPhase),
    profile,
  });

  return {
    start({consent = false} = {}) {
      if (consent !== true) throw new Error('consentimiento requerido');
      state = 'capturing';
      phase = 0;
      count = 0;
      frames = [];
      profile = null;
      return status();
    },
    push(pose, world) {
      if (state !== 'capturing') return status();
      if (!Array.isArray(pose) || pose.length < 33 ||
          visibility(pose[I.L_SHOULDER]) < minVisibility ||
          visibility(pose[I.R_SHOULDER]) < minVisibility) return status();
      frames.push([pose, world]);
      count += 1;
      if (count >= framesPerPhase) {
        phase += 1;
        count = 0;
        if (phase >= BODY_CAPTURE_PHASES.length) {
          profile = estimateBodyProfile(frames, {declared,
            minSamples: Math.min(MIN_SAMPLES, framesPerPhase), minVisibility});
          frames = []; // no se conservan landmarks
          state = 'done';
          phase = BODY_CAPTURE_PHASES.length - 1;
        }
      }
      return status();
    },
    cancel() {
      state = 'idle';
      frames = [];
      return status();
    },
    status,
  };
}
