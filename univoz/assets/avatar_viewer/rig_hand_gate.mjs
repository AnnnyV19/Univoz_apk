// Compuerta de manos ANTES de asignar lados: usa los hombros y munecas de la
// pose como guia para que MediaPipe no "alucine" manos.
//
// Rechaza:
//   hand_duplicate          la misma mano detectada dos veces (si no, se
//                           asigna una a cada lado y el avatar mueve ambas
//                           manos iguales, como espejo)
//   hand_far_from_arm       mano lejos de las dos munecas visibles de la pose
//                           (cara, fondo, otra persona)
//   hand_scale_implausible  tamano de mano imposible respecto a los hombros
// Una mano sin ancla (munecas de la pose no visibles, p. ej. fuera de
// cuadro) pasa marcada como `unanchored`; createHandBirthGate le exige
// varios frames seguidos antes de aceptarla.

const MIN_VIS = 0.5;

const pt = (p) => ({x: Number(p?.x ?? p?.[0]), y: Number(p?.y ?? p?.[1]),
  visibility: Number(p?.visibility ?? p?.[3] ?? 1)});
const ok = (p) => Number.isFinite(p.x) && Number.isFinite(p.y);
const dist = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);

function bbox(landmarks) {
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const raw of landmarks) {
    const p = pt(raw);
    x0 = Math.min(x0, p.x); y0 = Math.min(y0, p.y);
    x1 = Math.max(x1, p.x); y1 = Math.max(y1, p.y);
  }
  return {x0, y0, x1, y1};
}

function overlap(a, b) {
  const w = Math.max(0, Math.min(a.x1, b.x1) - Math.max(a.x0, b.x0));
  const h = Math.max(0, Math.min(a.y1, b.y1) - Math.max(a.y0, b.y0));
  const area = (r) => Math.max(1e-9, (r.x1 - r.x0) * (r.y1 - r.y0));
  return (w * h) / Math.min(area(a), area(b));
}

/**
 * @param candidates [{landmarks: 21 puntos de imagen, confidence}]
 * @param pose 33 landmarks de imagen con visibility (o null)
 * @returns {{accepted: number[], rejected: {index, code}[], unanchored: number[]}}
 */
export function gateHandCandidates(candidates, pose, {
  maxWristDistance = 1.0,   // en anchos de hombro
  minHandScale = 0.12,      // muneca -> nudillo medio, en anchos de hombro
  maxHandScale = 0.9,
  duplicateDistance = 0.2,  // munecas, en anchos de hombro
  duplicateOverlap = 0.5,
} = {}) {
  const list = Array.isArray(candidates) ? candidates : [];
  const accepted = [], rejected = [], unanchored = [];
  const valid = list.map((c, index) => ({c, index})).filter(({c}) =>
    Array.isArray(c?.landmarks) && c.landmarks.length === 21 &&
    c.landmarks.every((p) => ok(pt(p))));
  for (const {index} of list.map((c, index) => ({c, index})).filter(({c}) =>
    !valid.some((v) => v.c === c))) {
    rejected.push({index, code: 'hand_landmarks_invalid'});
  }

  const ls = pt(pose?.[11]), rs = pt(pose?.[12]);
  const shouldersOk = ok(ls) && ok(rs) && ls.visibility >= MIN_VIS &&
    rs.visibility >= MIN_VIS && dist(ls, rs) > 1e-3;
  if (!shouldersOk) {
    // Sin hombros no hay guia: no bloquear, el camino viejo decide.
    return {accepted: valid.map((v) => v.index), rejected, unanchored: []};
  }
  const sw = dist(ls, rs);
  const wrists = [pt(pose[15]), pt(pose[16])]
    .filter((w) => ok(w) && w.visibility >= MIN_VIS);

  // Mas confiable primero, para que el duplicado descartado sea el debil.
  const ordered = [...valid].sort((a, b) =>
    (Number(b.c.confidence) || 0) - (Number(a.c.confidence) || 0));
  const kept = [];
  for (const {c, index} of ordered) {
    const wrist = pt(c.landmarks[0]);
    const scale = dist(wrist, pt(c.landmarks[9])) / sw;
    if (!(scale >= minHandScale && scale <= maxHandScale)) {
      rejected.push({index, code: 'hand_scale_implausible'});
      continue;
    }
    const box = bbox(c.landmarks);
    if (kept.some((k) => dist(k.wrist, wrist) / sw < duplicateDistance &&
        overlap(k.box, box) > duplicateOverlap)) {
      rejected.push({index, code: 'hand_duplicate'});
      continue;
    }
    if (wrists.length) {
      const near = Math.min(...wrists.map((w) => dist(w, wrist))) / sw;
      if (near > maxWristDistance) {
        rejected.push({index, code: 'hand_far_from_arm'});
        continue;
      }
    } else {
      unanchored.push(index);
    }
    kept.push({index, wrist, box});
    accepted.push(index);
  }
  accepted.sort((a, b) => a - b);
  rejected.sort((a, b) => a.index - b.index);
  unanchored.sort((a, b) => a - b);
  return {accepted, rejected, unanchored};
}

/**
 * Exige `frames` detecciones seguidas en el mismo lugar a las manos sin
 * ancla antes de dejarlas pasar. Las ancladas al brazo pasan al instante.
 */
export function createHandBirthGate({frames = 3, maxJump = 0.08} = {}) {
  let pending = [];
  return {
    filter(candidates, accepted, unanchored) {
      const out = [];
      const next = [];
      for (const index of accepted) {
        if (!unanchored.includes(index)) {
          out.push(index);
          continue;
        }
        const wrist = pt(candidates[index].landmarks[0]);
        const prev = pending.find((p) => dist(p.wrist, wrist) <= maxJump);
        const count = (prev?.count ?? 0) + 1;
        next.push({wrist, count});
        if (count >= frames) out.push(index);
      }
      pending = next;
      return out;
    },
    reset() { pending = []; },
  };
}
