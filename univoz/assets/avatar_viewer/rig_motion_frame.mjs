// Frame de movimiento web (MotionFrameV2, 152D) y sus validaciones: lo que
// antes vivia inline en index.html (webManoUtilizable,
// webPoseGeometriaValida, normalizarFrameWeb, calcularCalidadFrameWeb).
// Puro: devuelve los errores en vez de registrarlos, asi lo comparten la
// pagina, el banco de paridad (tools/rig-tests/paridad) y los ports a
// Kotlin, Dart y Python. Espejo de normalizeFrame() en sign_norm.dart/py.

export const HAND_MARGIN = 0.15;
export const BODY_MARGIN = 0.15;
export const HAND_CONNECTIONS = Object.freeze([
  [0, 1], [1, 2], [2, 3], [3, 4],
  [0, 5], [5, 6], [6, 7], [7, 8],
  [0, 9], [9, 10], [10, 11], [11, 12],
  [0, 13], [13, 14], [14, 15], [15, 16],
  [0, 17], [17, 18], [18, 19], [19, 20],
  [5, 9], [9, 13], [13, 17],
]);
const BODY_INDEXES = [11, 12, 13, 14, 15, 16, 23, 24];

export function coord(p) {
  if (Array.isArray(p)) {
    return {
      x: Number(p[0]), y: Number(p[1]), z: Number(p[2]),
      visibility: Number(p[3] ?? 0),
    };
  }
  return {
    x: Number(p?.x), y: Number(p?.y), z: Number(p?.z),
    visibility: Number(p?.visibility ?? 0),
  };
}

export function finitePoint(p) {
  return Number.isFinite(p.x) && Number.isFinite(p.y) && Number.isFinite(p.z);
}

export function pointInFrame(p) {
  return finitePoint(p) && p.x >= 0 && p.x <= 1 && p.y >= 0 && p.y <= 1;
}

const distance = (a, b) => Math.hypot(a.x - b.x, a.y - b.y, a.z - b.z);
const ok = {ok: true, code: null, landmark: null};
const fail = (code, landmark = null) => ({ok: false, code, landmark});

/**
 * No alimentar el normalizador con manos parcialmente corruptas: MediaPipe
 * puede devolver un punto aislado fuera de cuadro durante una oclusion; si
 * se acepta, ese punto deforma angulo y orientacion de toda la mano.
 */
export function handUsable(hand) {
  if (!Array.isArray(hand) || hand.length !== 21) {
    return fail('hand_landmarks_incomplete');
  }
  const points = hand.map(coord);
  const nonFinite = points.findIndex((p) => !finitePoint(p));
  if (nonFinite >= 0) return fail('point_non_finite', nonFinite);
  // La muneca debe verse; las puntas pueden salirse un margen chico.
  if (!pointInFrame(points[0])) return fail('wrist_out_of_frame', 0);
  const inside = points.filter((p) => p.x >= -HAND_MARGIN &&
    p.x <= 1 + HAND_MARGIN && p.y >= -HAND_MARGIN &&
    p.y <= 1 + HAND_MARGIN).length;
  if (inside < 15) {
    const outside = points.findIndex((p) => p.x < -HAND_MARGIN ||
      p.x > 1 + HAND_MARGIN || p.y < -HAND_MARGIN || p.y > 1 + HAND_MARGIN);
    return fail('hand_out_of_frame', outside >= 0 ? outside : null);
  }
  const scale = Math.hypot(points[9].x - points[0].x, points[9].y - points[0].y);
  if (!Number.isFinite(scale) || scale < 0.015 || scale > 0.65) {
    return fail('hand_scale_invalid', 9);
  }
  // Cada conexion debe ser plausible respecto de la escala del MCP medio:
  // atrapa puntos intercambiados o picos sin rechazar manos abiertas/cerradas.
  for (const [a, b] of HAND_CONNECTIONS) {
    const d = distance(points[a], points[b]);
    if (!Number.isFinite(d) || d < scale * 0.018 || d > scale * 2.2) {
      return fail('hand_segment_invalid', b);
    }
  }
  return ok;
}

