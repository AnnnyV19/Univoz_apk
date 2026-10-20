// Evento perf del visor embebido (Android): mismo contenido que el de la
// camara web (eventoPerfSesion en index.html), medido sobre los frames que
// llegan por aplicarFrameVivo. Latencia = inferencia nativa + espera hasta
// el render; no incluye el cruce Kotlin -> Dart -> WebView porque los
// relojes no son comparables.

const kMaxPendientes = 8;

const p95 = (values) => {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * .95) - 1)];
};

export function createEmbeddedPerf() {
  let received = 0;
  let withHand = 0;
  let rendered = 0;
  let latency = [];
  let infer = [];
  let tier = null;
  let thermal = null;
  const pending = new Map();

  const reset = () => {
    received = 0;
    withHand = 0;
    rendered = 0;
    latency = [];
    infer = [];
    pending.clear();
  };

  const frameReceived = ({frameId, receivedAtMs, inferMs, hasHand,
    tier: nivel, thermal: termico} = {}) => {
    received++;
    if (hasHand === true) withHand++;
    const ms = typeof inferMs === 'number' && Number.isFinite(inferMs) && inferMs >= 0
      ? inferMs : null;
    if (ms !== null) infer.push(ms);
    tier = typeof nivel === 'string' ? nivel : null;
    thermal = Number.isInteger(termico) ? termico : null;
    pending.set(frameId, {receivedAtMs: Number(receivedAtMs) || 0, inferMs: ms ?? 0});
    if (pending.size > kMaxPendientes) pending.delete(pending.keys().next().value);
  };

  const frameRendered = ({frameId, renderedAtMs}) => {
    const p = pending.get(frameId);
    if (!p) return;
    pending.delete(frameId);
    latency.push(Math.round((renderedAtMs - p.receivedAtMs + p.inferMs) * 10) / 10);
  };

  const renderTick = () => { rendered++; };

  const drain = (extra = {}) => {
    if (received === 0) {
      reset();
      return null;
    }
    const out = {
      latency_ms: latency,
      fps: {input: received, inference: received, tracking: withHand,
        pose: received, render: rendered},
      tier,
      thermal,
      infer_ms_p95: p95(infer),
      ...extra,
    };
    reset();
    return out;
  };

  return {frameReceived, frameRendered, renderTick, drain, reset};
}
