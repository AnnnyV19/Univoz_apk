// Reproduccion estable de secuencias (aportado por la rama app-limpia,
// 2026-10-14): relleno de huecos de mano, suavizado gaussiano que se apaga
// con el movimiento rapido, interpolacion entre cuadros y el extra de encuadre
// por la mano mas baja. Puro (sin THREE ni DOM).
//
// Layout del vector 2.0.0 (152 dims), igual que lib/sign_norm.dart.
const kOffBody = 0, kOffLocL = 24, kOffLocR = 27, kOffPresL = 30,
  kOffPresR = 31, kOffShapeL = 32, kOffShapeR = 92, kFrameDim = 152;

const kManosRep = [
  {loc: kOffLocL, pres: kOffPresL, shape: kOffShapeL},
  {loc: kOffLocR, pres: kOffPresR, shape: kOffShapeR},
];
const kSuavSigma = 1.3;
const kSuavRadio = 3;
// Velocidad (unidades por cuadro) por debajo de la cual el suavizado es
// total (v0) y por encima de la cual no se aplica (v1).
const kSuavUmbrales = {
  cuerpo: [0.02, 0.08],
  muneca: [0.04, 0.14],
  forma: [0.06, 0.25],
};
const kSuavNucleo = (() => {
  const k = [];
  let suma = 0;
  for (let i = -kSuavRadio; i <= kSuavRadio; i++) {
    const w = Math.exp(-0.5 * (i / kSuavSigma) ** 2);
    k.push(w);
    suma += w;
  }
  return k.map((w) => w / suma);
})();

function _rachas(marca) {
  const out = [];
  let i = 0;
  while (i < marca.length) {
    if (marca[i]) {
      let j = i;
      while (j < marca.length && marca[j]) j++;
      out.push([i, j]);
      i = j;
    } else {
      i++;
    }
  }
  return out;
}

// Rellena por interpolacion lineal los cuadros SIN mano que quedan entre
// la primera y la ultima deteccion de esa mano. Lo de antes de la primera
// y despues de la ultima no se toca: ahi la mano de verdad no esta.
function _rellenarHuecos(F) {
  for (const m of kManosRep) {
    let a = -1;
    let b = -1;
    for (let t = 0; t < F.length; t++) {
      if (F[t][m.pres] >= 0.5) {
        if (a < 0) a = t;
        b = t;
      }
    }
    if (a < 0 || a === b) continue;
    let t = a;
    while (t <= b) {
      if (F[t][m.pres] >= 0.5) { t++; continue; }
      const t0 = t - 1;
      let t1 = t;
      while (F[t1][m.pres] < 0.5) t1++;
      for (let u = t0 + 1; u < t1; u++) {
        const w = (u - t0) / (t1 - t0);
        for (let c = 0; c < 3; c++) {
          F[u][m.loc + c] = F[t0][m.loc + c] * (1 - w) + F[t1][m.loc + c] * w;
        }
        for (let c = 0; c < 60; c++) {
          F[u][m.shape + c] = F[t0][m.shape + c] * (1 - w) + F[t1][m.shape + c] * w;
        }
        F[u][m.pres] = 1.0;
      }
      t = t1;
    }
  }
}

function _suaveParaVelocidad(v0, v1, v) {
  const t = Math.min(1, Math.max(0, (v - v0) / (v1 - v0)));
  return t * t * (3 - 2 * t);
}

// Suaviza F[a..b) en las columnas c0..c0+n-1. Cada cuadro mezcla el dato
// crudo con su version gaussiana segun la velocidad local.
function _suavizarTramo(F, a, b, c0, n, grupo, factor) {
  const largo = b - a;
  if (largo < 1) return;
  const x = [];
  for (let t = a; t < b; t++) x.push(F[t].slice(c0, c0 + n));
  const d = [];
  for (let i = 0; i < largo - 1; i++) {
    let s = 0;
    for (let k = 0; k < n; k++) {
      const q = x[i + 1][k] - x[i][k];
      s += q * q;
    }
    d.push(Math.sqrt(s));
  }
  const [v0, v1] = kSuavUmbrales[grupo];
  for (let i = 0; i < largo; i++) {
    let v = 0;
    if (largo > 1) {
      if (i === 0) v = d[0];
      else if (i === largo - 1) v = d[largo - 2];
      else v = 0.5 * (d[i - 1] + d[i]);
    }
    const w = 1 - _suaveParaVelocidad(v0, v1, v / factor);
    if (w <= 0) continue;
    for (let k = 0; k < n; k++) {
      let acc = 0;
      for (let j = -kSuavRadio; j <= kSuavRadio; j++) {
        const idx = Math.min(largo - 1, Math.max(0, i + j));
        acc += kSuavNucleo[j + kSuavRadio] * x[idx][k];
      }
      F[a + i][c0 + k] = x[i][k] + w * (acc - x[i][k]);
    }
  }
}

