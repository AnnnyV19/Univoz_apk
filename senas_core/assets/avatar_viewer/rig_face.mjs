// Cara del usuario -> avatar (FaceFrameV1, canal aparte de 152D).
//
// Los rasgos no manuales (cejas, boca, mirada, giro de cabeza) son parte de
// la lengua de senas. Holistic entrega 478 puntos de cara y blendshapes; aqui
// se traducen a expresiones VRM 1.0 y a un giro de cabeza.
//
// Convencion de la cabeza (vista de interlocutor): yaw > 0 = gira hacia SU
// izquierda (la nariz va a la derecha de la imagen); pitch > 0 = mira arriba;
// roll > 0 = inclina hacia su hombro derecho (lado izquierdo de la imagen).

// Puntos clave que viajan desde Android (FACE_KEYPOINTS en Kotlin,
// kFaceKeypoints en Dart). Cubren todo lo que usan las funciones de abajo.
export const FACE_KEYPOINTS = Object.freeze([1, 10, 152, 33, 133, 159, 145,
  263, 362, 386, 374, 13, 14, 61, 291, 105, 334]);

/**
 * Reconstruye una malla dispersa (478 posiciones, solo las clave llenas)
 * desde los puntos clave [[x, y, z], ...] en el orden de FACE_KEYPOINTS.
 */
export function faceFromKeypoints(points) {
  if (!Array.isArray(points) || points.length !== FACE_KEYPOINTS.length) return null;
  const out = new Array(478).fill(null);
  for (let k = 0; k < FACE_KEYPOINTS.length; k++) {
    const p = points[k];
    if (!Array.isArray(p) || p.length < 3 || !p.every((v) => Number.isFinite(Number(v)))) {
      return null;
    }
    out[FACE_KEYPOINTS[k]] = {x: Number(p[0]), y: Number(p[1]), z: Number(p[2])};
  }
  return out;
}

export const FACE_IDX = Object.freeze({
  NOSE_TIP: 1, FOREHEAD: 10, CHIN: 152,
  RIGHT_EYE_OUTER: 33, LEFT_EYE_OUTER: 263,
});

const clamp01 = (v) => Math.max(0, Math.min(1, Number(v) || 0));
const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2],
  a[0] * b[1] - a[1] * b[0]];
const unit = (a) => {
  const m = Math.hypot(a[0], a[1], a[2]);
  return m > 1e-9 ? [a[0] / m, a[1] / m, a[2] / m] : null;
};

/**
 * Giro de cabeza desde la malla facial en coordenadas de imagen.
 * [aspect] = ancho / alto del video (x y z vienen normalizados por el ancho).
 */
export function headRotationFromFace(landmarks, {aspect = 1} = {}) {
  if (!Array.isArray(landmarks) || landmarks.length < 264) return null;
  // imagen (x der, y abajo, z se aleja) -> camara (x der, y arriba, z hacia
  // la camara), x y z en las mismas unidades que y.
  const p = (i) => {
    const q = landmarks[i];
    return [Number(q?.x) * aspect, -Number(q?.y), -Number(q?.z) * aspect];
  };
  const ejeX = unit(sub(p(FACE_IDX.LEFT_EYE_OUTER), p(FACE_IDX.RIGHT_EYE_OUTER)));
  const arriba = sub(p(FACE_IDX.FOREHEAD), p(FACE_IDX.CHIN));
  if (!ejeX || ![...ejeX, ...arriba].every(Number.isFinite)) return null;
  const ejeY = unit(sub(arriba, ejeX.map((v) => v * dot(arriba, ejeX))));
  if (!ejeY) return null;
  const ejeZ = cross(ejeX, ejeY); // normal de la cara, hacia la camara
  // R = Ry(yaw) Rx(pitch) Rz(roll); columnas = ejeX, ejeY, ejeZ.
  const pitch = Math.asin(Math.max(-1, Math.min(1, ejeZ[1])));
  const yaw = Math.atan2(ejeZ[0], ejeZ[2]);
  const roll = Math.atan2(ejeX[1], ejeY[1]);
  return {yaw, pitch, roll};
}

