// Genera senas_core/test/golden/paridad_manos.jsonl.gz: frames reales de
// sesiones web (ventanas elegidas por cobertura) y escenarios sinteticos,
// con la salida esperada de la captura de manos web. Lo leen el candado
// node (paridad_manos.test.mjs), Kotlin (ParidadManosTest), Dart y Python.
//
//   node gen_paridad_manos.mjs [--sesiones ../../sesiones]
//
// Las sesiones no estan en git: el fixture si. Volver a generarlo solo si
// cambia la captura web a proposito, y revisar paridad_manos.resumen.json.
import {createHash} from 'node:crypto';
import {readFileSync, writeFileSync} from 'node:fs';
import {gzipSync} from 'node:zlib';

import {crearCaptura} from './paridad/captura_actual.mjs';
import {escenarios} from './paridad/escenarios.mjs';
import {
  codigosDe, entradaDeFrame, frameDeEntrada, reproducirTramo,
} from './paridad/replay.mjs';
import {framesDeSesion, leerJsonl} from './paridad/sesion_jsonl.mjs';

const args = process.argv.slice(2);
const opcion = (nombre, defecto) => {
  const i = args.indexOf(nombre);
  return i >= 0 ? args[i + 1] : defecto;
};
const DIR = opcion('--sesiones', new URL('../../sesiones/', import.meta.url).pathname);
const SALIDA = new URL('../../test/golden/paridad_manos.jsonl.gz', import.meta.url).pathname;
const RESUMEN = new URL('../../test/golden/paridad_manos.resumen.json', import.meta.url).pathname;

const MANIOBRAS_MANOS = ['estatica', 'pulgar', 'giro', 'puno', 'pronacion',
  'cruce', 'tapar_200', 'tapar_500', 'salir'];
const FUENTES = [
  {id: 'dnrzh8', archivo: '20261020T040119Z-dnrzh8.jsonl', maniobras: MANIOBRAS_MANOS,
    codigos: 'todos', tope: 640},
  {id: 'wddae4', archivo: '20261004T093623Z-wddae4.jsonl',
    maniobras: ['giro', 'pronacion', 'tapar_200'], codigos: [], tope: 150},
  {id: '9qwtjc', archivo: '20261004T075412Z-9qwtjc.jsonl', maniobras: [],
    codigos: ['hand_assignment_hysteresis', 'track_ambiguous',
      'hand_identity_swap', 'too_many_hand_candidates'], tope: 260},
];
// Debe aparecer en el fixture o el generador falla.
const REQUERIDOS = ['hand_recovered', 'hand_occluded', 'hand_position_held',
  'hand_position_jump', 'hand_surface_ambiguous', 'hand_surface_flip',
  'hand_landmarks_invalid', 'hand_far_from_arm', 'hand_duplicate',
  'hand_scale_implausible', 'hand_side_ambiguous', 'wrist_out_of_frame',
  'wrist_disagreement', 'hand_assignment_hysteresis', 'track_ambiguous',
  'stale_frame', 'hand_geometry_degenerate', 'mode:fallback',
  'mode:pose_arm_chain', 'mode:ambiguous', 'state:LOST', 'state:OCCLUDED',
  'state:TENTATIVE', 'state:TRACKING'];

const sha = (ruta) => createHash('sha256').update(readFileSync(ruta)).digest('hex');
// Las entradas pasan por el formato del fixture para reproducir lo mismo
// que reproducira cualquier otra implementacion.
const comoFixture = (frames) => frames.map((f) =>
  ({...frameDeEntrada(entradaDeFrame(f)), maniobra: f.maniobra ?? null}));

function fusionar(ventanas) {
  const orden = ventanas.slice().sort((x, y) => x.desde - y.desde);
  const out = [];
  for (const v of orden) {
    const ultima = out.at(-1);
    if (ultima && v.desde <= ultima.hasta) {
      ultima.hasta = Math.max(ultima.hasta, v.hasta);
      ultima.motivos.push(...v.motivos);
    } else out.push({...v, motivos: [...v.motivos]});
  }
  return out;
}

