// SignSpaceFrame v1: representacion de la sena independiente del cuerpo.
// Espejo exacto de tools/sign_space.py y lib/sign_space.dart; golden en
// test/golden/sign_space_cases.json. MotionFrameV2 152D no cambia.
// Acepta landmarks como arrays [x, y, z, visibility] o como objetos de
// MediaPipe JS {x, y, z, visibility}.

export const SIGN_SPACE_VERSION = '1.0.0';
export const SIGN_SPACE_DIM = 35;
export const SS = Object.freeze({
  NOSE: 0, MOUTH_L: 9, MOUTH_R: 10,
  L_SHOULDER: 11, R_SHOULDER: 12, L_ELBOW: 13, R_ELBOW: 14,
  L_WRIST: 15, R_WRIST: 16, L_PINKY: 17, R_PINKY: 18,
  L_INDEX: 19, R_INDEX: 20, L_HIP: 23, R_HIP: 24,
  OFF_UPPER_L: 0, OFF_FORE_L: 3, OFF_UPPER_R: 6, OFF_FORE_R: 9,
  OFF_PALM_L: 12, OFF_PALM_R: 15, OFF_NOSE: 18, OFF_MOUTH: 21,
  OFF_HANDDIR_L: 24, OFF_HANDDIR_R: 27, OFF_CONTACT: 30,
  C_FACE_L: 0, C_FACE_R: 1, C_CHEST_L: 2, C_CHEST_R: 3, C_HANDS: 4,
});
export const SS_CHEST = Object.freeze([0, -0.40, 0.10]);

const MIN_VISIBILITY = 0.5;
const HIP_VISIBILITY = 0.5;
const CONTACT_FACE = 0.30;
const CONTACT_CHEST = 0.30;
const CONTACT_HANDS = 0.25;
const EPS = 1e-6;

const pt = (p) => Array.isArray(p) ? [+p[0], +p[1], +p[2]] :
  [+p?.x, +p?.y, +p?.z];
const visibility = (p) => Array.isArray(p) ? (p.length >= 4 ? +p[3] : NaN) :
  +(p?.visibility ?? NaN);
const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const cross = (a, b) => [
  a[1] * b[2] - a[2] * b[1],
  a[2] * b[0] - a[0] * b[2],
  a[0] * b[1] - a[1] * b[0],
];
const len = (a) => Math.sqrt(dot(a, a));
const unit = (a) => {
  const m = len(a);
  return m < EPS ? null : [a[0] / m, a[1] / m, a[2] / m];
};
const mid = (...ps) => [0, 1, 2].map((i) =>
  ps.reduce((s, p) => s + p[i], 0) / ps.length);

function visible(pose, idx, min) {
  return visibility(pose[idx]) >= min;
}

function bodyBase(pose, w, hipVisibility) {
  const hi = w[SS.L_SHOULDER], hd = w[SS.R_SHOULDER];
  const right = unit(sub(hd, hi));
  if (!right) return null;
  const scale = len(sub(hd, hi));
  const origin = mid(hi, hd);
  let trunk, mode;
  if (visible(pose, SS.L_HIP, hipVisibility) &&
      visible(pose, SS.R_HIP, hipVisibility)) {
    trunk = sub(origin, mid(w[SS.L_HIP], w[SS.R_HIP]));
    mode = 'full';
  } else {
    trunk = [0, -1, 0]; // vertical de la camara
    mode = 'upper';
  }
  const proj = dot(trunk, right);
  const up = unit([0, 1, 2].map((i) => trunk[i] - right[i] * proj));
  if (!up) return null;
  const front = unit(cross(up, right));
  if (!front) return null;
  return {right, up, front, origin, scale, mode};
}

function dirIn(base, a, b) {
  const d = unit(sub(b, a));
  return d ? [dot(d, base.right), dot(d, base.up), dot(d, base.front)] : null;
}

function posIn(base, p) {
  const q = sub(p, base.origin);
  return [dot(q, base.right) / base.scale, dot(q, base.up) / base.scale,
    dot(q, base.front) / base.scale];
}

