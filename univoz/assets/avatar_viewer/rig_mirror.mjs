// Vista espejo: el avatar se mueve como un reflejo del usuario (levantas la
// derecha y se mueve el brazo del mismo lado de la pantalla). Solo para
// verse a uno mismo; para traducir a otra persona el avatar NO se espeja.
//
// mirrorMotionFrame es espejo exacto de sign_norm.mirror_frame (Python) y
// mirrorFrame (Dart): golden en test/golden/golden_cases.json.

import {SS, SIGN_SPACE_DIM} from './rig_sign_space.mjs';

const MF_DIM = 152;
const OFF_LOC_L = 24, OFF_LOC_R = 27, OFF_PRES_L = 30, OFF_PRES_R = 31;
const OFF_SHAPE_L = 32, OFF_SHAPE_R = 92, HAND_PTS = 20;
const BODY_PAIRS = [[0, 1], [2, 3], [4, 5], [6, 7]];

function swapX(src, out, a, b) {
  out[a] = -src[b]; out[a + 1] = src[b + 1]; out[a + 2] = src[b + 2];
  out[b] = -src[a]; out[b + 1] = src[a + 1]; out[b + 2] = src[a + 2];
}

/** Espeja un MotionFrameV2 (152D). null si no tiene 152 valores. */
export function mirrorMotionFrame(v) {
  if (!Array.isArray(v) || v.length !== MF_DIM) return null;
  const out = new Array(MF_DIM).fill(0);
  for (const [a, b] of BODY_PAIRS) swapX(v, out, a * 3, b * 3);
  swapX(v, out, OFF_LOC_L, OFF_LOC_R);
  out[OFF_PRES_L] = v[OFF_PRES_R];
  out[OFF_PRES_R] = v[OFF_PRES_L];
  for (let j = 0; j < HAND_PTS; j++) {
    swapX(v, out, OFF_SHAPE_L + j * 3, OFF_SHAPE_R + j * 3);
  }
  return out;
}

/** Espeja un SignSpaceFrame: lados, eje x, contactos y mascara. */
export function mirrorSignSpaceFrame(frame) {
  if (!frame || !Array.isArray(frame.values) ||
      frame.values.length !== SIGN_SPACE_DIM) return null;
  const v = frame.values;
  const out = new Array(SIGN_SPACE_DIM).fill(0);
  for (const [a, b] of [[SS.OFF_UPPER_L, SS.OFF_UPPER_R],
    [SS.OFF_FORE_L, SS.OFF_FORE_R], [SS.OFF_PALM_L, SS.OFF_PALM_R],
    [SS.OFF_HANDDIR_L, SS.OFF_HANDDIR_R]]) swapX(v, out, a, b);
  for (const off of [SS.OFF_NOSE, SS.OFF_MOUTH]) {
    out[off] = -v[off]; out[off + 1] = v[off + 1]; out[off + 2] = v[off + 2];
  }
  const c = SS.OFF_CONTACT;
  out[c + SS.C_FACE_L] = v[c + SS.C_FACE_R];
  out[c + SS.C_FACE_R] = v[c + SS.C_FACE_L];
  out[c + SS.C_CHEST_L] = v[c + SS.C_CHEST_R];
  out[c + SS.C_CHEST_R] = v[c + SS.C_CHEST_L];
  out[c + SS.C_HANDS] = v[c + SS.C_HANDS];
  const m = frame.mask;
  const r = frame.reconstructed ?? {};
  return {...frame, values: out, mask: {armL: m.armR, armR: m.armL,
    handL: m.handR, handR: m.handL, face: m.face},
  reconstructed: {armL: r.armR === true, armR: r.armL === true}};
}
