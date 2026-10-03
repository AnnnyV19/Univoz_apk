// Grabador de sesion: registra TODO lo que pasa en una sesion de camara
// (landmarks crudos, manos antes y despues de la compuerta, cara, vectores,
// errores, tiempos y eventos) para encontrar fallos y mejorar el pipeline.
// Nunca guarda video ni imagenes.
//
// Formato JSONL (SessionLogV1): una linea JSON por registro.
//   {kind: 'session_start', schema, session_id, started_at_ms, meta}
//   {kind: 'frame', ...}      un frame procesado
//   {kind: 'event', type, ...} eventos (camara, perfil, fallback, errores)
//   {kind: 'session_end', frames, events, dropped, reason}
// Cada linea lleva `seq` (0, 1, 2...) para deduplicar al analizar.
// Las lineas se mandan en bloques a un `sink` (servidor local); si falla,
// se reintentan y, si la cola se llena, se descartan los frames mas viejos
// (nunca la cabecera ni los eventos) contando cuantos se perdieron.

export const SESSION_SCHEMA = 'SessionLogV1';

const round = (v, d = 4) => {
  const n = Number(v);
  if (!Number.isFinite(n)) return null;
  const f = 10 ** d;
  return Math.round(n * f) / f;
};

/** Landmarks a arrays redondeados [x, y, z(, visibility)]. */
export function compactLandmarks(points, {indices = null, digits = 4} = {}) {
  if (!Array.isArray(points)) return null;
  const pick = indices ? indices.map((i) => points[i]) : points;
  return pick.map((p) => {
    const arr = Array.isArray(p) ? p : [p?.x, p?.y, p?.z,
      ...(p?.visibility != null ? [p.visibility] : [])];
    return arr.map((v) => round(v, digits));
  });
}

export function newSessionId(date = new Date()) {
  const stamp = date.toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
  const rand = Math.random().toString(36).slice(2, 8).padEnd(6, '0');
  return `${stamp}-${rand}`;
}

export function createSessionRecorder({
  sessionId = newSessionId(),
  meta = {},
  sink = async () => false,
  flushEvery = 60,
  maxPending = 20000,
  now = () => Date.now(),
} = {}) {
  let pending = [];
  const local = [];            // copia para exportar si no hay servidor
  const maxLocal = maxPending;
  let frames = 0, events = 0, lines = 0, dropped = 0, sent = 0;
  let flushing = null;
  let closed = false;

  let seq = 0;
  const push = (record, droppable) => {
    // seq permite deduplicar: al cerrar la pagina un bloque en vuelo puede
    // llegar dos veces (fetch + sendBeacon); preferimos duplicar a perder.
    const line = JSON.stringify({seq: seq++, ...record});
    lines++;
    pending.push({line, droppable});
    local.push(line);
    if (local.length > maxLocal) {
      const i = local.findIndex((l, k) => k > 0 && l.startsWith('{"kind":"frame"'));
      local.splice(i > 0 ? i : 1, 1);
    }
    if (pending.length > maxPending) {
      const i = pending.findIndex((p) => p.droppable);
      if (i >= 0) {
        pending.splice(i, 1);
        dropped++;
      }
    }
    if (pending.length >= flushEvery) void api.flush();
  };

  const api = {
    sessionId,
    frame(data) {
      if (closed) return;
      frames++;
      push({kind: 'frame', ...data}, true);
    },
    event(type, data = {}) {
      if (closed) return;
      events++;
      push({kind: 'event', type, t_ms: now(), ...data}, false);
    },
    async flush() {
      if (flushing) return flushing;
      if (!pending.length) return true;
      const batch = pending.slice();
      flushing = (async () => {
        let ok = false;
        try { ok = await sink(sessionId, batch.map((p) => p.line)); } catch (_) {}
        if (ok) {
          pending = pending.slice(batch.length);
          sent += batch.length;
        }
        return ok;
      })();
      try { return await flushing; } finally { flushing = null; }
    },
    async close({reason = 'stop'} = {}) {
      if (closed) return;
      push({kind: 'session_end', t_ms: now(), frames, events, dropped,
        reason}, false);
      closed = true;
      await api.flush();
      if (pending.length) await api.flush();
    },
    /**
     * Cierre sincrono para cuando la pagina se va (pagehide): agrega el fin
     * de sesion y entrega TODO lo pendiente a `syncSink` (sendBeacon), que
     * no espera respuesta.
     */
    closeNow({reason = 'page_unload', maxBytes = 60000} = {},
      syncSink = null) {
      if (closed) return false;
      push({kind: 'session_end', t_ms: now(), frames, events, dropped,
        reason}, false);
      closed = true;
      // sendBeacon acepta ~64 KB: se manda en bloques, en orden.
      const send = (lines) => {
        try { return !!syncSink?.(sessionId, lines); } catch (_) { return false; }
      };
      let bloque = [], bytes = 0, ok = true;
      for (const p of pending) {
        if (bloque.length && bytes + p.line.length + 1 > maxBytes) {
          ok = send(bloque);
          if (!ok) break;
          sent += bloque.length;
          bloque = []; bytes = 0;
        }
        bloque.push(p.line);
        bytes += p.line.length + 1;
      }
      if (ok && bloque.length) {
        ok = send(bloque);
        if (ok) sent += bloque.length;
      }
      if (ok) {
        pending = [];
        return true;
      }
      // Al menos que quede registrado el cierre.
      const fin = pending.at(-1).line;
      if (send([fin])) sent += 1;
      return false;
    },
    stats: () => ({frames, events, lines, dropped, sent,
      pending: pending.length}),
    exportLines: () => local.slice(),
  };
  push({kind: 'session_start', schema: SESSION_SCHEMA, session_id: sessionId,
    started_at_ms: now(), meta}, false);
  return api;
}
