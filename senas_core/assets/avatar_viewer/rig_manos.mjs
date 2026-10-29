// Separador de manos (aportado por la rama app-limpia, 2026-10-14). Puro.
import { SeparadorCuerpo } from './rig_cuerpo.mjs';

// ---------------------------------------------------------------------
// Separador de manos: que una mano no atraviese a la otra (ni al
// antebrazo de la otra). Una persona no pasa una mano por la otra: una
// queda apoyada sobre / delante de la otra.
//
// Por que pasa: la altura y el costado de cada muñeca vienen de video 2D,
// pero la PROFUNDIDAD entre las dos manos casi no se mide. Con las dos
// manos a la misma altura las plantillas dejan una mano dentro de la otra.
//
// Que hace (matematica pura, sin THREE, probada en Node):
//  - Mide la traslacion relativa HORIZONTAL minima que separa las dos
//    manos (esferas en muñeca, palma, nudillos y dedos + antebrazos). La
//    altura de cada muñeca NO se toca jamas: solo se desplaza en
//    horizontal (si la IK tuviera que recortar el alcance, se gira en
//    horizontal para conservar la altura).
//  - La profundidad cuesta menos que el costado (asi una mano queda
//    "sobre" la otra y no se corre de lado), y en profundidad se adelanta
//    la mano que ya esta delante (atras esta el torso).
//  - Cada paso vuelve a pasar por SeparadorCuerpo, asi que nada queda
//    dentro del torso. Maximo MAX_DESPL por mano; la tasa de cambio esta
//    limitada para que no haya saltos entre cuadros.
// ---------------------------------------------------------------------
export const SeparadorManos = (() => {
  const RADIO_MUNECA = 0.022;
  const RADIOS_MANO = [];
  for (let i = 0; i < 20; i++) {
    RADIOS_MANO.push(i % 4 === 0 ? 0.014 : (i % 4 === 3 ? 0.006 : 0.008));
  }
  const RADIO_CODO = 0.040;
  const TS_ANT = [0.2, 0.4, 0.6, 0.8];
  const radioAnt = (t) => 0.044 - 0.027 * t;
  const MARGEN = 0.001;
  const TOL = 0.0004;
  const MAX_DESPL = 0.045;   // m por mano (modelo de referencia)
  const TASA = 0.01;         // m por cuadro
  const LAMBDA = 1.5;        // costo del costado respecto a la profundidad
  const KAPPA = 0.8;         // histeresis de la direccion
  const LEJOS = 0.12;        // discos mas lejos que esto no importan
  const N_PSI = 48;
  const PASES = 6;

  const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  const cruz = (a, b) => [a[1] * b[2] - a[2] * b[1],
    a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
  const suma = (a, b, s = 1) => [a[0] + b[0] * s, a[1] + b[1] * s, a[2] + b[2] * s];
  const largo = (a) => Math.sqrt(dot(a, a));
  const hayDespl = (a) => a[0] !== 0 || a[1] !== 0 || a[2] !== 0;

  // Ajusta SOLO la parte horizontal de d para que el alcance quede en
  // [rmin, rmax-1mm]; la altura no cambia.
  function topeHorizontal(d, arriba, rmax, rmin) {
    const rT = rmax - 1e-3;
    const y = dot(d, arriba);
    const h = suma(d, arriba, -y);
    const nh = largo(h);
    const n = largo(d);
    if (n > rT) {
      const H2 = rT * rT - y * y;
      if (H2 > 0 && nh > 1e-9) return suma(h.map((v) => v * Math.sqrt(H2) / nh), arriba, y);
    } else if (n < rmin) {
      const H2 = rmin * rmin - y * y;
      if (H2 > 0 && nh > 1e-9) return suma(h.map((v) => v * Math.sqrt(H2) / nh), arriba, y);
    }
    return d;
  }

  // Esferas [centro, radio] de la mano (con la muñeca) y del antebrazo.
  function puntos(e, res, k) {
    const sol = SeparadorCuerpo.ik(e, res.delta, res.giro);
    const mano = [[sol.muneca, RADIO_MUNECA * k]];
    if (e.mano) {
      for (let i = 0; i < 20; i++) {
        mano.push([suma(sol.muneca, e.mano[i]), RADIOS_MANO[i] * k]);
      }
    }
    const ant = [];
    const av = suma(sol.muneca, sol.codo, -1);
    for (const t of TS_ANT) ant.push([suma(sol.codo, av, t), radioAnt(t) * k]);
    ant.push([sol.codo, RADIO_CODO * k]);
    return {mano, ant, muneca: sol.muneca};
  }

  function penetracion(A, B, margen) {
    let pen = -1e9;
    for (const [pa, ra] of A) {
      for (const [pb, rb] of B) {
        const dx = pa[0] - pb[0], dy = pa[1] - pb[1], dz = pa[2] - pb[2];
        const p = ra + rb + margen - Math.sqrt(dx * dx + dy * dy + dz * dz);
        if (p > pen) pen = p;
      }
    }
    return pen;
  }

  // Discos (hx, hz, Rh) en el plano horizontal: la traslacion relativa T
  // de A respecto a B debe cumplir |h + T| >= Rh (la altura es fija).
  function restricciones(A, B, arriba, der, fre, margen, lejos) {
    const out = [];
    for (const [pa, ra] of A) {
      for (const [pb, rb] of B) {
        const v = [pa[0] - pb[0], pa[1] - pb[1], pa[2] - pb[2]];
        const R = ra + rb + margen;
        const dy = dot(v, arriba);
        if (Math.abs(dy) < R) {
          const h = suma(v, arriba, -dy);
          const Rh = Math.sqrt(R * R - dy * dy);
          if (largo(h) - Rh < lejos) out.push([dot(h, der), dot(h, fre), Rh]);
        }
      }
    }
    return out;
  }

  // Traslacion horizontal minima (costo anisotropico) fuera de todos los
  // discos. Para cada direccion, los discos que cortan la recta dan
  // intervalos prohibidos de t; se busca el menor t >= 0 fuera de ellos.
  const COS_PSI = [], SIN_PSI = [], PESO_PSI = [];
  for (let ip = 0; ip < N_PSI; ip++) {
    const psi = 2 * Math.PI * ip / N_PSI;
    COS_PSI.push(Math.cos(psi)); SIN_PSI.push(Math.sin(psi));
    PESO_PSI.push(Math.sqrt(LAMBDA * Math.cos(psi) ** 2 + Math.sin(psi) ** 2));
  }
  const ivA = new Float64Array(4096), ivB = new Float64Array(4096);
  function mejorT(cons, psiPrev) {
    if (cons.length === 0) return {tx: 0, tz: 0, psi: null, t: 0};
    const nc = Math.min(cons.length, ivA.length);
    let mejor = null;
    for (let ip = 0; ip < N_PSI; ip++) {
      const nx = COS_PSI[ip], nz = SIN_PSI[ip];
      let m = 0;
      for (let j = 0; j < nc; j++) {
        const c = cons[j];
        const hn = c[0] * nx + c[1] * nz;
        const disc = hn * hn - (c[0] * c[0] + c[1] * c[1]) + c[2] * c[2];
        if (disc > 0) {
          const s = Math.sqrt(disc);
          if (-hn + s > 0) { ivA[m] = -hn - s; ivB[m] = -hn + s; m++; }
        }
      }
      // Menor t >= 0 fuera de todos los intervalos abiertos (a, b): se
      // avanza hasta el final de cada intervalo que contiene a t.
      let cur = 0, cambio = true;
      while (cambio) {
        cambio = false;
        for (let j = 0; j < m; j++) {
          const a = ivA[j], b = ivB[j];
          if (b > cur && (a < cur - 1e-12 || (cur === 0 && a <= 0))) { cur = b; cambio = true; }
        }
      }
      const t = cur > 0 ? cur + 1e-4 : 0;
      let c = t * PESO_PSI[ip];
      const psi = 2 * Math.PI * ip / N_PSI;
      if (psiPrev !== null && psiPrev !== undefined) {
        c *= 1 + KAPPA * (1 - Math.cos(psi - psiPrev)) / 2;
      }
      if (mejor === null || c < mejor.c) mejor = {c, psi, t, nx, nz};
    }
    return {tx: mejor.nx * mejor.t, tz: mejor.nz * mejor.t, psi: mejor.psi, t: mejor.t};
  }

  // es: [entradaIzq, entradaDer] (mismo formato que SeparadorCuerpo.resolver);
  // previos: [giroIzq, giroDer] o null; prevPar: {psi, sh: [[x,y,z],[x,y,z]]}
  // del cuadro anterior (reciente) o null.
  // Devuelve {res: [resIzq, resDer], sh, psi, limitado, pases}. Cada res es
  // la salida de SeparadorCuerpo.resolver mas `desplazado` (true si la
  // muñeca se corrio por la otra mano): res.delta es el objetivo final.
  function resolverPar(es, previos, prevPar) {
    const arriba = es[0].arriba, fre = es[0].frente;
    let der = cruz(arriba, fre);
    const ld = largo(der);
    der = [der[0] / ld, der[1] / ld, der[2] / ld];
    const k = es[0].marco.escala;
    const margen = MARGEN * k, tol = TOL * k, maxD = MAX_DESPL * k, tasa = TASA * k;
    const base0 = es.map((e) => {
      const r0 = largo(e.delta);
      const rr0 = Math.min(e.radioMax, Math.max(e.radioMin, r0));
      const f = rr0 / Math.max(r0, 1e-9);
      return [e.delta[0] * f, e.delta[1] * f, e.delta[2] * f];
    });
    const sh = [[0, 0, 0], [0, 0, 0]];
    const w = [0.5, 0.5];
    const bloq = [false, false];
    const res = [null, null], P = [null, null];
    const correr = (l) => {
      const e = es[l];
      let d = e.delta;
      if (hayDespl(sh[l])) d = topeHorizontal(suma(base0[l], sh[l]), arriba, e.radioMax, e.radioMin);
      const ee = Object.assign({}, e, {delta: d});
      res[l] = SeparadorCuerpo.resolver(ee, previos ? previos[l] : null);
      P[l] = puntos(ee, res[l], k);
    };
    correr(0); correr(1);
    let psi = prevPar ? prevPar.psi : null;
    let pases = 0;
    for (let it = 0; it < PASES; it++) {
      const A = P[0].mano.concat(P[0].ant), B = P[1].mano.concat(P[1].ant);
      if (penetracion(A, B, margen) <= tol) break;
      const cons = restricciones(A, B, arriba, der, fre, margen, LEJOS * k);
      const T = mejorT(cons, psi);
      if (T.t <= 1e-6) break;
      psi = T.psi; pases++;
      // T = traslacion de la izquierda respecto a la derecha. Costado:
      // repartido. Profundidad: se adelanta la mano que queda delante.
      let pl = [der[0] * w[0] * T.tx, der[1] * w[0] * T.tx, der[2] * w[0] * T.tx];
      let pr = [-der[0] * w[1] * T.tx, -der[1] * w[1] * T.tx, -der[2] * w[1] * T.tx];
      if (T.tz >= 0) {
        if (!bloq[0]) pl = suma(pl, fre, T.tz); else pr = suma(pr, fre, -T.tz);
      } else {
        if (!bloq[1]) pr = suma(pr, fre, -T.tz); else pl = suma(pl, fre, T.tz);
      }
      sh[0] = suma(sh[0], pl); sh[1] = suma(sh[1], pr);
      for (let l = 0; l < 2; l++) {
        const n = largo(sh[l]);
        if (n > maxD) sh[l] = sh[l].map((v) => v * maxD / n);
      }
      const wr0 = [P[0].muneca, P[1].muneca];
      correr(0); correr(1);
      [pl, pr].forEach((pedido, l) => {
        let dw = suma(P[l].muneca, wr0[l], -1);
        dw = suma(dw, arriba, -dot(dw, arriba));
        const plan = largo(pedido);
        if (plan > 1e-4) {
          const logro = dot(dw, pedido) / plan / plan;
          if (logro < 0.6) { bloq[l] = true; w[l] = Math.max(0.1, w[l] * 0.4); }
        }
      });
      const s = w[0] + w[1]; w[0] /= s; w[1] /= s;
      // Si ninguna muñeca avanzo (las dos topadas), no hay mas que hacer.
      if (Math.max(largo(suma(P[0].muneca, wr0[0], -1)),
        largo(suma(P[1].muneca, wr0[1], -1))) < 1e-4 * k) break;
    }
    let limitado = false;
    if (prevPar && prevPar.sh) {
      for (let l = 0; l < 2; l++) {
        const d = suma(sh[l], prevPar.sh[l], -1);
        const n = largo(d);
        if (n > tasa) { sh[l] = suma(prevPar.sh[l], d, tasa / n); limitado = true; }
      }
      if (limitado) { correr(0); correr(1); }
    }
    res[0].desplazado = hayDespl(sh[0]);
    res[1].desplazado = hayDespl(sh[1]);
    return {res, sh, psi, limitado, pases};
  }

  return Object.freeze({resolverPar, mejorT, restricciones, topeHorizontal,
    MAX_DESPL, TASA});
})();

// ---------------------------------------------------------------------
// Flexion de los dedos largos CON SIGNO (2026-10-28).
//
// El visor medía cada falange como el angulo SIN signo entre dos
// segmentos. Eso sumaba como "doblez hacia la palma" dos cosas que no lo
// son: la abertura lateral de los dedos (el indice sale ~20° de la linea
// del metacarpo) y la hiperextension (la punta que el detector deja un poco
// hacia atras). Con la palma hacia la camara, los dedos que en el video van
// derechos quedaban apuntando hacia quien mira. Medido en las 541 señas: la
// articulacion de la punta salia 6-17° doblada de mas y el nudillo del
// indice ~10°.
//
// Ahora la flexion es la componente del giro sobre la normal de la palma:
// positiva hacia la palma, la abertura lateral no cuenta y lo que va hacia
// atras se queda en 0 (recto). La normal sale de la quiralidad de cada mano
// (sign_norm: x,y de imagen sin espejo, z de MediaPipe): derecha =
// indice x meñique, izquierda = al reves. Si una toma viene espejada la
// quiralidad se invierte; se detecta porque nudillos y falanges medias
// quedarian casi todos "hacia atras", y entonces se usa la normal opuesta.
// Devuelve [[mcp, pip, dip] x indice, medio, anular, meñique] en radianes,
// o null si la mano es degenerada.
// ---------------------------------------------------------------------
export function flexionesConSigno(puntos, lado) {
  if (!Array.isArray(puntos) || puntos.length < 20) return null;
  const resta = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
  const pto = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  const largo = (a) => Math.sqrt(pto(a, a));
  const cruz = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2],
    a[0] * b[1] - a[1] * b[0]];
  for (const p of puntos) {
    if (!Array.isArray(p) || p.length < 3 || !p.every(Number.isFinite)) return null;
  }
  let n = cruz(puntos[4], puntos[16]);
  if (lado === 'left') n = n.map((x) => -x);
  const ln = largo(n);
  if (!(ln > 1e-9)) return null;
  n = n.map((x) => x / ln);
  const dedos = [[4, 5, 6, 7], [8, 9, 10, 11], [12, 13, 14, 15], [16, 17, 18, 19]];
  const medir = (normal) => {
    const out = [];
    for (const idx of dedos) {
      const pts = [[0, 0, 0], ...idx.map((i) => puntos[i])];
      const seg = [];
      for (let k = 0; k < 4; k++) seg.push(resta(pts[k + 1], pts[k]));
      if (seg.some((s) => !(largo(s) > 1e-9))) return null;
      const f = [];
      for (let k = 0; k < 3; k++) {
        const la = largo(seg[k]);
        const a = seg[k].map((x) => x / la);
        const b = seg[k + 1];
        // normal de la palma sin la parte paralela al segmento anterior
        const d = pto(normal, a);
        let np = normal.map((x, c) => x - d * a[c]);
        const lnp = largo(np);
        if (!(lnp > 1e-9)) return null;
        np = np.map((x) => x / lnp);
        f.push(Math.atan2(pto(b, np), pto(b, a)));
      }
      out.push(f);
    }
    return out;
  };
  let f = medir(n);
  if (!f) return null;
  // Quiralidad: nudillos + falanges medias casi todos hacia atras = toma
  // espejada (una mano real no se hiperextiende asi en los cuatro dedos).
  const suma = f.reduce((s, d) => s + d[0] + d[1], 0);
  if (suma < -0.6) {
    const g = medir(n.map((x) => -x));
    if (g) f = g;
  }
  return f.map((d) => d.map((x) => Math.max(0, x)));
}