/** Blendshapes de MediaPipe (ARKit) -> expresiones VRM 1.0 en [0, 1]. */
export function blendshapesToVrmExpressions(bs) {
  if (!bs || typeof bs !== 'object') return {};
  const g = (k) => clamp01(bs[k]);
  return {
    blinkLeft: g('eyeBlinkLeft'),
    blinkRight: g('eyeBlinkRight'),
    aa: g('jawOpen'),
    ou: Math.max(g('mouthPucker'), g('mouthFunnel')),
    ee: clamp01((g('mouthStretchLeft') + g('mouthStretchRight')) / 2),
    happy: clamp01((g('mouthSmileLeft') + g('mouthSmileRight')) / 2),
    angry: clamp01((g('browDownLeft') + g('browDownRight')) / 2),
    surprised: clamp01((g('browInnerUp') +
      (g('eyeWideLeft') + g('eyeWideRight')) / 2) / 2),
  };
}

/** Vista espejo: ojos intercambiados, yaw y roll invertidos. */
export function mirrorFaceSignals(expressions, head) {
  const e = {...expressions};
  if ('blinkLeft' in e || 'blinkRight' in e) {
    [e.blinkLeft, e.blinkRight] = [expressions.blinkRight, expressions.blinkLeft];
  }
  return {
    expressions: e,
    head: head ? {yaw: -head.yaw, pitch: head.pitch, roll: -head.roll} : null,
  };
}

// Indices de la malla facial de MediaPipe (478 puntos). "Derecho" = de la
// persona.
const EYE = {
  right: {outer: 33, inner: 133, top: 159, bottom: 145, brow: 105},
  left: {outer: 263, inner: 362, top: 386, bottom: 374, brow: 334},
};
const LIP_TOP = 13, LIP_BOTTOM = 14, MOUTH_RIGHT = 61, MOUTH_LEFT = 291;

// Umbrales sobre proporciones de la propia cara (no dependen de distancia a
// la camara). Aproximados para un adulto; ajustables tras prueba fisica.
const EAR_OPEN = 0.25, EAR_CLOSED = 0.10;      // alto/ancho del ojo
const JAW_FULL = 0.18;                          // labios / alto de cara
const SMILE_NEUTRAL = 0.52, SMILE_FULL = 0.65;  // boca / ancho entre ojos
const BROW_NEUTRAL = 0.22, BROW_FULL = 0.30;    // ceja-ojo / alto de cara

/**
 * Expresiones VRM 1.0 desde la geometria de la malla facial. Funciona sin
 * blendshapes (el subgrafo de blendshapes de Holistic no corre en GPU
 * WebGL).
 */
export function expressionsFromFaceLandmarks(landmarks, {aspect = 1} = {}) {
  if (!Array.isArray(landmarks) || landmarks.length < 400) return {};
  const p = (i) => [Number(landmarks[i]?.x) * aspect, Number(landmarks[i]?.y)];
  const d = (a, b) => Math.hypot(p(a)[0] - p(b)[0], p(a)[1] - p(b)[1]);
  const alto = d(FACE_IDX.FOREHEAD, FACE_IDX.CHIN);
  const entreOjos = d(EYE.right.outer, EYE.left.outer);
  if (!(alto > 1e-6) || !(entreOjos > 1e-6)) return {};
  const lin = (v, a, b) => clamp01((v - a) / (b - a));
  const blink = (e) => lin(d(e.top, e.bottom) / Math.max(1e-6, d(e.outer, e.inner)),
    EAR_OPEN, EAR_CLOSED);
  const ceja = (d(EYE.right.brow, EYE.right.top) + d(EYE.left.brow, EYE.left.top)) /
    (2 * alto);
  return {
    blinkLeft: blink(EYE.left),
    blinkRight: blink(EYE.right),
    aa: lin(d(LIP_TOP, LIP_BOTTOM) / alto, 0, JAW_FULL),
    happy: lin(d(MOUTH_RIGHT, MOUTH_LEFT) / entreOjos, SMILE_NEUTRAL, SMILE_FULL),
    surprised: lin(ceja, BROW_NEUTRAL, BROW_FULL),
  };
}
