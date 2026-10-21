// Frase: varias señas SEGUIDAS, sin volver a reposo entre una y otra
// (aportado por la rama app-limpia, 2026-10-14). Puro.
//
// Flutter manda [{frames: 32x152, fps}, ...] (una entrada por seña o por letra
// deletreada). Cada seña se limpia por separado con [preparar] (asi el
// suavizado no mezcla una seña con la siguiente), se lleva a un mismo ritmo
// (los cuadros por segundo de la mas rapida; las mas lentas se estiran) y
// entre una y otra se intercala una transicion corta que lleva la ultima pose
// de una a la primera de la siguiente. La transicion usa las mismas reglas que
// interpolarFrame: una mano que solo esta en una de las dos señas no se
// inventa, aparece/desaparece y el visor la lleva a reposo con su margen
// normal.
import { interpolarFrame } from './rig_replay.mjs';

export const kFraseTransicionMs = 260;
export const kFraseMaxSegmentos = 60;
export const kFraseFrameDim = 152;
export const kFraseTFrames = 32;

// Valida un cuadro de 152 numeros finitos.
export const esFrameValido = (frame) => Array.isArray(frame) &&
  frame.length === kFraseFrameDim &&
  frame.every((v) => Number.isFinite(Number(v)));

// Valida el arreglo completo de segmentos que manda Dart.
export const fraseValida = (segmentos) => Array.isArray(segmentos) &&
  segmentos.length > 0 && segmentos.length <= kFraseMaxSegmentos &&
  segmentos.every((s) => s && Array.isArray(s.frames) &&
    s.frames.length === kFraseTFrames && s.frames.every(esFrameValido));

const copiarSecuencia = (frames) => frames.map((f) => f.slice());

// [preparar]: limpieza por seña (rig_replay.prepararSecuencia o, por defecto,
// una simple copia: el visor de la app ya interpola al renderizar).
export function armarFrase(segmentos, preparar = copiarSecuencia) {
  const fpsSeg = segmentos.map((s) => Number.isFinite(Number(s.fps)) &&
    Number(s.fps) > 0 ? Math.min(120, Math.max(1, Number(s.fps))) : 30);
  const base = Math.max(...fpsSeg);
  const out = [];
  const nTrans = Math.max(2, Math.round(kFraseTransicionMs / 1000 * base));
  segmentos.forEach((seg, i) => {
    const P = preparar(seg.frames);
    if (out.length > 0) {
      const par = [out[out.length - 1], P[0]];
      for (let j = 1; j <= nTrans; j++) {
        const x = j / (nTrans + 1);
        const f = x * x * (3 - 2 * x);
        out.push(interpolarFrame(par, f, new Array(kFraseFrameDim).fill(0)));
      }
    }
    const n = Math.max(2, Math.round(P.length * base / fpsSeg[i]));
    for (let k = 0; k < n; k++) {
      const pos = k * (P.length - 1) / (n - 1);
      out.push(interpolarFrame(P, pos, new Array(kFraseFrameDim).fill(0)));
    }
  });
  return {frames: out, fps: base};
}