// Codo con las longitudes reales del usuario (IK de dos huesos, metros);
// plano del codo desde la estimacion de MediaPipe. Espejo de
// _codo_por_ik en sign_space.py.
function elbowByIk(shoulder, wrist, upper, fore, guide) {
  const d = sub(wrist, shoulder);
  let dist = len(d);
  if (dist < EPS) return null;
  const u = d.map((v) => v / dist);
  dist = Math.min(Math.max(dist, Math.abs(upper - fore) + 1e-4), upper + fore - 1e-4);
  const a = (upper * upper - fore * fore + dist * dist) / (2 * dist);
  const h = Math.sqrt(Math.max(0, upper * upper - a * a));
  let perp = null;
  for (const pole of [sub(guide, shoulder), [0, 1, 0]]) { // Y world = abajo
    const pr = dot(pole, u);
    perp = unit([0, 1, 2].map((i) => pole[i] - u[i] * pr));
    if (perp) break;
  }
  if (!perp) return null;
  return [0, 1, 2].map((i) => shoulder[i] + u[i] * a + perp[i] * h);
}

/**
 * @param profile BodyProfileV1 opcional: con el, un codo no visible con
 *   hombro y muneca visibles se reconstruye (reconstructed[armX] = true).
 * @returns {{version, mode, scale, values: number[], mask: object,
 *   reconstructed: object}|null}
 */
export function signSpaceFrame(pose, poseWorld, {
  minVisibility = MIN_VISIBILITY,
  hipVisibility = HIP_VISIBILITY,
  profile = null,
} = {}) {
  if (!Array.isArray(pose) || pose.length < 33) return null;
  if (!Array.isArray(poseWorld) || poseWorld.length < 33) return null;
  if (!visible(pose, SS.L_SHOULDER, minVisibility) ||
      !visible(pose, SS.R_SHOULDER, minVisibility)) return null;
  const w = poseWorld.map(pt);
  if (w.slice(0, 25).some((p) => !p.every(Number.isFinite))) return null;

  const base = bodyBase(pose, w, hipVisibility);
  if (!base) return null;

  const out = new Array(SIGN_SPACE_DIM).fill(0);
  const mask = {armL: false, armR: false, handL: false, handR: false,
    face: false};
  const reconstructed = {armL: false, armR: false};
  const measures = profile?.measures ?? {};
  const palms = {};
  const put = (off, v) => { out[off] = v[0]; out[off + 1] = v[1]; out[off + 2] = v[2]; };

  for (const [side, shoulder, elbow, wrist, pinky, index, offU, offF, offP, offH] of [
    ['L', SS.L_SHOULDER, SS.L_ELBOW, SS.L_WRIST, SS.L_PINKY, SS.L_INDEX,
      SS.OFF_UPPER_L, SS.OFF_FORE_L, SS.OFF_PALM_L, SS.OFF_HANDDIR_L],
    ['R', SS.R_SHOULDER, SS.R_ELBOW, SS.R_WRIST, SS.R_PINKY, SS.R_INDEX,
      SS.OFF_UPPER_R, SS.OFF_FORE_R, SS.OFF_PALM_R, SS.OFF_HANDDIR_R],
  ]) {
    if (visible(pose, elbow, minVisibility) && visible(pose, wrist, minVisibility)) {
      const du = dirIn(base, w[shoulder], w[elbow]);
      const df = dirIn(base, w[elbow], w[wrist]);
      if (du && df) {
        put(offU, du);
        put(offF, df);
        mask[`arm${side}`] = true;
      }
    } else if (visible(pose, wrist, minVisibility) &&
        measures[`upper${side}`] && measures[`fore${side}`]) {
      const ik = elbowByIk(w[shoulder], w[wrist], measures[`upper${side}`],
        measures[`fore${side}`], w[elbow]);
      const du = ik && dirIn(base, w[shoulder], ik);
      const df = ik && dirIn(base, ik, w[wrist]);
      if (du && df) {
        put(offU, du);
        put(offF, df);
        mask[`arm${side}`] = true;
        reconstructed[`arm${side}`] = true;
      }
    }
    if (visible(pose, wrist, minVisibility)) {
      const dh = dirIn(base, w[wrist], mid(w[pinky], w[index]));
      if (dh) {
        const palm = posIn(base, mid(w[wrist], w[pinky], w[index]));
        put(offP, palm);
        put(offH, dh);
        mask[`hand${side}`] = true;
        palms[side] = palm;
      }
    }
  }

  if (visible(pose, SS.NOSE, minVisibility)) {
    put(SS.OFF_NOSE, posIn(base, w[SS.NOSE]));
    put(SS.OFF_MOUTH, posIn(base, mid(w[SS.MOUTH_L], w[SS.MOUTH_R])));
    mask.face = true;
  }

  const nose = out.slice(SS.OFF_NOSE, SS.OFF_NOSE + 3);
  const mouth = out.slice(SS.OFF_MOUTH, SS.OFF_MOUTH + 3);
  for (const [side, cFace, cChest] of [['L', SS.C_FACE_L, SS.C_CHEST_L],
    ['R', SS.C_FACE_R, SS.C_CHEST_R]]) {
    const palm = palms[side];
    if (!palm) continue;
    if (mask.face && Math.min(len(sub(palm, nose)), len(sub(palm, mouth))) <
        CONTACT_FACE) out[SS.OFF_CONTACT + cFace] = 1;
    if (len(sub(palm, SS_CHEST)) < CONTACT_CHEST) out[SS.OFF_CONTACT + cChest] = 1;
  }
  if (palms.L && palms.R && len(sub(palms.L, palms.R)) < CONTACT_HANDS) {
    out[SS.OFF_CONTACT + SS.C_HANDS] = 1;
  }

  return {version: SIGN_SPACE_VERSION, mode: base.mode, scale: base.scale,
    values: out, mask, reconstructed};
}

