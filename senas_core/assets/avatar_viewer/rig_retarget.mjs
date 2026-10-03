// Retargeter SignSpaceFrame -> avatar con proporciones propias.
//
// Lejos del cuerpo manda la DIRECCION de cada segmento del usuario aplicada
// a los huesos del avatar (cinematica directa): un brazo largo o corto no
// deforma la pose. Cerca de un ancla (nariz, boca, pecho) manda el LUGAR: la
// palma se resuelve contra el ancla equivalente del avatar con el mismo
// desplazamiento en anchos de hombro, para que tocar el menton siga siendo
// tocar el menton. Entre ambos extremos se mezcla con smoothstep.
//
// Marco del cuerpo del avatar: origen en el centro de hombros, +x derecha
// del personaje, +y arriba, +z al frente, en metros del avatar.

import {SS, SS_CHEST} from './rig_sign_space.mjs';

export const RETARGET_ANCHOR_NEAR = 0.25;
export const RETARGET_ANCHOR_FAR = 0.60;

const add = (a, b) => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const mul = (a, s) => [a[0] * s, a[1] * s, a[2] * s];
const len = (a) => Math.hypot(a[0], a[1], a[2]);
const lerp = (a, b, t) => add(a, mul(sub(b, a), t));
const slice3 = (v, off) => [v[off], v[off + 1], v[off + 2]];
const smoothstep = (e0, e1, x) => {
  const t = Math.max(0, Math.min(1, (x - e0) / (e1 - e0)));
  return t * t * (3 - 2 * t);
};

/**
 * Perfil del avatar en su marco del cuerpo. `shoulderL`/`shoulderR` y las
 * anclas en metros; si faltan anclas se usan proporciones humanas tipicas.
 */
export function createAvatarRigProfile({
  shoulderL, shoulderR, upperL, upperR, foreL, foreR,
  palmOffset = null, nose = null, mouth = null, chest = null,
}) {
  const shoulderWidth = len(sub(shoulderR, shoulderL));
  if (!(shoulderWidth > 0)) throw new RangeError('avatar sin ancho de hombros');
  for (const [k, v] of Object.entries({upperL, upperR, foreL, foreR})) {
    if (!(v > 0)) throw new RangeError(`avatar sin largo ${k}`);
  }
  const sw = shoulderWidth;
  return {
    shoulderWidth: sw,
    shoulders: {L: shoulderL, R: shoulderR},
    upper: {L: upperL, R: upperR},
    fore: {L: foreL, R: foreR},
    palmOffset: palmOffset ?? 0.25 * sw,
    anchors: {
      nose: nose ?? [0, 0.62 * sw, 0.22 * sw],
      mouth: mouth ?? [0, 0.48 * sw, 0.20 * sw],
      chest: chest ?? mul(SS_CHEST, sw),
    },
  };
}

/**
 * @param frame SignSpaceFrame (de signSpaceFrame o de la biblioteca)
 * @param avatar perfil de createAvatarRigProfile
 * @param side 'L' | 'R'
 * @returns {{palm, wrist, elbow, anchor, anchorWeight}|null} null si el
 *   brazo no existe en el frame (mascara): el visor conserva su estado.
 */
export function retargetArm(frame, avatar, side) {
  if (!frame?.mask?.[`arm${side}`]) return null;
  const v = frame.values;
  const L = side === 'L';
  const upperDir = slice3(v, L ? SS.OFF_UPPER_L : SS.OFF_UPPER_R);
  const foreDir = slice3(v, L ? SS.OFF_FORE_L : SS.OFF_FORE_R);
  const hasHand = !!frame.mask[`hand${side}`];
  const handDir = hasHand ? slice3(v, L ? SS.OFF_HANDDIR_L : SS.OFF_HANDDIR_R)
    : foreDir;

  const shoulder = avatar.shoulders[side];
  const upper = avatar.upper[side];
  const fore = avatar.fore[side];
  const elbow = add(shoulder, mul(upperDir, upper));
  const wristFk = add(elbow, mul(foreDir, fore));
  const palmFk = add(wristFk, mul(handDir, avatar.palmOffset));

  let palm = palmFk;
  let anchor = null;
  let anchorWeight = 0;
  if (hasHand) {
    const palmUser = slice3(v, L ? SS.OFF_PALM_L : SS.OFF_PALM_R);
    const candidates = [['chest', SS_CHEST]];
    if (frame.mask.face) {
      candidates.push(['nose', slice3(v, SS.OFF_NOSE)],
        ['mouth', slice3(v, SS.OFF_MOUTH)]);
    }
    let best = null;
    for (const [name, userAnchor] of candidates) {
      const offset = sub(palmUser, userAnchor);
      const d = len(offset);
      if (!best || d < best.d) best = {name, offset, d};
    }
    anchorWeight = 1 - smoothstep(RETARGET_ANCHOR_NEAR, RETARGET_ANCHOR_FAR, best.d);
    if (anchorWeight > 0) {
      anchor = best.name;
      const palmAnchor = add(avatar.anchors[best.name],
        mul(best.offset, avatar.shoulderWidth));
      palm = lerp(palmFk, palmAnchor, anchorWeight);
    }
  }

  let wrist = sub(palm, mul(handDir, avatar.palmOffset));
  const reach = sub(wrist, shoulder);
  const maxReach = (upper + fore) * 0.999;
  if (len(reach) > maxReach) {
    wrist = add(shoulder, mul(reach, maxReach / len(reach)));
    palm = add(wrist, mul(handDir, avatar.palmOffset));
  }
  return {palm, wrist, elbow, anchor, anchorWeight};
}

/**
 * Anclas de la cara del avatar (marco del cuerpo del avatar) desde sus
 * huesos de ojos. Todo en coordenadas de mundo del visor; `right`, `up`,
 * `front` son los ejes del avatar. Las distancias faciales se escalan por la
 * distancia entre ojos (IPD), asi sirven para avatares realistas o
 * estilizados. null si faltan ojos o los ejes son degenerados.
 */
export function faceAnchorsFromEyes({shoulderMid, eyeL, eyeR, right, up, front}) {
  const pts = [shoulderMid, eyeL, eyeR, right, up, front];
  if (pts.some((p) => !Array.isArray(p) || p.length < 3 ||
      !p.every(Number.isFinite))) return null;
  const ipd = len(sub(eyeL, eyeR));
  if (!(ipd > 1e-4)) return null;
  const mid = mul(add(eyeL, eyeR), 0.5);
  const toBody = (p) => {
    const q = sub(p, shoulderMid);
    return [q[0] * right[0] + q[1] * right[1] + q[2] * right[2],
      q[0] * up[0] + q[1] * up[1] + q[2] * up[2],
      q[0] * front[0] + q[1] * front[1] + q[2] * front[2]];
  };
  const eyes = toBody(mid);
  // Proporciones faciales humanas en IPD: nariz ~0.6 bajo los ojos y ~0.5
  // al frente; boca ~1.15 bajo los ojos y ~0.4 al frente.
  return {
    nose: [eyes[0], eyes[1] - 0.6 * ipd, eyes[2] + 0.5 * ipd],
    mouth: [eyes[0], eyes[1] - 1.15 * ipd, eyes[2] + 0.4 * ipd],
  };
}