export function poseGeometry(pose, poseWorld) {
  if (!Array.isArray(pose) || pose.length < 33 ||
      !Array.isArray(poseWorld) || poseWorld.length < 33) {
    return fail('pose-formato');
  }
  for (const i of [11, 12, 23, 24]) {
    const p = coord(pose[i]);
    // Los hombros deben verse en la imagen; las caderas pueden quedar fuera
    // del recorte superior: sus worldLandmarks siguen dando el eje del torso.
    const shoulderInMargin = p.x >= -BODY_MARGIN && p.x <= 1 + BODY_MARGIN &&
      p.y >= -BODY_MARGIN && p.y <= 1 + BODY_MARGIN;
    if ((i === 11 || i === 12) && (!finitePoint(p) || !shoulderInMargin)) {
      return fail('shoulder_out_of_frame', i);
    }
    const needsVisibility = i === 11 || i === 12;
    if (!finitePoint(p) || (needsVisibility &&
        (!Number.isFinite(p.visibility) || p.visibility < 0.2)) ||
        !finitePoint(coord(poseWorld[i]))) {
      return fail('pose_anchor_unsafe', i);
    }
  }
  const world = poseWorld.map(coord);
  const shoulders = distance(world[11], world[12]);
  if (!Number.isFinite(shoulders) || shoulders < 1e-3) {
    return fail('hombros-degenerados');
  }
  for (const [a, b] of [[11, 13], [13, 15], [12, 14], [14, 16], [23, 24]]) {
    const d = distance(world[a], world[b]);
    if (!Number.isFinite(d) || d < shoulders * 0.08 || d > shoulders * 2.5) {
      return fail('pose_segment_invalid', b);
    }
  }
  const mid = (a, b) => ({x: (a.x + b.x) * 0.5, y: (a.y + b.y) * 0.5,
    z: (a.z + b.z) * 0.5});
  const trunk = distance(mid(world[11], world[12]), mid(world[23], world[24]));
  if (!Number.isFinite(trunk) || trunk <= shoulders * 0.25 ||
      trunk >= shoulders * 4.0) return fail('tronco-invalido');
  return ok;
}

const sub = (a, b) => [a.x - b.x, a.y - b.y, a.z - b.z];
const subArr = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const length = (a) => Math.hypot(a[0], a[1], a[2]);
const unit = (a) => {
  const m = length(a);
  return m < 1e-6 ? null : [a[0] / m, a[1] / m, a[2] / m];
};
const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const cross = (a, b) => [
  a[1] * b[2] - a[2] * b[1],
  a[2] * b[0] - a[0] * b[2],
  a[0] * b[1] - a[1] * b[0],
];

function bodyBasis(world) {
  const leftShoulder = coord(world[11]);
  const rightShoulder = coord(world[12]);
  const leftHip = coord(world[23]);
  const rightHip = coord(world[24]);
  if (!finitePoint(leftShoulder) || !finitePoint(rightShoulder) ||
      !finitePoint(leftHip) || !finitePoint(rightHip)) return null;
  const scale = length(sub(rightShoulder, leftShoulder));
  if (!Number.isFinite(scale) || scale < 1e-6) return null;
  const right = unit(sub(rightShoulder, leftShoulder));
  if (!right) return null;
  const origin = [
    (leftShoulder.x + rightShoulder.x) * 0.5,
    (leftShoulder.y + rightShoulder.y) * 0.5,
    (leftShoulder.z + rightShoulder.z) * 0.5,
  ];
  const hips = [
    (leftHip.x + rightHip.x) * 0.5,
    (leftHip.y + rightHip.y) * 0.5,
    (leftHip.z + rightHip.z) * 0.5,
  ];
  const trunk = subArr(origin, hips);
  const up = unit([
    trunk[0] - right[0] * dot(trunk, right),
    trunk[1] - right[1] * dot(trunk, right),
    trunk[2] - right[2] * dot(trunk, right),
  ]);
  if (!up) return null;
  const front = unit(cross(up, right));
  if (!front) return null;
  return {right, up, front, origin, scale};
}

function project(basis, point) {
  const p = coord(point);
  if (!finitePoint(p)) return null;
  const q = [p.x - basis.origin[0], p.y - basis.origin[1], p.z - basis.origin[2]];
  return [
    dot(q, basis.right) / basis.scale,
    dot(q, basis.up) / basis.scale,
    dot(q, basis.front) / basis.scale,
  ];
}

/**
 * Pose y manos crudas a MotionFrameV2 (152 valores) o null.
 * `renderWrists` ({left, right} en coordenadas de imagen) desplaza solo la
 * ubicacion de la mano del render hacia la muneca estabilizada (la de la
 * pose puede ir uno o dos frames atrasada), acotado a +-0.75 anchos de hombro.
 * Devuelve {vector, errors: [{stage, code, side, landmark}], validation}.
 */