const lineas = [];
const resumen = {generado_con: 'captura_actual.mjs', fuentes: [], sinteticos: []};
let plantilla = null;

for (const fuente of FUENTES) {
  const ruta = DIR + fuente.archivo;
  const frames = comoFixture(framesDeSesion(leerJsonl(ruta)));
  const completa = reproducirTramo('completa', frames, crearCaptura);
  if (!plantilla && fuente.id === 'dnrzh8') {
    const i = completa.findIndex((l, k) => k > 60 && l.esp.vec &&
      l.esp.left.detected != null && l.esp.right.detected != null &&
      frames[k].candidatas.length === 2 && frames[k].maniobra === 'estatica');
    if (i >= 0) plantilla = frames[i];
  }
  const ventanas = [];
  for (const m of fuente.maniobras) {
    const i = frames.findIndex((f) => f.maniobra === m);
    if (i >= 0) ventanas.push({desde: Math.max(0, i - 20), hasta: i + 30,
      motivos: [`maniobra:${m}`]});
  }
  const objetivo = fuente.codigos === 'todos'
    ? [...new Set(completa.flatMap(codigosDe))] : fuente.codigos;
  for (const codigo of objetivo) {
    const hits = completa.map((l, k) => codigosDe(l).includes(codigo) ? k : -1)
      .filter((k) => k >= 0);
    for (const k of [hits[0], hits[Math.floor(hits.length / 2)]]) {
      if (k == null) continue;
      ventanas.push({desde: Math.max(0, k - 45), hasta: k + 15,
        motivos: [codigo]});
    }
  }
  let usados = 0;
  const tramos = [];
  for (const v of fusionar(ventanas)) {
    if (usados >= fuente.tope) break;
    const hasta = Math.min(frames.length, v.hasta + 1, v.desde + fuente.tope - usados);
    const nombre = `${fuente.id}-${v.desde}`;
    const tramo = reproducirTramo(nombre, frames.slice(v.desde, hasta), crearCaptura);
    const codigos = [...new Set(tramo.flatMap(codigosDe))].sort();
    const faltan = v.motivos.filter((m) => !m.startsWith('maniobra:') &&
      !codigos.includes(m));
    usados += tramo.length;
    lineas.push(...tramo);
    tramos.push({nombre, desde: v.desde, hasta: hasta - 1, frames: tramo.length,
      motivos: [...new Set(v.motivos)], faltan, codigos});
  }
  resumen.fuentes.push({id: fuente.id, archivo: fuente.archivo, sha256: sha(ruta),
    frames_sesion: frames.length, tramos});
}

if (!plantilla) throw new Error('no hay frame plantilla con dos manos en dnrzh8');
for (const {nombre, frames} of escenarios(plantilla)) {
  const tramo = reproducirTramo(nombre, comoFixture(frames), crearCaptura);
  lineas.push(...tramo);
  resumen.sinteticos.push({nombre, frames: tramo.length,
    codigos: [...new Set(tramo.flatMap(codigosDe))].sort()});
}

const total = {};
for (const l of lineas) for (const c of codigosDe(l)) total[c] = (total[c] ?? 0) + 1;
resumen.total_frames = lineas.length;
resumen.codigos = Object.fromEntries(Object.entries(total).sort());
const faltan = REQUERIDOS.filter((c) => !total[c]);
resumen.requeridos_faltantes = faltan;

writeFileSync(SALIDA, gzipSync(lineas.map((l) => JSON.stringify(l)).join('\n') + '\n',
  {level: 9}));
writeFileSync(RESUMEN, JSON.stringify(resumen, null, 1) + '\n');
console.log(`paridad_manos: ${lineas.length} frames, ${Object.keys(total).length} codigos` +
  (faltan.length ? `; FALTAN ${faltan.join(', ')}` : ''));
if (faltan.length) process.exit(1);