// Devuelve una COPIA lista para reproducir: huecos rellenos y temblor
// quitado. No toca la secuencia original ni lo que usa el reconocimiento.
export function prepararSecuencia(frames) {
  const F = frames.map((f) => f.slice());
  _rellenarHuecos(F);
  for (const m of kManosRep) {
    const presente = F.map((f) => f[m.pres] >= 0.5);
    for (const [a, b] of _rachas(presente)) {
      _suavizarTramo(F, a, b, m.loc, 3, 'muneca', 1);
      _suavizarTramo(F, a, b, m.shape, 60, 'forma', Math.sqrt(20));
    }
  }
  for (let p = 0; p < 8; p++) {
    const c0 = kOffBody + p * 3;
    const tiene = F.map((f) => Math.hypot(f[c0], f[c0 + 1], f[c0 + 2]) > 1e-6);
    for (const [a, b] of _rachas(tiene)) {
      _suavizarTramo(F, a, b, c0, 3, 'cuerpo', 1);
    }
  }
  return F;
}

// Cuadro intermedio en la posicion fraccionaria `pos` (0 = primer cuadro).
// Solo mezcla lo que existe en los dos cuadros vecinos; si un punto o una
// mano falta en uno de los dos, toma el del mas cercano (no inventa un
// punto entre "hay mano" y "no hay mano").
export function interpolarFrame(F, pos, salida) {
  const n = F.length;
  const p = Math.min(Math.max(pos, 0), n - 1);
  const i0 = Math.floor(p);
  const i1 = Math.min(n - 1, i0 + 1);
  const f = p - i0;
  const A = F[i0];
  const B = F[i1];
  if (i0 === i1 || f === 0) {
    for (let k = 0; k < kFrameDim; k++) salida[k] = A[k];
    return salida;
  }
  const cerca = f < 0.5 ? A : B;
  for (let pt = 0; pt < 8; pt++) {
    const c = kOffBody + pt * 3;
    const ambos = Math.hypot(A[c], A[c + 1], A[c + 2]) > 1e-6 &&
      Math.hypot(B[c], B[c + 1], B[c + 2]) > 1e-6;
    for (let k = 0; k < 3; k++) {
      salida[c + k] = ambos ? A[c + k] + (B[c + k] - A[c + k]) * f : cerca[c + k];
    }
  }
  for (const m of kManosRep) {
    const ambas = A[m.pres] >= 0.5 && B[m.pres] >= 0.5;
    if (ambas) {
      for (let k = 0; k < 3; k++) {
        salida[m.loc + k] = A[m.loc + k] + (B[m.loc + k] - A[m.loc + k]) * f;
      }
      for (let k = 0; k < 60; k++) {
        salida[m.shape + k] = A[m.shape + k] + (B[m.shape + k] - A[m.shape + k]) * f;
      }
      salida[m.pres] = 1;
    } else {
      for (let k = 0; k < 3; k++) salida[m.loc + k] = cerca[m.loc + k];
      for (let k = 0; k < 60; k++) salida[m.shape + k] = cerca[m.shape + k];
      salida[m.pres] = cerca[m.pres];
    }
  }
  return salida;
}

// Cuanto hay que bajar el borde de abajo del encuadre "codos" (en unidades
// del mundo) para que la mano mas baja de la secuencia siga a la vista.
//   m = {hombroY, brazo} a escala 1; anchoHombros ya viene en unidades de
//   mundo (es como se mide el avatar al cargarlo).
export function extraEncuadreAbajo(frames, m, escala, reposo, anchoHombros) {
  if (!m || !Array.isArray(frames) || !(anchoHombros > 0)) return 0;
  let yMin = Infinity;
  for (const f of frames) {
    if (f[kOffPresL] >= 0.5) yMin = Math.min(yMin, f[kOffLocL + 1]);
    if (f[kOffPresR] >= 0.5) yMin = Math.min(yMin, f[kOffLocR + 1]);
  }
  if (!Number.isFinite(yMin)) return 0;
  const munecaY = m.hombroY * escala + yMin * anchoHombros;
  const codoY = (m.hombroY - m.brazo * Math.sin(reposo)) * escala;
  const abajoBase = codoY - 0.03 * escala;
  const mano = 0.4 * m.brazo * escala; // lo que cuelga la mano bajo la muñeca
  const extra = abajoBase - (munecaY - mano);
  // Por debajo de ~4.5 cm la mano apenas se corta: no vale mover la camara.
  if (!(extra > 0.045 * escala)) return 0;
  return Math.min(extra, m.brazo * escala);
}
