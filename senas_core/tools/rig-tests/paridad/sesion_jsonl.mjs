// Lectura de sesiones SessionLogV1 (.jsonl o .jsonl.gz) para el banco de
// paridad de manos. Convierte los landmarks compactados ([x, y, z, vis?],
// rig_session.compactLandmarks) de vuelta a objetos {x, y, z, visibility}:
// la captura web lee `pose[15].visibility` y con arrays caeria a 1.
import {readFileSync} from 'node:fs';
import {gunzipSync} from 'node:zlib';

export function leerJsonl(ruta) {
  const crudo = readFileSync(ruta);
  const texto = ruta.endsWith('.gz') ? gunzipSync(crudo).toString('utf8')
    : crudo.toString('utf8');
  return texto.split('\n').filter((linea) => linea.trim())
    .map((linea) => JSON.parse(linea));
}

export function punto(p) {
  if (!Array.isArray(p)) return p;
  const out = {x: p[0], y: p[1], z: p[2] ?? 0};
  if (p.length > 3) out.visibility = p[3];
  return out;
}

const puntos = (lista) => Array.isArray(lista) ? lista.map(punto) : null;

// Pasos del protocolo (tecla -> maniobra), igual que analizar_sesion.PASOS.
const PASOS = {
  manos: {1: 'estatica', 2: 'pulgar', 3: 'giro', 4: 'puno', 5: 'pronacion',
    6: 'cruce', 7: 'tapar_200', 8: 'tapar_500', 9: 'salir'},
  cuerpo: {1: 'quieto', 4: 'cruce', 9: 'salir'},
};

/**
 * Frames de una sesion web listos para reproducir: lo que entro a la
 * captura de manos (pose usada, mundo, candidatas con etiqueta y confianza,
 * skew pose/manos) y la maniobra del protocolo vigente.
 */
export function framesDeSesion(registros) {
  const inicio = registros.find((r) => r.kind === 'session_start');
  const protocolo = inicio?.meta?.protocol ?? 'cuerpo';
  let maniobra = null;
  const out = [];
  for (const r of registros) {
    if (r.kind === 'event' && r.type === 'marker') {
      maniobra = PASOS[r.protocol ?? protocolo]?.[r.step] ?? null;
      continue;
    }
    if (r.kind !== 'frame' || !Number.isFinite(r.t)) continue;
    const candidatas = r.hands?.candidates;
    if (!Array.isArray(candidatas)) continue;
    out.push({
      t: r.t,
      pose: puntos(r.pose),
      world: puntos(r.world),
      skewMs: Number.isFinite(r.skew_ms) ? r.skew_ms : 0,
      candidatas: candidatas.map((c) => ({
        landmarks: puntos(c.lm),
        label: c.label ?? '',
        conf: c.conf,
      })),
      maniobra,
      seq: r.seq,
    });
  }
  return out;
}
