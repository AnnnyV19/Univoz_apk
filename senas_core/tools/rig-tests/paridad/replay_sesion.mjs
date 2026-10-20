#!/usr/bin/env node
// Paridad sobre una sesion del telefono: reproduce la captura web
// (rig_hand_capture + rig_tracking) con las entradas que registro
// sesion_captura.dart y la compara con las decisiones de CapturaManos.kt:
// compuerta, nacimiento, lados, manos utilizables y, por lado, presencia,
// estado y superficie palma/dorso.
//
//   node tools/rig-tests/paridad/replay_sesion.mjs <sesion.jsonl[.gz]>
//
// La sesion guarda landmarks a 4 cifras (como la web): un valor pegado a un
// umbral puede decidir distinto que en el telefono, que vio el valor
// completo. Por eso informa la coincidencia por campo y los primeros
// desajustes en vez de exigir 100 %.
import {framesDeSesion, leerJsonl} from './sesion_jsonl.mjs';
import {crearCaptura as capturaActual} from './captura_actual.mjs';

const CAMPOS = [
  'gate.accepted', 'gate.unanchored', 'gate.rejected', 'gate.passed',
  'assignment.mode', 'assignment.sides', 'usable',
  'tracked.left', 'tracked.right', 'tracked.left_state', 'tracked.right_state',
  'tracked.left_surface', 'tracked.right_surface',
];

const rechazos = (lista) => Array.isArray(lista)
  ? lista.map((r) => [r.index, r.code]) : undefined;

/** Lo que decidio la web para un frame, con los nombres de la sesion. */
function decisionWeb(p) {
  const t = p.manos.tracking;
  return {
    'gate.accepted': p.entrada.accepted,
    'gate.unanchored': p.entrada.unanchored,
    'gate.rejected': rechazos(p.entrada.rejected),
    'gate.passed': p.entrada.passed,
    'assignment.mode': p.entrada.assignment.mode,
    'assignment.sides': p.entrada.assignment.sides,
    'usable': p.usable,
    'tracked.left': (t.left.raw ?? t.left.detected) != null,
    'tracked.right': (t.right.raw ?? t.right.detected) != null,
    'tracked.left_state': t.left.state,
    'tracked.right_state': t.right.state,
    'tracked.left_surface': t.left.surface ?? null,
    'tracked.right_surface': t.right.surface ?? null,
  };
}

/** Lo que registro el telefono (undefined = la sesion no lo trae). */
function decisionTelefono(r) {
  const h = r.hands ?? {};
  const k = r.tracked ?? {};
  return {
    'gate.accepted': h.accepted,
    'gate.unanchored': h.unanchored,
    'gate.rejected': rechazos(h.rejected),
    'gate.passed': h.passed,
    'assignment.mode': h.assignment?.mode,
    'assignment.sides': h.assignment?.sides,
    'usable': h.usable,
    'tracked.left': k.left,
    'tracked.right': k.right,
    'tracked.left_state': k.left_state,
    'tracked.right_state': k.right_state,
    'tracked.left_surface': k.left_surface,
    'tracked.right_surface': k.right_surface,
  };
}

/**
 * Reproduce la sesion y compara campo a campo. Kotlin crea un motor (y una
 * captura limpia) al arrancar la camara o al cambiar de modo de captura:
 * aqui se reinicia igual.
 */
export function compararSesion(registros, crearCaptura = capturaActual) {
  const porSeq = new Map(registros.filter((r) => r.kind === 'frame')
    .map((r) => [r.seq, r]));
  const frames = framesDeSesion(registros);
  const porCampo = Object.fromEntries(CAMPOS.map((c) => [c, {iguales: 0, total: 0}]));
  const desajustes = [];
  let captura = null;
  let modo;
  for (const frame of frames) {
    const r = porSeq.get(frame.seq);
    if (!captura || r.mode !== modo) {
      captura = crearCaptura();
      modo = r.mode;
    }
    const web = decisionWeb(captura.process(frame));
    const telefono = decisionTelefono(r);
    for (const campo of CAMPOS) {
      if (telefono[campo] === undefined) continue;
      const c = porCampo[campo];
      c.total++;
      if (JSON.stringify(telefono[campo]) === JSON.stringify(web[campo])) c.iguales++;
      else {
        desajustes.push({seq: frame.seq, t: frame.t, campo,
          telefono: telefono[campo], web: web[campo]});
      }
    }
  }
  return {frames: frames.length, porCampo, desajustes};
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const ruta = process.argv[2];
  if (!ruta) {
    console.error('uso: node replay_sesion.mjs <sesion.jsonl[.gz]>');
    process.exit(2);
  }
  const r = compararSesion(leerJsonl(ruta));
  console.log(`frames reproducidos: ${r.frames}`);
  for (const [campo, c] of Object.entries(r.porCampo)) {
    if (!c.total) continue;
    const pct = (100 * c.iguales / c.total).toFixed(2);
    console.log(`  ${campo.padEnd(22)} ${pct.padStart(6)} %  (${c.iguales}/${c.total})`);
  }
  for (const d of r.desajustes.slice(0, 15)) {
    console.log(`  seq ${d.seq} t ${d.t} ${d.campo}: telefono=${JSON.stringify(d.telefono)}` +
      ` web=${JSON.stringify(d.web)}`);
  }
  if (r.desajustes.length > 15) console.log(`  ... ${r.desajustes.length - 15} mas`);
  process.exit(r.desajustes.length ? 1 : 0);
}
