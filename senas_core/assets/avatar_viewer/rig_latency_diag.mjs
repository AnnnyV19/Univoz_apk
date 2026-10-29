// Diagnostico de latencia del visor embebido (Android). Solo mide; el visor
// lo crea unicamente cuando Dart enciende window.configurarLatencia(true)
// (modo desarrollador), asi que apagado no cuesta nada. Cada serie es un
// anillo de Float64Array: sin arreglos nuevos por frame. drain() se llama
// una vez por segundo y arma el resumen que viaja a Dart como 'lat:<json>'
// (Dart lo imprime con la etiqueta UnivozLat).

const kCapacidad = 256;

/** Anillo de muestras en ms con resumen p50/p95/max. */
export function createSeries(capacity = kCapacidad) {
  const buf = new Float64Array(capacity);
  let count = 0;
  let next = 0;
  return {
    push(ms) {
      if (!Number.isFinite(ms)) return;
      buf[next] = ms;
      next = (next + 1) % capacity;
      if (count < capacity) count++;
    },
    get size() { return count; },
    // Copia y ordena: solo corre en drain (1 vez por segundo).
    summary() {
      if (!count) return {n: 0, p50: null, p95: null, max: null};
      const sorted = Array.from(buf.subarray(0, count)).sort((a, b) => a - b);
      const at = (q) => sorted[Math.min(count - 1, Math.max(0, Math.ceil(count * q) - 1))];
      const r = (x) => Math.round(x * 10) / 10;
      return {n: count, p50: r(at(.5)), p95: r(at(.95)), max: r(sorted[count - 1])};
    },
    reset() { count = 0; next = 0; },
  };
}

export function createLatencyDiag({capacity = kCapacidad} = {}) {
  const apply = createSeries(capacity);   // aplicarFrameVivo completo
  const tick = createSeries(capacity);    // un tick de animar() con render
  const shown = createSeries(capacity);   // frame recibido -> primer render
  let framesIn = 0;
  let ticks = 0;
  let superseded = 0;                     // frames pisados antes de verse
  let latestId = -1;
  let latestAt = 0;
  let latestShown = true;
  let startedAt = null;

  const reset = () => {
    apply.reset(); tick.reset(); shown.reset();
    framesIn = 0; ticks = 0; superseded = 0;
  };

  return {
    /** Fin de aplicarFrameVivo: [ms] que tardo y el instante de llegada. */
    frameApplied(frameId, receivedAtMs, applyMs) {
      if (startedAt === null) startedAt = receivedAtMs;
      framesIn++;
      apply.push(applyMs);
      if (!latestShown) superseded++;
      latestId = frameId;
      latestAt = receivedAtMs;
      latestShown = false;
    },
    /** Fin de un tick de animar(): [tickMs] de trabajo y [nowMs] al terminar. */
    tickDone(tickMs, nowMs) {
      ticks++;
      tick.push(tickMs);
      if (!latestShown) {
        latestShown = true;
        shown.push(nowMs - latestAt);
      }
    },
    drain(nowMs) {
      const windowMs = startedAt === null ? 0 : Math.max(1, nowMs - startedAt);
      const out = {
        frames_in: framesIn,
        ticks,
        superseded,
        apply_ms: apply.summary(),
        tick_ms: tick.summary(),
        shown_ms: shown.summary(),
        window_ms: Math.round(windowMs),
      };
      startedAt = nowMs;
      reset();
      return out;
    },
    reset,
    get latestFrameId() { return latestId; },
  };
}
