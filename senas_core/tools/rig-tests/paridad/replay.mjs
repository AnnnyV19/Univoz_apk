// Nucleo del banco de paridad de manos: reproduce frames por una captura
// (createCapturaInline hoy; rig_hand_capture despues) y arma el registro del
// fixture `paridad_manos.jsonl.gz` que leen node, Kotlin, Dart y Python.
import {punto} from './sesion_jsonl.mjs';

const arr = (p, conVis) => {
  const out = [p.x, p.y, p.z];
  if (conVis && p.visibility != null) out.push(p.visibility);
  return out;
};

function mismosPuntos(a, b) {
  return Array.isArray(a) && Array.isArray(b) && a.length === b.length &&
    a.every((p, i) => p.x === b[i].x && p.y === b[i].y && p.z === b[i].z);
}

// Valores calculados a 12 cifras: el fixture pesa ~30 % menos y la
// tolerancia de comparacion (1e-9) queda muy por encima del redondeo.
const r12 = (v) => typeof v === 'number' && Number.isFinite(v)
  ? Number(v.toPrecision(12)) : v;

const ordenar = (errores) => errores
  .map((e) => [e.stage, e.code, e.side ?? null])
  .sort((a, b) => JSON.stringify(a) < JSON.stringify(b) ? -1 : 1);

/** Entrada del fixture (arrays planos, como la sesion). */
export function entradaDeFrame(frame) {
  return {
    t: frame.t,
    skew: frame.skewMs ?? 0,
    pose: frame.pose ? frame.pose.map((p) => arr(p, true)) : null,
    // La captura no usa la visibilidad de los puntos de mundo.
    world: frame.world ? frame.world.map((p) => arr(p, false)) : null,
    cand: frame.candidatas.map((c) => ({
      lm: c.landmarks.map((p) => arr(p, true)),
      label: c.label,
      conf: c.conf,
    })),
  };
}

/** Inversa de entradaDeFrame: lo que reproduce cualquier implementacion. */
export function frameDeEntrada(entrada) {
  return {
    t: entrada.t,
    skewMs: entrada.skew ?? 0,
    pose: entrada.pose ? entrada.pose.map(punto) : null,
    world: entrada.world ? entrada.world.map(punto) : null,
    candidatas: entrada.cand.map((c) => ({
      landmarks: c.lm.map(punto), label: c.label, conf: c.conf,
    })),
  };
}

/**
 * Salida esperada de un frame a partir de las piezas de la captura.
 * El vector no tiene estado (depende de la entrada y de que candidata quedo
 * en cada lado): se guarda en 1 de cada 4 frames y siempre que sale nulo o
 * con errores. Sin clave `vec` = no muestreado; `vec: null` = vector nulo.
 */
export function esperadoDe(frame, piezas, {conVector = true} = {}) {
  const {entrada, usable, manos, errCaptura, vec, vecRender, errVector,
    quality} = piezas;
  const tracking = manos.tracking;
  const indice = (lm) => lm == null ? null
    : frame.candidatas.findIndex((c) => mismosPuntos(c.landmarks, lm));
  const lado = (side) => {
    const t = tracking[side];
    const render = t.renderLandmarks == null ? null
      : mismosPuntos(t.renderLandmarks, t.raw) ? 'raw'
        : t.renderLandmarks.map((p) => [r12(p.x), r12(p.y), r12(p.z)]);
    return {
      raw: indice(t.raw),
      detected: indice(t.detected),
      state: t.state,
      surface: t.surface ?? null,
      surfaceChanges: t.surfaceChanges,
      recoveryFrames: t.recoveryFrames,
      restBlend: r12(t.restBlend),
      render,
      cost: r12(tracking.diagnostics.costs[side] ?? null),
    };
  };
  let render = null;
  if (vecRender == null) render = vec == null ? null : 'null';
  else if (vec != null) {
    render = {};
    vecRender.forEach((v, k) => { if (v !== vec[k]) render[k] = r12(v); });
    if (!Object.keys(render).length) render = null;
  } else render = {all: vecRender.map(r12)};
  const muestra = conVector || vec == null || errVector.length > 0;
  const vectores = muestra ? {vec: vec ? vec.map(r12) : null, vec_render: render}
    : {};
  return {
    gate: {
      accepted: entrada.accepted,
      unanchored: entrada.unanchored,
      rejected: entrada.rejected.map((r) => [r.index, r.code]),
      passed: entrada.passed,
    },
    assign: {mode: entrada.assignment.mode, sides: entrada.assignment.sides},
    usable,
    left: lado('left'),
    right: lado('right'),
    contact: {
      active: tracking.contact.active,
      wrist: r12(tracking.contact.wristDistanceShoulders),
      overlap: r12(tracking.contact.boxOverlap),
    },
    err_captura: ordenar(errCaptura),
    ...vectores,
    err_vector: ordenar(errVector),
    quality: r12(quality),
  };
}

/** Reproduce un tramo desde estado limpio; devuelve lineas del fixture. */
export function reproducirTramo(nombre, frames, crearCaptura) {
  const captura = crearCaptura();
  return frames.map((frame, i) => {
    const piezas = captura.process(frame);
    return {tramo: nombre, i, in: entradaDeFrame(frame),
      esp: esperadoDe(frame, piezas, {conVector: i % 4 === 0})};
  });
}

/** Codigos (captura + vector) de una linea, para medir cobertura. */
export function codigosDe(linea) {
  return [...linea.esp.err_captura, ...linea.esp.err_vector].map((e) => e[1])
    .concat([`mode:${linea.esp.assign.mode}`,
      `state:${linea.esp.left.state}`, `state:${linea.esp.right.state}`]);
}
