// Escenarios sinteticos del banco de paridad. Parten de un frame real con
// las dos manos (anatomia plausible) y fuerzan los casos que las sesiones
// grabadas casi no tienen: oclusiones de 200/300/500/700 ms, saltos,
// volteos palma/dorso, cruce con etiquetas invertidas, manos sin anclar,
// timestamps repetidos, palma degenerada, duplicados con confianzas de
// separado, manos fuera de cuadro y pose ausente.

const DT = 33;

const copiaPunto = (p) => ({...p});
const copiaCand = (c) => ({...c, landmarks: c.landmarks.map(copiaPunto)});
const copiaFrame = (f) => ({
  ...f,
  pose: f.pose ? f.pose.map(copiaPunto) : null,
  world: f.world ? f.world.map(copiaPunto) : null,
  candidatas: f.candidatas.map(copiaCand),
});

function mover(cand, dx, dy = 0, dz = 0) {
  return {...cand, landmarks: cand.landmarks.map((p) =>
    ({...p, x: p.x + dx, y: p.y + dy, z: p.z + dz}))};
}

// Profundidad espejada respecto de la muneca: invierte la normal de la palma.
function reflejarZ(cand) {
  const w = cand.landmarks[0].z;
  return {...cand, landmarks: cand.landmarks.map((p) => ({...p, z: 2 * w - p.z}))};
}

function serie(base, n, alFrame) {
  const out = [];
  for (let i = 0; i < n; i++) {
    const f = copiaFrame(base);
    f.t = base.t + i * DT;
    out.push(alFrame(f, i) ?? f);
  }
  return out;
}

/**
 * plantilla: frame real con dos candidatas (izquierda anatomica primero no
 * importa) y pose completa. Devuelve [{nombre, frames}].
 */
export function escenarios(plantilla) {
  const base = copiaFrame(plantilla);
  const [a, b] = base.candidatas;
  const lista = [];

  for (const ms of [200, 300, 500, 700]) {
    const hueco = Math.round(ms / DT);
    lista.push({nombre: `sint-oclusion-${ms}`, frames: serie(base, 15 + hueco + 12,
      (f, i) => {
        if (i >= 15 && i < 15 + hueco) f.candidatas = [copiaCand(a)];
      })});
  }

  lista.push({nombre: 'sint-salto', frames: serie(base, 26, (f, i) => {
    const deriva = i * .002;
    let dx = deriva;
    if (i === 10) dx += .25; // salto aislado: se retiene
    if (i >= 15) dx += .25; // salto sostenido: se acepta al repetirse
    f.candidatas = [mover(a, dx), copiaCand(b)];
  })});

  lista.push({nombre: 'sint-volteo', frames: serie(base, 26, (f, i) => {
    const volteada = i === 10 || i >= 16;
    f.candidatas = [volteada ? reflejarZ(a) : copiaCand(a), copiaCand(b)];
  })});

  // Cruce: las munecas intercambian x en 30 frames; a mitad de camino las
  // etiquetas del detector se invierten (como hace la camara frontal).
  const dxCruce = b.landmarks[0].x - a.landmarks[0].x;
  lista.push({nombre: 'sint-cruce', frames: serie(base, 40, (f, i) => {
    const k = Math.min(1, Math.max(0, (i - 5) / 30));
    const ca = mover(a, dxCruce * k);
    const cb = mover(b, -dxCruce * k);
    if (i >= 20) {
      ca.label = b.label;
      cb.label = a.label;
    }
    f.candidatas = [ca, cb];
  })});

  lista.push({nombre: 'sint-sin-anclar', frames: serie(base, 12, (f) => {
    for (const k of [15, 16]) f.pose[k] = {...f.pose[k], visibility: .3};
  })});

  lista.push({nombre: 'sint-t-repetido', frames: serie(base, 14, (f, i) => {
    if (i === 5) f.t = base.t + 4 * DT; // mismo instante que el anterior
    if (i === 8) f.t = base.t + 6 * DT; // hacia atras
  })});

  // Palma degenerada: indice, medio, anular y menique alineados con la
  // muneca en el plano de imagen (normal nula) sin romper longitudes.
  lista.push({nombre: 'sint-palma-degenerada', frames: serie(base, 10, (f, i) => {
    if (i < 3) return;
    const m = a.landmarks;
    const w = m[0], d = m[9];
    const linea = (k) => ({...m[k], x: w.x + (d.x - w.x) * k,
      y: w.y + (d.y - w.y) * k, z: w.z});
    const lm = m.map(copiaPunto);
    lm[5] = linea(.8); lm[9] = linea(1); lm[13] = linea(1.2); lm[17] = linea(1.4);
    f.candidatas = [{...a, landmarks: lm}, copiaCand(b)];
  })});

  // Separado: etiquetas y confianzas variables mas un duplicado debil.
  lista.push({nombre: 'sint-separado-confianzas', frames: serie(base, 12, (f, i) => {
    const ca = {...copiaCand(a), conf: .62 + (i % 3) * .1};
    const cb = {...copiaCand(b), conf: .91};
    const dup = {...mover(b, .01, .005), conf: .55};
    f.candidatas = i % 4 === 0 ? [dup, ca, cb] : [ca, cb, dup];
  })});

  lista.push({nombre: 'sint-fuera-de-cuadro', frames: serie(base, 14, (f, i) => {
    if (i < 3) return;
    const w = b.landmarks[0];
    const dx = i < 8 ? 1.05 - w.x : .97 - w.x;
    f.candidatas = [copiaCand(a), mover(b, dx)];
  })});

  lista.push({nombre: 'sint-pose-ausente', frames: serie(base, 12, (f, i) => {
    if (i >= 3 && i < 8) {
      f.pose = null;
      f.world = null;
    }
  })});

  return lista;
}