const MASK_KEYS = ['armL', 'armR', 'handL', 'handR', 'face'];

/**
 * Valida un SignSpaceFrame recibido por el puente (Dart) o de la biblioteca.
 * Devuelve el frame normalizado o null si no cumple el contrato v1.
 */
export function parseSignSpaceFrame(raw) {
  if (!raw || typeof raw !== 'object') return null;
  if (raw.version !== SIGN_SPACE_VERSION) return null;
  if (raw.mode !== 'full' && raw.mode !== 'upper') return null;
  const values = raw.values;
  if (!Array.isArray(values) || values.length !== SIGN_SPACE_DIM ||
      values.some((v) => !Number.isFinite(Number(v)))) return null;
  if (!raw.mask || MASK_KEYS.some((k) => typeof raw.mask[k] !== 'boolean')) {
    return null;
  }
  return {
    version: raw.version,
    mode: raw.mode,
    scale: Number(raw.scale),
    values: values.map(Number),
    mask: Object.fromEntries(MASK_KEYS.map((k) => [k, raw.mask[k]])),
    // Opcional (frames viejos no lo traen): brazo con codo reconstruido.
    reconstructed: {armL: raw.reconstructed?.armL === true,
      armR: raw.reconstructed?.armR === true},
  };
}

/**
 * Valida la pista SignSpace de una sena de biblioteca (MotionSequenceV2 con
 * campo opcional `sign_space`). Debe tener tantas entradas como frames 152D;
 * cada entrada es un SignSpaceFrame o null (frame sin cuerpo utilizable).
 * Devuelve el arreglo validado, o null si la pista no sirve: en ese caso el
 * visor reproduce solo con 152D, como antes.
 */
export function parseSignSpaceSequence(raw, frameCount) {
  if (!Array.isArray(raw) || raw.length !== frameCount) return null;
  const out = [];
  for (const entry of raw) {
    if (entry === null) {
      out.push(null);
      continue;
    }
    const frame = parseSignSpaceFrame(entry);
    if (!frame) return null;
    out.push(frame);
  }
  return out.some(Boolean) ? out : null;
}