export function normalizeMotionFrame(pose, poseWorld, left, right,
  {renderWrists = null} = {}) {
  const errors = [];
  let validation = '';
  const error = (code, side = null, landmark = null) => {
    errors.push({stage: 'capture', code, side, landmark});
    validation = code;
  };
  const result = (vector) => ({vector, errors, validation});
  if (!Array.isArray(pose) || pose.length < 33 ||
      !Array.isArray(poseWorld) || poseWorld.length < 33) {
    error('pose_format');
    return result(null);
  }
  const ls = coord(pose[11]);
  const rs = coord(pose[12]);
  if (!finitePoint(ls) || !finitePoint(rs) ||
      ls.visibility < 0.5 || rs.visibility < 0.5) {
    error('shoulder_confidence_low');
    return result(null);
  }
  if (BODY_INDEXES.some((i) => !finitePoint(coord(poseWorld[i])))) {
    error('pose_world_non_finite');
    return result(null);
  }
  const geometry = poseGeometry(pose, poseWorld);
  if (!geometry.ok) {
    error(geometry.code, null, geometry.landmark);
    return result(null);
  }
  const basis = bodyBasis(poseWorld);
  if (!basis) return result(null);

  const dx = rs.x - ls.x;
  const dy = rs.y - ls.y;
  const imageScale = Math.hypot(dx, dy);
  if (imageScale < 1e-6) return result(null);
  const cosT = dx / imageScale;
  const sinT = dy / imageScale;
  const out = Array(152).fill(0);

  for (let i = 0; i < BODY_INDEXES.length; i++) {
    const q = project(basis, poseWorld[BODY_INDEXES[i]]);
    if (!q) return result(null);
    out[i * 3] = q[0];
    out[i * 3 + 1] = q[1];
    out[i * 3 + 2] = q[2];
  }

  const hands = [
    [left, 'left', 24, 30, 32, 15],
    [right, 'right', 27, 31, 92, 16],
  ];
  for (const [rawHand, side, offLoc, offPres, offShape, poseWrist] of hands) {
    if (!Array.isArray(rawHand) || rawHand.length !== 21) continue;
    const hand = rawHand.map(coord);
    const usable = handUsable(hand);
    if (!usable.ok) {
      error(usable.code, side, usable.landmark);
      validation = 'mano-geometria';
      continue;
    }
    const q = project(basis, poseWorld[poseWrist]);
    if (!q) continue;
    // Muneca estabilizada del render: residuo de imagen proyectado a los
    // ejes del cuerpo y acotado. El vector semantico conserva la de la pose.
    const stableWrist = coord(renderWrists?.[side]);
    const poseWristImage = coord(pose?.[poseWrist]);
    if (finitePoint(stableWrist) && finitePoint(poseWristImage)) {
      const imageDx = (stableWrist.x - poseWristImage.x) / imageScale;
      const imageDy = (stableWrist.y - poseWristImage.y) / imageScale;
      const bodyDx = imageDx * cosT + imageDy * sinT;
      const bodyDy = -imageDx * sinT + imageDy * cosT;
      q[0] += Math.max(-.75, Math.min(.75, bodyDx));
      q[1] += Math.max(-.75, Math.min(.75, bodyDy));
    }
    out[offLoc] = q[0];
    out[offLoc + 1] = q[1];
    out[offLoc + 2] = q[2];
    out[offPres] = 1;

    const w = hand[0];
    const m = hand[9];
    let handScale = Math.hypot(m.x - w.x, m.y - w.y);
    if (handScale < 1e-6) handScale = imageScale * 0.25;
    for (let j = 1; j < 21; j++) {
      const p = hand[j];
      const qx = p.x - w.x;
      const qy = p.y - w.y;
      const k = offShape + (j - 1) * 3;
      out[k] = (qx * cosT + qy * sinT) / handScale;
      out[k + 1] = (-qx * sinT + qy * cosT) / handScale;
      out[k + 2] = (p.z - w.z) / handScale;
    }
  }
  return result(out.every(Number.isFinite) ? out : null);
}

/**
 * Calidad del frame [0, 1]: promedio de visibilidad de los 8 puntos del
 * cuerpo (el minimo es demasiado sensible: un codo tapado hundia Q) y
 * presencia de manos (una basta para una sena; dos suben la calidad).
 */
export function frameQuality(pose, poseWorld, left, right) {
  if (!Array.isArray(pose) || pose.length < 33 ||
      !Array.isArray(poseWorld) || poseWorld.length < 33) return 0;
  const body = BODY_INDEXES.map((i) => coord(pose[i]).visibility);
  if (body.some((v) => !Number.isFinite(v))) return 0;
  const visibility = Math.max(0, Math.min(1,
    body.reduce((total, value) => total + Math.max(0, Math.min(1, value)), 0) /
      body.length));
  const hands = left && right ? 1 : left || right ? 0.82 : 0.65;
  return Math.max(0, Math.min(1, visibility * 0.75 + hands * 0.25));
}
