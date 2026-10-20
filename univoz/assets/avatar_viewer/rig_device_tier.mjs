// Presupuesto de render por nivel de dispositivo (DeviceTier.kt manda el
// nivel en sourceMeta.tier). Spec:
// docs/superpowers/specs/2026-10-05-android-niveles-dispositivo-design.md

export const TIER_RENDER = Object.freeze({
  bajo: Object.freeze({frameIntervalMs: 1000 / 30, pixelRatio: .75}),
  medio: Object.freeze({frameIntervalMs: 1000 / 30, pixelRatio: 1}),
  alto: Object.freeze({frameIntervalMs: 1000 / 60, pixelRatio: 1.25}),
});

// Nivel desconocido (plugin viejo, null, basura): alto, el comportamiento
// de antes. Devuelve siempre el mismo objeto para comparar por identidad.
export function renderBudgetForTier(tier) {
  // hasOwnProperty y no Object.hasOwn: WebViews viejos (Chrome < 93) de
  // telefonos de gama baja no lo tienen.
  return typeof tier === 'string' &&
    Object.prototype.hasOwnProperty.call(TIER_RENDER, tier)
    ? TIER_RENDER[tier] : TIER_RENDER.alto;
}

// rAF corre a la tasa de la pantalla (60/90/120 Hz); se salta frames hasta
// cumplir el intervalo. 2 ms de margen absorben el jitter de rAF.
export function shouldRenderFrame(lastRenderAt, now, budget) {
  return !lastRenderAt || now - lastRenderAt >= budget.frameIntervalMs - 2;
}

// En reposo (sin frames en vivo, sin transiciones ni plantilla) el avatar
// solo parpadea: 15 FPS bastan y el telefono no dibuja de mas. Mismo
// pixelRatio que el nivel para que no cambie el tamano del lienzo.
export const IDLE_FRAME_INTERVAL_MS = 1000 / 15;
const idleBudgets = new Map();
export function idleBudgetFor(budget) {
  if (!idleBudgets.has(budget)) {
    idleBudgets.set(budget, Object.freeze({
      frameIntervalMs: Math.max(budget.frameIntervalMs, IDLE_FRAME_INTERVAL_MS),
      pixelRatio: budget.pixelRatio,
    }));
  }
  return idleBudgets.get(budget);
}
