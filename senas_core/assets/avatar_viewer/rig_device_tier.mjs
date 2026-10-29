// Presupuesto de render por nivel de dispositivo (DeviceTier.kt manda el
// nivel en sourceMeta.tier). Spec:
// docs/superpowers/specs/2026-10-05-android-niveles-dispositivo-design.md
//
// El nivel (que sigue la carga de MediaPipe) solo decide la resolucion del
// lienzo. El ritmo de dibujo NO sale de el: es el de la pantalla mientras el
// tick propio del visor quepa en el cuadro (createRenderGovernor).

export const TIER_RENDER = Object.freeze({
  bajo: Object.freeze({frameIntervalMs: 1000 / 60, pixelRatio: .75}),
  medio: Object.freeze({frameIntervalMs: 1000 / 60, pixelRatio: 1}),
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

// Mismo presupuesto con un intervalo minimo mayor; objeto cacheado por
// (presupuesto, intervalo) para comparar por identidad.
const topes = new Map();
function conIntervaloMinimo(budget, minMs) {
  let porMs = topes.get(budget);
  if (!porMs) topes.set(budget, porMs = new Map());
  if (!porMs.has(minMs)) {
    porMs.set(minMs, Object.freeze({
      frameIntervalMs: Math.max(budget.frameIntervalMs, minMs),
      pixelRatio: budget.pixelRatio,
    }));
  }
  return porMs.get(minMs);
}

// En reposo (sin frames en vivo, sin transiciones ni plantilla) el avatar
// solo parpadea: 15 FPS bastan y el telefono no dibuja de mas. Mismo
// pixelRatio que el nivel para que no cambie el tamano del lienzo.
export const IDLE_FRAME_INTERVAL_MS = 1000 / 15;
export const idleBudgetFor = (budget) =>
  conIntervaloMinimo(budget, IDLE_FRAME_INTERVAL_MS);

// Freno por costo propio: si el p95 de los ultimos 60 ticks (JS + envio del
// dibujo) pasa de kTickLentoMs (no cabe en un cuadro de 60 Hz), el visor baja
// a 30 FPS; vuelve a la pantalla por debajo de kTickRapidoMs (histeresis, para
// no oscilar en el borde).
export const SLOW_FRAME_INTERVAL_MS = 1000 / 30;
export const kTickLentoMs = 16;
export const kTickRapidoMs = 12;
export function createRenderGovernor(ventana = 60) {
  const ticks = new Float32Array(ventana);
  let n = 0;
  let lento = false;
  return {
    tick(tickMs) {
      ticks[n++ % ventana] = tickMs;
      // El p95 se recalcula cada 15 ticks (copia ordenada de 60 numeros).
      if (n < ventana || n % 15) return;
      const p95 = Float32Array.from(ticks).sort()[Math.floor(ventana * .95)];
      lento = p95 > (lento ? kTickRapidoMs : kTickLentoMs);
    },
    get lento() { return lento; },
    budgetFor: (budget) => lento
      ? conIntervaloMinimo(budget, SLOW_FRAME_INTERVAL_MS) : budget,
  };
}