// Grupos continuos del frame y la mascara que los habilita.
const FILTER_GROUPS = [
  {mask: 'armL', offsets: [SS.OFF_UPPER_L, SS.OFF_FORE_L], unit: true},
  {mask: 'armR', offsets: [SS.OFF_UPPER_R, SS.OFF_FORE_R], unit: true},
  {mask: 'handL', offsets: [SS.OFF_PALM_L], unit: false},
  {mask: 'handR', offsets: [SS.OFF_PALM_R], unit: false},
  {mask: 'handL', offsets: [SS.OFF_HANDDIR_L], unit: true},
  {mask: 'handR', offsets: [SS.OFF_HANDDIR_R], unit: true},
  {mask: 'face', offsets: [SS.OFF_NOSE, SS.OFF_MOUTH], unit: false},
];

function oneEuro(minCutoff, beta, dCutoff = 1) {
  let ready = false, prev = 0, prevRaw = 0, prevVel = 0, prevT = 0;
  const alpha = (cutoff, dtMs) => {
    const tau = 1 / (2 * Math.PI * Math.max(1e-6, cutoff));
    return 1 / (1 + tau / (dtMs / 1000));
  };
  return {
    filter(x, t) {
      if (!ready) {
        ready = true;
        prev = prevRaw = x;
        prevT = t;
        return x;
      }
      const dt = Math.max(1, Math.min(200, t - prevT));
      const ad = alpha(dCutoff, dt);
      const vel = ad * ((x - prevRaw) / (dt / 1000)) + (1 - ad) * prevVel;
      const a = alpha(minCutoff + beta * Math.abs(vel), dt);
      prev = a * x + (1 - a) * prev;
      prevRaw = x;
      prevVel = vel;
      prevT = t;
      return prev;
    },
  };
}

/**
 * One Euro por valor sobre los bloques continuos de SignSpaceFrame. Las
 * direcciones se renormalizan despues de filtrar; un grupo que desaparece
 * (mascara false) reinicia sus filtros para no arrastrar estado viejo al
 * volver. Los contactos tienen histeresis: se encienden al instante y se
 * apagan solo tras `releaseFrames` frames seguidos sin contacto.
 */
export function createSignSpaceFilter({
  minCutoff = 2.0,
  beta = 0.4,
  releaseFrames = 2,
} = {}) {
  let filters = new Map();
  let contactOff = new Array(5).fill(0);
  let contactState = new Array(5).fill(0);
  return {
    filter(frame, timeMs) {
      if (!frame) return null;
      const out = frame.values.slice();
      for (const group of FILTER_GROUPS) {
        for (const off of group.offsets) {
          if (!frame.mask[group.mask]) {
            for (let i = 0; i < 3; i++) filters.delete(off + i);
            continue;
          }
          for (let i = 0; i < 3; i++) {
            if (!filters.has(off + i)) filters.set(off + i, oneEuro(minCutoff, beta));
            out[off + i] = filters.get(off + i).filter(out[off + i], timeMs);
          }
          if (group.unit) {
            const m = Math.hypot(out[off], out[off + 1], out[off + 2]);
            if (m > EPS) for (let i = 0; i < 3; i++) out[off + i] /= m;
          }
        }
      }
      for (let c = 0; c < 5; c++) {
        const raw = out[SS.OFF_CONTACT + c];
        if (raw >= 0.5) {
          contactState[c] = 1;
          contactOff[c] = 0;
        } else if (contactState[c] && ++contactOff[c] >= releaseFrames) {
          contactState[c] = 0;
        }
        out[SS.OFF_CONTACT + c] = contactState[c];
      }
      return {...frame, values: out, mask: {...frame.mask}};
    },
    reset() {
      filters = new Map();
      contactOff = new Array(5).fill(0);
      contactState = new Array(5).fill(0);
    },
  };
}
