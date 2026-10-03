// Cara del usuario -> avatar (FaceFrameV1, canal aparte de 152D).
//
// Los rasgos no manuales (cejas, boca, mirada, giro de cabeza) son parte de
// la lengua de senas. Holistic entrega 478 puntos de cara y blendshapes; aqui
// se traducen a expresiones VRM 1.0 y a un giro de cabeza.
//
// Convencion de la cabeza (vista de interlocutor): yaw > 0 = gira hacia SU
// izquierda (la nariz va a la derecha de la imagen); pitch > 0 = mira arriba;
// roll > 0 = inclina hacia su hombro derecho (lado izquierdo de la imagen).

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
