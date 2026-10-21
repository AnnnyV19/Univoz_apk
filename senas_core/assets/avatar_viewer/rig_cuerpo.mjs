// Separador de cuerpo (aportado por la rama app-limpia, 2026-10-13). Modulo
// puro: sin THREE ni DOM. Vive aqui (fuente de verdad) y se inlinea en
// index.html con tools/inline_viewer_modules.py. La TABLA del torso se midio
// en la malla de MODELO_UNIVOZ_v0.vrm: con otro modelo hay que regenerarla
// (univoz/herramientas/cuerpo/simulacion/tabla_torso.py).

// ---------------------------------------------------------------------
// Separador de cuerpo: que las manos y los antebrazos del avatar no
// atraviesen su propio torso.
//
// Por que pasa: las plantillas guardan la muñeca en "anchos de hombro"
// medidos en una persona real; la mano de quien firma queda ~0.6 anchos
// delante de los hombros (el pecho de una persona delgada). El torso de
// este avatar (VRoid, con ropa) llega a ~0.67 anchos delante del plano
// de los hombros, asi que la IK dejaba la muñeca, la palma y el codo
// DENTRO del pecho.
//
// Que hace (matematica pura, sin THREE, probada en Node):
//  1. EMPUJE: si la mano o la muñeca quedan dentro del torso, el objetivo
//     de la muñeca se corre hacia ADELANTE (eje horizontal del avatar) lo
//     justo para salir. Nunca cambia la altura: el desplazamiento es
//     horizontal y se limita para que la IK no tenga que recortar el
//     alcance (si lo recortara, la muñeca cambiaria de altura).
//  2. GIRO DEL CODO: el codo gira alrededor del eje hombro-muñeca (±90°,
//     pasos de 10°) hasta que codo y antebrazo salen del torso, con el
//     menor giro posible. No mueve la muñeca ni la mano.
//  El torso se aproxima por una tabla de cortes medida en la malla del
//  modelo (superelipse N=2.4 por altura); se escala con el ancho de
//  hombros del avatar y sigue la inclinacion del pecho.
// ---------------------------------------------------------------------
export const SeparadorCuerpo = (() => {
  // Ancho de hombros (m) del modelo con el que se midio la tabla.
  const ANCHO_REF = 0.2171117844;
  // [altura respecto a los hombros, semiancho, frente, espalda] en
  // metros del modelo de referencia. frente/espalda: distancia hacia
  // delante (+) o atras (-) del plano de los hombros.
  const TABLA = [
    [-0.44975, 0.03959, 0.12749, -0.06461],
    [-0.40975, 0.10216, 0.13767, -0.07384],
    [-0.36975, 0.14139, 0.14769, -0.07623],
    [-0.32975, 0.14360, 0.14929, -0.07325],
    [-0.28975, 0.14154, 0.15114, -0.07024],
    [-0.24975, 0.12474, 0.14455, -0.05285],
    [-0.20975, 0.11377, 0.14352, -0.03949],
    [-0.16975, 0.11194, 0.14599, -0.02193],
    [-0.12975, 0.11715, 0.14581, -0.02410],
    [-0.08975, 0.13830, 0.14622, -0.04259],
    [-0.04975, 0.14151, 0.13412, -0.05232],
    [-0.00975, 0.11926, 0.10004, -0.05647],
    [0.03025, 0.05898, 0.06941, -0.05298],
    [0.07025, 0.05170, 0.04617, -0.04899],
  ];
  const V0 = TABLA[0][0];
  const V1 = TABLA[TABLA.length - 1][0];
  const EXPONENTE = 2.4;
  const MARGEN = 0.004;
  const BANDA_U = 0.03;
  const BANDA_V = 0.04;
  const TOLERANCIA = 0.0015;
  const MAX_EMPUJE = 0.20;
  const TASA_GIRO = 12 * Math.PI / 180;
  const GIROS = [];
  for (let g = -90; g <= 90; g += 10) GIROS.push(g * Math.PI / 180);
  const PASO_GIRO = 10 * Math.PI / 180;
  const MAX_GIRO = 90 * Math.PI / 180;
  // Radios (m, modelo de referencia) de lo que se prueba contra el torso.
  const RADIO_MUNECA = 0.028;
  const RADIOS_DEDO = [];
  for (let i = 0; i < 20; i++) {
    RADIOS_DEDO.push(i % 4 === 0 ? 0.022 : (i % 4 === 3 ? 0.004 : 0.009));
  }

  const suave = (x) => {
    const t = x < 0 ? 0 : (x > 1 ? 1 : x);
    return t * t * (3 - 2 * t);
  };
  const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  const cruz = (a, b) => [a[1] * b[2] - a[2] * b[1],
    a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
  const suma = (a, b, s = 1) => [a[0] + b[0] * s, a[1] + b[1] * s, a[2] + b[2] * s];
  const largo = (a) => Math.sqrt(dot(a, a));

  function fila(v) {
    let i = 0;
    while (i < TABLA.length - 2 && v > TABLA[i + 1][0]) i++;
    const a = TABLA[i], b = TABLA[i + 1];
    const t = (v - a[0]) / (b[0] - a[0]);
    return [a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t,
      a[3] + (b[3] - a[3]) * t];
  }

  // Cuanto hay que adelantar (m del modelo de referencia) una esfera de
  // radio r en q = (derecha, arriba, adelante) para que salga del torso.
  function necesidad(q, r) {
    const u = q[0], v = q[1], w = q[2];
    if (!(v > V0 && v < V1)) return 0;
    const [a, wf, wb] = fila(v);
    const R = r + MARGEN;
    const A = a + R;
    const B = (wf - wb) / 2 + R;
    const wc = (wf + wb) / 2;
    const au = Math.abs(u);
    if (au >= A) return 0;
    const t = w - (wc - 0.5 * B);
    if (t <= 0) return 0;
    const wSuperficie = wc + B * Math.pow(1 - Math.pow(au / A, EXPONENTE), 1 / EXPONENTE);
    const n = wSuperficie - w;
    if (n <= 0) return 0;
    const g = suave((A - au) / BANDA_U) * suave((v - V0) / BANDA_V) *
      suave((V1 - v) / BANDA_V) * suave(t / (0.5 * B));
    return n * g;
  }

  // IK de dos huesos (misma que resolverBrazo) con giro del codo.
  function ik(e, delta, giro) {
    const r = largo(delta);
    const rr = Math.min(e.radioMax, Math.max(e.radioMin, r));
    const d = r > 1e-9 ? [delta[0] / r, delta[1] / r, delta[2] / r] : [0, 0, 1];
    const muneca = suma(e.hombro, d, rr);
    const quitar = (p) => suma(p, d, -dot(p, d));
    let pl = quitar(e.codoDeseado);
    if (dot(pl, pl) < 1e-8) pl = quitar(e.dirUp);
    if (dot(pl, pl) < 1e-8) pl = [0, 1, 0];
    pl = quitar(pl);
    const lp = largo(pl);
    pl = [pl[0] / lp, pl[1] / lp, pl[2] / lp];
    if (giro !== 0) {
      const c = Math.cos(giro), s = Math.sin(giro);
      const x = cruz(d, pl);
      pl = [pl[0] * c + x[0] * s, pl[1] * c + x[1] * s, pl[2] * c + x[2] * s];
    }
    const avance = (e.lenUp * e.lenUp - e.lenLo * e.lenLo + rr * rr) / (2 * rr);
    const altura = Math.sqrt(Math.max(0, e.lenUp * e.lenUp - avance * avance));
    const codo = suma(suma(e.hombro, d, avance), pl, altura);
    return {codo, muneca};
  }

  // e: {hombro, delta, codoDeseado, dirUp, lenUp, lenLo, radioMin,
  //     radioMax, frente, arriba, mano: 20 desplazamientos desde la muñeca (o
  //     null), marco: {T (12, filas de [R|t]), origen, der, arr, fre,
  //     escala}} -- todo en el mismo sistema de coordenadas del mundo.
  // previo: giro (rad) del cuadro anterior o null. Devuelve
  // {empuje, giro, giroObjetivo, costo, iter}.
  function resolver(e, previo = null) {
    const m = e.marco, T = m.T, k = m.escala;
    const aCuerpo = (p) => {
      const x = T[0] * p[0] + T[1] * p[1] + T[2] * p[2] + T[3] - m.origen[0];
      const y = T[4] * p[0] + T[5] * p[1] + T[6] * p[2] + T[7] - m.origen[1];
      const z = T[8] * p[0] + T[9] * p[1] + T[10] * p[2] + T[11] - m.origen[2];
      const c = [x, y, z];
      return [dot(c, m.der) / k, dot(c, m.arr) / k, dot(c, m.fre) / k];
    };
    const nec = (p, r) => necesidad(aCuerpo(p), r) * k;
    // El objetivo ya recortado por el alcance del brazo (lo que haria la
    // IK sola). El empuje se aplica sobre eso y NUNCA toca su altura:
    // si adelantar la muñeca excede el alcance, se gira el brazo en
    // horizontal (misma altura, mismo alcance) en vez de recortarlo.
    const r0 = largo(e.delta);
    const rr0 = Math.min(e.radioMax, Math.max(e.radioMin, r0));
    const base = r0 > 1e-9 ? [e.delta[0] * rr0 / r0, e.delta[1] * rr0 / r0,
      e.delta[2] * rr0 / r0] : [0, 0, 0];
    const yb = dot(base, e.arriba);
    const rTope = e.radioMax - 1e-3;
    const H2 = rTope * rTope - yb * yb;
    const hb = suma(base, e.arriba, -yb);
    const maxS = H2 <= 0 ? 0 : MAX_EMPUJE;
    const objetivo = (S) => {
      if (S <= 0) return e.delta;
      let hn = suma(hb, e.frente, S);
      const n = largo(hn);
      const H = Math.sqrt(H2);
      if (n > H) hn = [hn[0] * H / n, hn[1] * H / n, hn[2] * H / n];
      return suma(hn, e.arriba, yb);
    };
    let S = 0, giro = 0, costo = 0, it = 0;
    for (it = 0; it < 10; it++) {
      const d = objetivo(S);
      let sol = ik(e, d, 0);
      let necMano = nec(sol.muneca, RADIO_MUNECA);
      if (e.mano) {
        for (let i = 0; i < 20; i++) {
          necMano = Math.max(necMano,
            nec(suma(sol.muneca, e.mano[i]), RADIOS_DEDO[i]));
        }
      }
      if (necMano > TOLERANCIA) {
        if (S >= maxS - 1e-9) break;
        S = Math.min(maxS, S + necMano);
        continue;
      }
      let mejor = null;
      for (const th of GIROS) {
        sol = ik(e, d, th);
        const arm = [[sol.codo, 0.038]];
        for (const t of [0.2, 0.4, 0.6, 0.8]) {
          arm.push([suma(sol.codo, suma(sol.muneca, sol.codo, -1), t), 0.04 - 0.01 * t]);
        }
        let c = 0;
        for (const [p, r] of arm) c = Math.max(c, nec(p, r));
        const j = c * 50 + Math.abs(th) * 0.01;
        if (mejor === null || j < mejor.j) mejor = {j, th, c};
      }
      // Refina el giro (seccion aurea alrededor del mejor de la rejilla)
      // para que el codo se mueva continuo y no a saltos de 10 grados.
      const jGiro = (th) => {
        const s2 = ik(e, d, th);
        const ar = [[s2.codo, 0.038]];
        for (const t of [0.2, 0.4, 0.6, 0.8]) {
          ar.push([suma(s2.codo, suma(s2.muneca, s2.codo, -1), t), 0.04 - 0.01 * t]);
        }
        let c2 = 0;
        for (const [p, r] of ar) c2 = Math.max(c2, nec(p, r));
        return {j: c2 * 50 + Math.abs(th) * 0.01, th, c: c2};
      };
      let a2 = Math.max(-MAX_GIRO, mejor.th - PASO_GIRO);
      let b2 = Math.min(MAX_GIRO, mejor.th + PASO_GIRO);
      const gr = (Math.sqrt(5) - 1) / 2;
      let x1 = b2 - gr * (b2 - a2), x2 = a2 + gr * (b2 - a2);
      let f1 = jGiro(x1), f2 = jGiro(x2);
      for (let n = 0; n < 8; n++) {
        if (f1.j < f2.j) {
          b2 = x2; x2 = x1; f2 = f1; x1 = b2 - gr * (b2 - a2); f1 = jGiro(x1);
        } else {
          a2 = x1; x1 = x2; f1 = f2; x2 = a2 + gr * (b2 - a2); f2 = jGiro(x2);
        }
      }
      const fr = jGiro((a2 + b2) / 2);
      if (fr.j < mejor.j) mejor = fr;
      giro = mejor.th;
      costo = mejor.c;
      if (mejor.c < TOLERANCIA) break;
      if (S >= maxS - 1e-9) break;
      S = Math.min(maxS, S + Math.max(0.005, mejor.c * 0.5));
    }
    const giroObjetivo = giro;
    if (previo !== null && Number.isFinite(previo)) {
      giro = previo + Math.max(-TASA_GIRO, Math.min(TASA_GIRO, giro - previo));
    }
    return {empuje: S, delta: objetivo(S), giro, giroObjetivo, costo, iter: it};
  }

  return Object.freeze({resolver, necesidad, ik, ANCHO_REF, TABLA, GIROS});
})();
