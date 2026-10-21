// ManoIK: direccion 3D de cada falange (aportado por la rama app-limpia,
// 2026-10-14). Puro (arreglos y matrices 3x3). NO esta conectado al rig de
// este visor: ver docs/17-integracion-app-limpia.md.

// ---------------------------------------------------------------------
// Dedos en 3D (ManoIK).
//
// Antes cada falange solo sabia FLEXIONARSE (un angulo, alrededor de Z). Con
// eso ni la R (indice y medio cruzados) ni la O (circulo pulgar-indice)
// podian salir: los dedos nunca se acercaban ni se separaban de lado y el
// pulgar solo iba de "abierto" a "cerrado".
//
// Aqui el avatar copia la DIRECCION 3D de cada falange tal como la ve la
// camara, medida en el marco de la propia mano:
//   - dedos largos: cada falange tiene flexion (eje Z) y separacion lateral
//     (eje Y), con el orden Rz(flexion)·Ry(separacion) que es el de la
//     anatomia del nudillo: primero se abre de lado, luego se dobla.
//   - pulgar: cada hueso gira lo minimo para apuntar donde apunta el pulgar
//     del usuario, y un ajuste numerico lleva la punta del pulgar a la punta
//     del dedo que toca (OK, O, F...), porque los dedos del avatar no miden lo
//     mismo que los del usuario y copiar solo angulos dejaba un hueco.
//
// Todo trabaja con arreglos [x,y,z] y matrices 3x3 planas (fila mayor), sin
// THREE, para poder probarlo en Node con las plantillas reales.
// ---------------------------------------------------------------------
export const ManoIK = (() => {
  const clamp = (x, lo, hi) => Math.max(lo, Math.min(hi, x));
  const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
  const add = (a, b) => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
  const mul = (a, s) => [a[0] * s, a[1] * s, a[2] * s];
  const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  const cross = (a, b) => [a[1] * b[2] - a[2] * b[1],
    a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
  const largo = (a) => Math.sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);
  const unit = (a) => {
    const l = largo(a);
    return l > 1e-9 ? [a[0] / l, a[1] / l, a[2] / l] : null;
  };
  const finito = (a) => a.every(Number.isFinite);
  const envolver = (x) => {
    while (x > Math.PI) x -= 2 * Math.PI;
    while (x < -Math.PI) x += 2 * Math.PI;
    return x;
  };

  // Matrices 3x3 planas, fila mayor: [m00,m01,m02, m10,m11,m12, m20,m21,m22]
  const I3 = () => [1, 0, 0, 0, 1, 0, 0, 0, 1];
  const mm = (A, B) => {
    const R = new Array(9);
    for (let i = 0; i < 3; i++) {
      for (let j = 0; j < 3; j++) {
        R[i * 3 + j] = A[i * 3] * B[j] + A[i * 3 + 1] * B[3 + j] +
          A[i * 3 + 2] * B[6 + j];
      }
    }
    return R;
  };
  const mv = (A, x) => [
    A[0] * x[0] + A[1] * x[1] + A[2] * x[2],
    A[3] * x[0] + A[4] * x[1] + A[5] * x[2],
    A[6] * x[0] + A[7] * x[1] + A[8] * x[2]];
  const tr = (A) => [A[0], A[3], A[6], A[1], A[4], A[7], A[2], A[5], A[8]];
  const rotZ = (f) => {
    const c = Math.cos(f), s = Math.sin(f);
    return [c, -s, 0, s, c, 0, 0, 0, 1];
  };
  const rotY = (a) => {
    const c = Math.cos(a), s = Math.sin(a);
    return [c, 0, s, 0, 1, 0, -s, 0, c];
  };
  // Rotacion alrededor de un eje unitario (Rodrigues)
  const rotEje = (e, ang) => {
    const c = Math.cos(ang), s = Math.sin(ang), t = 1 - c;
    const [x, y, z] = e;
    return [t * x * x + c, t * x * y - s * z, t * x * z + s * y,
      t * x * y + s * z, t * y * y + c, t * y * z - s * x,
      t * x * z - s * y, t * y * z + s * x, t * z * z + c];
  };
  // Giro minimo que lleva la direccion unitaria a hacia b
  const giroMinimo = (a, b) => {
    const c = clamp(dot(a, b), -1, 1);
    let eje = cross(a, b);
    const s = largo(eje);
    if (s < 1e-9) {
      if (c > 0) return I3();
      // opuestos: cualquier eje perpendicular
      const p = Math.abs(a[0]) < 0.9 ? [1, 0, 0] : [0, 1, 0];
      return rotEje(unit(cross(a, p)), Math.PI);
    }
    eje = mul(eje, 1 / s);
    return rotEje(eje, Math.atan2(s, c));
  };
  // Matriz -> cuaternion [x,y,z,w]
  const aCuaternion = (R) => {
    const t = R[0] + R[4] + R[8];
    let x, y, z, w;
    if (t > 0) {
      const s = Math.sqrt(t + 1) * 2;
      w = 0.25 * s; x = (R[7] - R[5]) / s; y = (R[2] - R[6]) / s;
      z = (R[3] - R[1]) / s;
    } else if (R[0] > R[4] && R[0] > R[8]) {
      const s = Math.sqrt(1 + R[0] - R[4] - R[8]) * 2;
      w = (R[7] - R[5]) / s; x = 0.25 * s; y = (R[1] + R[3]) / s;
      z = (R[2] + R[6]) / s;
    } else if (R[4] > R[8]) {
      const s = Math.sqrt(1 + R[4] - R[0] - R[8]) * 2;
      w = (R[2] - R[6]) / s; x = (R[1] + R[3]) / s; y = 0.25 * s;
      z = (R[5] + R[7]) / s;
    } else {
      const s = Math.sqrt(1 + R[8] - R[0] - R[4]) * 2;
      w = (R[3] - R[1]) / s; x = (R[2] + R[6]) / s; y = (R[5] + R[7]) / s;
      z = 0.25 * s;
    }
    const n = Math.hypot(x, y, z, w) || 1;
    return [x / n, y / n, z / n, w / n];
  };

  const kNombresLargos = ['Index', 'Middle', 'Ring', 'Little'];
  // Indices de los 4 landmarks de cada dedo dentro de los 20 de la mano
  const kIdx = {
    Thumb: [0, 1, 2, 3], Index: [4, 5, 6, 7], Middle: [8, 9, 10, 11],
    Ring: [12, 13, 14, 15], Little: [16, 17, 18, 19],
  };

  // Limites de flexion (positiva = hacia la palma) y de separacion lateral
  // por falange, en radianes. La extension hacia atras es corta en la vida
  // real (nudillo ~25 deg, interfalangicas casi nada). La separacion lateral
  // es amplia en el nudillo y minima mas adelante: ahi solo hace falta lo
  // justo para seguir la direccion que mide la camara.
  const kFlexMin = [-0.45, -0.12, -0.12];
  const kFlexMax = [1.75, 1.95, 1.60];
  const kSepMax = [0.50, 0.30, 0.25];

  /**
   * Modelo de una mano del avatar. `huesos` trae, por dedo, los
   * desplazamientos entre huesos consecutivos en el marco local de la mano
   * (metros): offs[0] = nudillo respecto a la muneca (en el pulgar, la base
   * del pulgar), offs[1] = segunda falange respecto a la primera, offs[2] =
   * tercera respecto a la segunda; `punta` = largo de la yema.
   * `signoFlex` = cal[lado].dedos (sentido de Rz que lleva el dedo a la
   * palma).
   */
  function crearModelo(lado, huesos, signoFlex) {
    const modelo = {
      lado, signoFlex: signoFlex < 0 ? -1 : 1, dedos: {}, palma: 0,
    };
    for (const nombre of Object.keys(kIdx)) {
      const h = huesos[nombre];
      if (!h) continue;
      const offs = h.offs.map((o) => o.slice());
      const r = [unit(offs[1]), unit(offs[2])];
      r.push(r[1]); // la yema sigue la direccion de la ultima falange
      // La direccion de reposo del primer hueso apunta hacia el siguiente
      // hueso (r[0] = hacia offs[1]).
      modelo.dedos[nombre] = {
        offs, r, punta: h.punta,
        largo: [largo(offs[1]), largo(offs[2]), h.punta],
      };
    }
    if (modelo.dedos.Middle) modelo.palma = largo(modelo.dedos.Middle.offs[0]);
    return modelo;
  }

  // Resuelve R = Rz(f)·Ry(a) tal que R·r = u, con |a| <= amax.
  function dosEjes(r, u, amax) {
    const A = Math.hypot(r[0], r[2]);
    let a = 0;
    if (A > 1e-6) {
      const delta = Math.atan2(r[0], r[2]);
      const ac = Math.acos(clamp(u[2] / A, -1, 1));
      const a1 = envolver(ac - delta), a2 = envolver(-ac - delta);
      a = Math.abs(a1) <= Math.abs(a2) ? a1 : a2;
    }
    a = clamp(a, -amax, amax);
    const w = mv(rotY(a), r);
    const f = envolver(Math.atan2(u[1], u[0]) - Math.atan2(w[1], w[0]));
    return {f, a};
  }

  /**
   * Cuatro dedos largos. `M` = 4 puntos [nudillo, PIP, DIP, punta] en el
   * marco local de la mano. Devuelve por falange {f, a, flex} (rotacion
   * Rz(f)·Ry(a); flex = flexion con signo anatomico, positiva hacia la
   * palma).
   *
   * Se resuelve primero la cadena exacta (cada hueso apunta justo a su
   * segmento) y despues se recorta cada articulacion POR SEPARADO. Recortar
   * mientras se resuelve haria que el error de un hueso se propagara a los
   * siguientes y un puño apretado deformaria las yemas.
   */
  function resolverDedoLargo(modelo, nombre, M, sensibilidad = 1) {
    const d = modelo.dedos[nombre];
    if (!d || !M || M.length < 4) return null;
    const t = [unit(sub(M[1], M[0])), unit(sub(M[2], M[1])),
      unit(sub(M[3], M[2]))];
    if (!t[0] || !t[1] || !t[2]) return null;
    const signo = modelo.signoFlex;
    let Q = I3();
    const out = [];
    for (let k = 0; k < 3; k++) {
      const u = mv(tr(Q), t[k]);
      const exacto = dosEjes(d.r[k], u, Math.PI / 2);
      Q = mm(Q, mm(rotZ(exacto.f), rotY(exacto.a)));
      // recorte de esta articulacion
      const lim = dosEjes(d.r[k], u, kSepMax[k]);
      const flex = clamp(signo * lim.f * sensibilidad, kFlexMin[k], kFlexMax[k]);
      out.push({f: signo * flex, a: lim.a, flex});
    }
    return out;
  }

  // Posiciones [MCP, PIP, DIP, punta] del dedo largo dadas sus rotaciones
  function fkDedoLargo(modelo, nombre, rots) {
    const d = modelo.dedos[nombre];
    let Q = I3();
    let p = d.offs[0].slice();
    const pts = [p];
    for (let k = 0; k < 3; k++) {
      Q = mm(Q, mm(rotZ(rots[k].f), rotY(rots[k].a)));
      const off = k < 2 ? d.offs[k + 1] : mul(d.r[2], d.punta);
      p = add(p, mv(Q, off));
      pts.push(p);
    }
    return pts;
  }

  // ------------------------------- Pulgar -------------------------------
  // Cada hueso: giro minimo (sin torsion) de su direccion de reposo hacia la
  // direccion objetivo, expresada en el marco del hueso padre. La torsion no
  // se puede medir con un solo segmento y la malla del pulgar es casi
  // cilindrica; lo que importa es hacia donde apunta cada hueso.

  function fkPulgar(modelo, giros) {
    const d = modelo.dedos.Thumb;
    // giros = [R0,R1,R2] locales (3x3). Devuelve {pts:[CMC,MCP,IP,punta], Q:[Q0,Q1,Q2]}
    let Q = I3();
    let p = d.offs[0].slice();
    const pts = [p];
    const Qs = [];
    for (let k = 0; k < 3; k++) {
      Q = mm(Q, giros[k]);
      Qs.push(Q);
      const off = k < 2 ? d.offs[k + 1] : mul(d.r[2], d.punta);
      p = add(p, mv(Q, off));
      pts.push(p);
    }
    return {pts, Q: Qs};
  }

  // Giros desde parametros (2 por hueso: componentes del vector de giro en
  // el plano perpendicular a la direccion de reposo del hueso).
  function baseTangente(r) {
    const p = Math.abs(r[0]) < 0.9 ? [1, 0, 0] : [0, 1, 0];
    const e1 = unit(cross(r, p));
    const e2 = cross(r, e1);
    return [e1, e2];
  }

  function girosDeParams(base, params) {
    return [0, 1, 2].map((k) => {
      const w = add(mul(base[k][0], params[2 * k]),
        mul(base[k][1], params[2 * k + 1]));
      const ang = largo(w);
      return ang < 1e-9 ? I3() : rotEje(mul(w, 1 / ang), ang);
    });
  }

  const kPulgarMaxGiro = [1.25, 1.45, 1.35];

  // Costo del ajuste del pulgar: direcciones de cada hueso + (opcional) la
  // punta hacia un blanco.
  function costoPulgar(modelo, base, params, dirs, blanco, pesoBlanco) {
    const giros = girosDeParams(base, params);
    const {pts, Q} = fkPulgar(modelo, giros);
    const d = modelo.dedos.Thumb;
    let c = 0;
    for (let k = 0; k < 3; k++) {
      const dir = mv(Q[k], d.r[k]);
      c += (1 - dot(dir, dirs[k]));
    }
    // blando: no pasarse del rango de cada hueso
    for (let k = 0; k < 3; k++) {
      const m = Math.hypot(params[2 * k], params[2 * k + 1]);
      if (m > kPulgarMaxGiro[k]) c += 20 * (m - kPulgarMaxGiro[k]) ** 2;
    }
    if (blanco && pesoBlanco > 0) {
      const e = sub(pts[3], blanco);
      c += pesoBlanco * dot(e, e) / (0.01 * 0.01);
    }
    return c;
  }

  function paramsDeDirecciones(modelo, base, dirs) {
    const d = modelo.dedos.Thumb;
    const params = new Array(6).fill(0);
    let Q = I3();
    for (let k = 0; k < 3; k++) {
      const u = unit(mv(tr(Q), dirs[k]));
      // vector de giro del giro minimo: eje·angulo, perpendicular a r[k]
      const eje = cross(d.r[k], u);
      const s = largo(eje);
      let ang = Math.atan2(s, clamp(dot(d.r[k], u), -1, 1));
      ang = Math.min(ang, kPulgarMaxGiro[k]);
      const w = s > 1e-9 ? mul(eje, ang / s) : [0, 0, 0];
      params[2 * k] = dot(w, base[k][0]);
      params[2 * k + 1] = dot(w, base[k][1]);
      // El padre acumulado ya incluye el limite: asi el hueso siguiente
      // compensa lo que el anterior no alcanzo.
      Q = mm(Q, ang < 1e-9 ? I3() : rotEje(mul(w, 1 / ang), ang));
    }
    return params;
  }

  /**
   * `P` = 20 puntos de la mano en el marco local (metros). `blanco`: punto
   * (marco local) al que debe llegar la punta del pulgar, con peso en [0,1].
   */
  function resolverPulgar(modelo, P, blanco, pesoBlanco, previo) {
    const d = modelo.dedos.Thumb;
    if (!d) return null;
    const q = kIdx.Thumb.map((i) => P[i]);
    const dirs = [unit(sub(q[1], q[0])), unit(sub(q[2], q[1])),
      unit(sub(q[3], q[2]))];
    if (!dirs[0] || !dirs[1] || !dirs[2]) return null;
    const base = d.r.map(baseTangente);
    let params = paramsDeDirecciones(modelo, base, dirs);
    const conBlanco = blanco && pesoBlanco > 0.02;
    if (conBlanco) {
      // Descenso con paso adaptativo (diferencias finitas). 6 incognitas.
      let c = costoPulgar(modelo, base, params, dirs, blanco, pesoBlanco);
      let paso = 0.25;
      for (let it = 0; it < 40 && paso > 1e-4; it++) {
        const g = new Array(6);
        const h = 1e-4;
        for (let i = 0; i < 6; i++) {
          const p2 = params.slice(); p2[i] += h;
          g[i] = (costoPulgar(modelo, base, p2, dirs, blanco, pesoBlanco) - c) / h;
        }
        const gn = Math.hypot(...g);
        if (gn < 1e-6) break;
        let mejoro = false;
        for (let ls = 0; ls < 6; ls++) {
          const p2 = params.map((v, i) => v - paso * g[i] / gn);
          const c2 = costoPulgar(modelo, base, p2, dirs, blanco, pesoBlanco);
          if (c2 < c) { params = p2; c = c2; mejoro = true; break; }
          paso *= 0.5;
        }
        if (!mejoro) break;
        paso = Math.min(0.25, paso * 1.6);
      }
    }
    const giros = girosDeParams(base, params);
    const fk = fkPulgar(modelo, giros);
    return {
      params, giros, quats: giros.map(aCuaternion), pts: fk.pts,
      contacto: conBlanco ? pesoBlanco : 0,
    };
  }


  // ------------------- Landmarks -> marco local de la mano -------------------
  // Mismo marco que usa orientarMuneca: X = muneca -> nudillo medio, Y =
  // (indice - menique) ortogonalizado, Z = X x Y, con el signo de Y fijado
  // por la base del pulgar. Se arma igual con los landmarks y con los huesos
  // del avatar en reposo; la mano se orienta con el delta entre ambos y los
  // dedos se expresan en el marco de reposo, de modo que forma y orientacion
  // quedan separadas.
  function marcoMano(x, y, cmc) {
    const ex = unit(x);
    if (!ex) return null;
    let ey = sub(y, mul(ex, dot(y, ex)));
    ey = unit(ey);
    if (!ey) return null;
    let ez = unit(cross(ex, ey));
    if (!ez) return null;
    if (cmc) {
      const c = unit(cmc);
      if (c && dot(c, ey) < 0) { ey = mul(ey, -1); ez = mul(ez, -1); }
    }
    return {x: ex, y: ey, z: ez};
  }

  /**
   * `w`: 20 puntos relativos a la muneca, en ejes del MUNDO del avatar
   * (sin normalizar). `ref`: marco de reposo {x,y,z} en el mundo.
   * `mundoALocal`: matriz 3x3 del mundo al marco local de la mano en
   * reposo. `palma`: distancia muneca-nudillo medio del avatar (m).
   * Devuelve los 20 puntos en el marco local de la mano, en metros del
   * avatar.
   */
  function aMarcoLocal(w, ref, mundoALocal, palma) {
    if (!w || w.length < 20) return null;
    const obj = marcoMano(w[8], sub(w[4], w[16]), w[0]);
    if (!obj) return null;
    const long = largo(w[8]);
    if (!(long > 1e-6)) return null;
    const esc = palma / long;
    return w.map((p) => {
      const a = dot(p, obj.x), b = dot(p, obj.y), c = dot(p, obj.z);
      const m = add(add(mul(ref.x, a), mul(ref.y, b)), mul(ref.z, c));
      return mul(mv(mundoALocal, m), esc);
    });
  }

  const smooth01 = (x) => {
    const t = clamp(x, 0, 1);
    return t * t * (3 - 2 * t);
  };

  // --------------------- Dedos que se cruzan (R, V cerrada) ---------------------
  // Con la direccion copiada, dos dedos que se cruzan quedan con el mismo eje
  // y las dos mallas se funden en un solo dedo. Los landmarks no distinguen
  // cual pasa por encima (la diferencia real es de un grosor de dedo, menos
  // que el error de la camara), asi que se separan lo justo girando cada dedo
  // desde el nudillo: mitad cada uno, en la direccion dorso/palma que dicta el
  // orden medido (con histeresis para que no cambien de capa por ruido).
  const kParesDedos = [['Index', 'Middle', 'IM'], ['Middle', 'Ring', 'MR'],
    ['Ring', 'Little', 'RL']];
  const kTaperRadio = [1, 0.85, 0.75];

  function puntoMasCercano(a0, a1, b0, b1) {
    // Cercania entre dos segmentos (Ericson). Devuelve {d, ca, cb, s, t}
    const d1 = sub(a1, a0), d2 = sub(b1, b0), r = sub(a0, b0);
    const a = dot(d1, d1), e = dot(d2, d2), f = dot(d2, r);
    let s, t;
    const c = dot(d1, r);
    const b = dot(d1, d2);
    const den = a * e - b * b;
    s = den > 1e-12 ? clamp((b * f - c * e) / den, 0, 1) : 0;
    t = (b * s + f) / (e || 1e-12);
    if (t < 0) { t = 0; s = clamp(-c / (a || 1e-12), 0, 1); }
    else if (t > 1) { t = 1; s = clamp((b - c) / (a || 1e-12), 0, 1); }
    const ca = add(a0, mul(d1, s)), cb = add(b0, mul(d2, t));
    return {d: largo(sub(ca, cb)), ca, cb, s, t};
  }

  function aplicarFlexLimites(r, k, signo) {
    const flex = clamp(signo * r.f, kFlexMin[k], kFlexMax[k]);
    r.f = signo * flex;
    r.flex = flex;
    r.a = clamp(r.a, -kSepMax[k], kSepMax[k]);
  }

  function separarDedos(modelo, resultados, P, estado) {
    const signo = modelo.signoFlex;
    if (estado && !estado.cruce) estado.cruce = {};
    const cruce = (estado && estado.cruce) || {};
    for (let pasada = 0; pasada < 2; pasada++) {
      for (const [na, nb, clave] of kParesDedos) {
        const ra = resultados[na], rb = resultados[nb];
        if (!ra || !rb) continue;
        const da = modelo.dedos[na], db = modelo.dedos[nb];
        const sep0 = largo(sub(da.offs[0], db.offs[0]));
        const A = fkDedoLargo(modelo, na, ra), B = fkDedoLargo(modelo, nb, rb);
        // peor penetracion entre segmentos
        let peor = null;
        for (let i = 0; i < 3; i++) {
          for (let j = 0; j < 3; j++) {
            const rr = 0.37 * sep0 * (kTaperRadio[i] + kTaperRadio[j]);
            const c = puntoMasCercano(A[i], A[i + 1], B[j], B[j + 1]);
            const pen = rr - c.d;
            if (pen > 1e-5 && (!peor || pen > peor.pen)) {
              peor = {pen, rr, i, j, ...c};
            }
          }
        }
        if (!peor) continue;
        // convencion dorso/palma con histeresis (eje Y local = dorso)
        const lmA = [P[kIdx[na][peor.i]], P[kIdx[na][peor.i + 1]]];
        const lmB = [P[kIdx[nb][peor.j]], P[kIdx[nb][peor.j + 1]]];
        const lc = puntoMasCercano(lmA[0], lmA[1], lmB[0], lmB[1]);
        const dy = lc.ca[1] - lc.cb[1];
        if (cruce[clave] == null) cruce[clave] = dy >= 0 ? 1 : -1;
        else if (Math.abs(dy) > 0.015 * (modelo.palma || 0.067)) {
          cruce[clave] = dy > 0 ? 1 : -1;
        }
        const nConv = [0, cruce[clave], 0];
        let n = nConv;
        if (peor.d > 1e-6) {
          const nGeo = mul(sub(peor.ca, peor.cb), 1 / peor.d);
          const w = smooth01((peor.d / peor.rr - 0.25) / 0.35);
          n = unit(add(mul(nGeo, w), mul(nConv, 1 - w))) || nConv;
        }
        const cantidad = peor.pen * 0.5 * 1.05;
        for (const [nombre, res, punto, sg] of [
          [na, ra, peor.ca, 1], [nb, rb, peor.cb, -1]]) {
          const R0 = mm(rotZ(res[0].f), rotY(res[0].a));
          const mcp = modelo.dedos[nombre].offs[0];
          const palanca = sub(punto, mcp);
          const ejeF = [0, 0, 1];
          const ejeA = mv(R0, [0, 1, 0]);
          const gF = dot(cross(ejeF, palanca), n) * sg;
          const gA = dot(cross(ejeA, palanca), n) * sg;
          const g2 = gF * gF + gA * gA;
          if (g2 < 1e-10) continue;
          let df = gF * cantidad / g2, dA = gA * cantidad / g2;
          df = clamp(df, -0.2, 0.2); dA = clamp(dA, -0.2, 0.2);
          res[0].f += df; res[0].a += dA;
          aplicarFlexLimites(res[0], 0, signo);
        }
      }
    }
  }

  // ------------- Contacto y colision: ajuste conjunto de las cadenas -------------
  // Despues de resolver cada dedo por separado se hace un repaso donde TODAS
  // las falanges pueden moverse un poco: (1) la yema del pulgar y la del dedo
  // con el que hace contacto se acercan hasta tocarse (el circulo de la D, la
  // O, la F...) repartiendo el movimiento entre las dos cadenas; (2) ningun par
  // de falanges de dedos distintos puede quedar a menos de `kHolgura` (si se
  // traspasan, la malla se funde y desaparece la linea oscura que divide los
  // dedos; el contorno del avatar mide ~2.5 mm); (3) el lazo que forman el
  // pulgar y el dedo se redondea: la curvatura se reparte entre todas las
  // falanges en vez de concentrarse en dos articulaciones (triangulo).
  // Es un ajuste basado en posiciones (PBD) con derivadas analiticas: cada
  // restriccion mueve los angulos de las dos cadenas en proporcion a cuanto
  // ayuda cada articulacion, respetando los limites.
  // Radios (m) por falange medidos en la malla del avatar: [prox, medio, yema].
  const kRadios = {
    Index: [0.0071, 0.0054, 0.0036], Middle: [0.0066, 0.0055, 0.0040],
    Ring: [0.0069, 0.0050, 0.0031], Little: [0.0054, 0.0045, 0.0028],
    Thumb: [0.0090, 0.0075, 0.0042],
  };
  const kPalmaRef = 0.0668;       // largo de palma con el que se midieron
  const kHolguraDedos = 0.0020;   // entre dedos largos
  const kHolguraPulgar = 0.0015;  // pulgar contra dedo
  const kContactoSecundario = 0.35;
  const kPesoPlano = 3;
  // "masa inversa" de cada parametro: cuanto se deja mover. Flexion libre;
  // la separacion lateral solo en el nudillo (las demas casi no giran).
  const kMovDedo = [1, 1, 1.2, 0.5, 0.12, 0.12];
  const kDevDedo = [0.9, 0.9, 0.9, 0.2, 0.08, 0.08];  // desviacion maxima (rad)
  const kParesLargos = [['Index', 'Middle'], ['Middle', 'Ring'], ['Ring', 'Little'],
    ['Index', 'Ring'], ['Middle', 'Little'], ['Index', 'Little']];
  const kEjeArt = [0, 1, 2, 0, 1, 2];   // articulacion de cada parametro del dedo largo
  const kEjeArtPulgar = [0, 0, 1, 1, 2, 2];  // y del pulgar (2 por hueso)

  function cadenasDe(modelo, out) {
    const signo = modelo.signoFlex;
    const esc = (modelo.palma || kPalmaRef) / kPalmaRef;
    const lista = [];
    for (const nombre of kNombresLargos) {
      const r = out.dedos[nombre];
      if (!r) continue;
      const th = [r[0].f, r[1].f, r[2].f, r[0].a, r[1].a, r[2].a];
      const lo = [], hi = [];
      for (let k = 0; k < 3; k++) {
        const a = signo * kFlexMin[k], b = signo * kFlexMax[k];
        lo.push(Math.min(a, b)); hi.push(Math.max(a, b));
      }
      for (let k = 0; k < 3; k++) { lo.push(-kSepMax[k]); hi.push(kSepMax[k]); }
      for (let k = 0; k < 6; k++) {
        lo[k] = Math.max(lo[k], th[k] - kDevDedo[k]);
        hi[k] = Math.min(hi[k], th[k] + kDevDedo[k]);
      }
      lista.push({nombre, pulgar: false, th, th0: th.slice(), lo, hi, mov: kMovDedo,
        rad: kRadios[nombre].map((v) => v * esc), pts: null});
    }
    if (out.pulgar && modelo.dedos.Thumb) {
      const th = out.pulgar.params.slice();
      const lo = th.map((v) => v - 0.9), hi = th.map((v) => v + 0.9);
      lista.push({nombre: 'Thumb', pulgar: true, th, th0: th.slice(), lo, hi,
        mov: [1, 1, 1, 1, 1, 1], base: modelo.dedos.Thumb.r.map(baseTangente),
        rad: kRadios.Thumb.map((v) => v * esc), pts: null});
    }
    return lista;
  }

  // Jacobiano derecho de SO(3) en el vector de giro W (|W| = ang)
  function jacobianoDerecho(W, ang) {
    const a2 = ang * ang;
    const a = ang < 1e-3 ? 0.5 - a2 / 24 : (1 - Math.cos(ang)) / a2;
    const b = ang < 1e-3 ? 1 / 6 - a2 / 120 : (ang - Math.sin(ang)) / (a2 * ang);
    const x = W[0], y = W[1], z = W[2];
    const K = [0, -z, y, z, 0, -x, -y, x, 0];
    const K2 = mm(K, K);
    const J = new Array(9);
    for (let i = 0; i < 9; i++) J[i] = (i % 4 === 0 ? 1 : 0) - a * K[i] + b * K2[i];
    return J;
  }

  // Cinematica directa de la cadena + eje de giro (en el marco de la mano) de
  // cada parametro: c.eW[m] = eje, c.eK[m] = articulacion (su pivote es
  // pts[eK[m]]; mueve todos los puntos posteriores). Tambien guarda las
  // capsulas (3 segmentos; el ultimo termina un radio antes de la punta) y una
  // esfera que las envuelve.
  function fkCadena(modelo, c) {
    const d = modelo.dedos[c.nombre];
    let Q = I3();
    let p = d.offs[0].slice();
    const pts = [p];
    const eW = new Array(6);
    if (!c.pulgar) {
      c.eK = kEjeArt;
      for (let k = 0; k < 3; k++) {
        const QRz = mm(Q, rotZ(c.th[k]));
        eW[k] = [Q[2], Q[5], Q[8]];
        eW[3 + k] = [QRz[1], QRz[4], QRz[7]];
        Q = mm(QRz, rotY(c.th[3 + k]));
        const off = k < 2 ? d.offs[k + 1] : mul(d.r[2], d.punta);
        p = add(p, mv(Q, off));
        pts.push(p);
      }
    } else {
      c.eK = kEjeArtPulgar;
      for (let k = 0; k < 3; k++) {
        const e1 = c.base[k][0], e2 = c.base[k][1];
        const W = add(mul(e1, c.th[2 * k]), mul(e2, c.th[2 * k + 1]));
        const ang = largo(W);
        const G = ang < 1e-9 ? I3() : rotEje(mul(W, 1 / ang), ang);
        Q = mm(Q, G);
        const Jr = jacobianoDerecho(W, ang);
        eW[2 * k] = mv(Q, mv(Jr, e1));
        eW[2 * k + 1] = mv(Q, mv(Jr, e2));
        const off = k < 2 ? d.offs[k + 1] : mul(d.r[2], d.punta);
        p = add(p, mv(Q, off));
        pts.push(p);
      }
    }
    c.pts = pts; c.eW = eW;
    const v = sub(pts[3], pts[2]);
    const l = largo(v);
    const r2 = c.rad[2];
    c.segs = [[pts[0], pts[1]], [pts[1], pts[2]],
      [pts[2], l > r2 + 1e-5 ? sub(pts[3], mul(v, r2 / l)) : pts[2]]];
    const cen = mul(add(pts[0], pts[3]), 0.5);
    let rr = 0;
    for (const q of pts) rr = Math.max(rr, largo(sub(q, cen)));
    c.cen = cen; c.esf = rr + Math.max(c.rad[0], c.rad[1], c.rad[2]);
    return c;
  }

  function estadoCadena(modelo, c) {
    if (!c.pts) fkCadena(modelo, c);
    return c;
  }

  function limitarCadena(c) {
    for (let k = 0; k < 6; k++) c.th[k] = clamp(c.th[k], c.lo[k], c.hi[k]);
    if (c.pulgar) {
      for (let k = 0; k < 3; k++) {
        const m = Math.hypot(c.th[2 * k], c.th[2 * k + 1]);
        if (m > kPulgarMaxGiro[k]) {
          const e = kPulgarMaxGiro[k] / m;
          c.th[2 * k] *= e; c.th[2 * k + 1] *= e;
        }
      }
    }
    c.pts = null;
  }

  const cercanas = (A, B, margen) => {
    const d = sub(A.cen, B.cen);
    return d[0] * d[0] + d[1] * d[1] + d[2] * d[2] <
      (A.esf + B.esf + margen) * (A.esf + B.esf + margen);
  };

  // Un paso de proyeccion de la restriccion rc = {A, i, B, j, obj, modo,
  // capa, relax}. modo 'min': solo actua si la separacion entre las
  // superficies es menor que `obj`; 'igual': la lleva a `obj` (contacto).
  // Devuelve la violacion que tenia (m).
  function proyectarRestriccion(modelo, rc) {
    const {A, B, i, j} = rc;
    estadoCadena(modelo, A); estadoCadena(modelo, B);
    const sa = A.segs[i], sb = B.segs[j];
    const c = puntoMasCercano(sa[0], sa[1], sb[0], sb[1]);
    const R = A.rad[i] + B.rad[j];
    const C = c.d - R - rc.obj;
    if (rc.modo === 'min' ? C >= -2e-5 : Math.abs(C) < 1.5e-4) return 0;
    // direccion de A respecto a B (de B hacia A)
    let n;
    if (c.d > 1e-6) {
      n = mul(sub(c.ca, c.cb), 1 / c.d);
      if (rc.capa) {
        const w = smooth01((c.d / R - 0.25) / 0.35);
        n = unit(add(mul(n, w), mul(rc.capa, 1 - w))) || rc.capa;
      }
    } else n = rc.capa || [0, 1, 0];
    const gr = [];
    let den = 0;
    for (const [K, idx, signoK, pto] of [[A, i, 1, c.ca], [B, j, -1, c.cb]]) {
      const g = [0, 0, 0, 0, 0, 0];
      for (let m = 0; m < 6; m++) {
        const k = K.eK[m];
        if (k > idx) continue;
        g[m] = signoK * dot(n, cross(K.eW[m], sub(pto, K.pts[k])));
        // articulacion en su tope empujando hacia afuera: no cuenta
        const dd = -C * g[m];
        if ((dd > 0 && K.th[m] >= K.hi[m] - 1e-4) ||
            (dd < 0 && K.th[m] <= K.lo[m] + 1e-4)) g[m] = 0;
        den += K.mov[m] * g[m] * g[m];
      }
      gr.push(g);
    }
    if (den < 1e-9) return Math.abs(C);
    const lam = -C / den * (rc.relax == null ? 1 : rc.relax);
    [[A, gr[0]], [B, gr[1]]].forEach(([K, g]) => {
      for (let m = 0; m < 6; m++) {
        if (g[m] === 0) continue;
        K.th[m] += clamp(K.mov[m] * g[m] * lam, -0.25, 0.25);
      }
      limitarCadena(K);
    });
    return Math.abs(C);
  }

  // Una pasada: contactos y choques entre los pares de cadenas que estan cerca
  function pasadaRestricciones(modelo, contacto, grupos) {
    let peor = 0;
    for (const rc of contacto) peor = Math.max(peor, proyectarRestriccion(modelo, rc));
    for (const g of grupos) {
      estadoCadena(modelo, g.A); estadoCadena(modelo, g.B);
      if (!cercanas(g.A, g.B, g.margen)) continue;
      for (const rc of g.lista) peor = Math.max(peor, proyectarRestriccion(modelo, rc));
    }
    return peor;
  }

  // ---- Redondez del lazo pulgar-dedo (la O, la D, la F, la C...) ----
  // El lazo que forman la base del pulgar, sus tres huesos, el punto de
  // contacto, los tres huesos del dedo y la palma es un poligono. Si solo
  // se dobla en dos articulaciones queda en TRIANGULO. Un circulo reparte la
  // curvatura por igual: el giro en cada vertice es proporcional al largo
  // de los dos lados que lo tocan. Ademas debe quedar plano.
  function lazoPuntos(modelo, T, F) {
    estadoCadena(modelo, T); estadoCadena(modelo, F);
    const t = T.pts, f = F.pts;
    return [t[0], t[1], t[2], mul(add(t[3], f[3]), 0.5), f[2], f[1], f[0]];
  }
  const kVertPlano = [1, 2, 4, 5];
  const angEntre = (a, b) => Math.atan2(largo(cross(a, b)), dot(a, b));
  // Residuos del lazo: 7 de curvatura (giro - kappa*largo) y 4 de planaridad.
  function residuosLazo(V) {
    const n = V.length;
    const e = [], l = [];
    for (let i = 0; i < n; i++) {
      const d = sub(V[(i + 1) % n], V[i]);
      e.push(d); l.push(largo(d));
    }
    const tau = [], lv = [];
    let sumaT = 0, sumaL = 0;
    for (let i = 0; i < n; i++) {
      const p = (i + n - 1) % n;
      const t = l[p] * l[i] > 1e-10 ? angEntre(e[p], e[i]) : 0;
      tau.push(t); lv.push(0.5 * (l[p] + l[i]));
      sumaT += t; sumaL += lv[i];
    }
    const kappa = sumaL > 0 ? sumaT / sumaL : 0;
    const r = new Array(n + 4).fill(0);
    for (let i = 0; i < n; i++) r[i] = tau[i] - kappa * lv[i];
    const nPl = cross(sub(V[3], V[0]), sub(V[n - 1], V[0]));
    const lPl = largo(nPl);
    let fuera = 0;
    if (lPl > 1e-8) {
      const s = Math.sqrt(kPesoPlano) / 0.03;
      kVertPlano.forEach((i, q) => {
        const d = dot(sub(V[i], V[0]), nPl) / lPl;
        r[n + q] = s * d; fuera += d * d;
      });
    }
    return {r, kappa, fuera: Math.sqrt(fuera / 4), l, e};
  }
  // Estadisticas del lazo (para decidir si aplica y para diagnostico)
  function redondezLazo(V) {
    const rs = residuosLazo(V);
    let E = 0;
    for (const x of rs.r) E += x * x;
    let A = [0, 0, 0], per = 0;
    const n = V.length;
    for (let i = 0; i < n; i++) {
      A = add(A, cross(V[i], V[(i + 1) % n]));
      per += rs.l[i];
    }
    const q = per > 1e-9 ? 0.5 * largo(A) / (per * per) : 0;
    return {E, q, kappa: rs.kappa, fuera: rs.fuera, area: 0.5 * largo(A), per,
      cuerda: largo(sub(V[3], V[n - 1])), cy: V[3][1], cx: V[3][0]};
  }

  // Resuelve A x = b (n <= 12) por eliminacion con pivoteo; A se destruye
  function resolverLineal(A, b, n) {
    for (let i = 0; i < n; i++) {
      let p = i;
      for (let r = i + 1; r < n; r++) if (Math.abs(A[r][i]) > Math.abs(A[p][i])) p = r;
      if (Math.abs(A[p][i]) < 1e-12) return null;
      if (p !== i) { [A[p], A[i]] = [A[i], A[p]]; [b[p], b[i]] = [b[i], b[p]]; }
      for (let r = i + 1; r < n; r++) {
        const f = A[r][i] / A[i][i];
        if (f === 0) continue;
        for (let c = i; c < n; c++) A[r][c] -= f * A[i][c];
        b[r] -= f * b[i];
      }
    }
    const x = new Array(n);
    for (let i = n - 1; i >= 0; i--) {
      let s = b[i];
      for (let c = i + 1; c < n; c++) s -= A[i][c] * x[c];
      x[i] = s / A[i][i];
    }
    return x;
  }

  // Un paso de Levenberg-Marquardt sobre los 12 angulos (pulgar + dedo) que
  // reparte la curvatura del lazo y lo aplana SIN soltar el contacto ni
  // meterse en otros dedos: el contacto y los choques que tocan al pulgar o
  // al dedo entran como filas del mismo sistema (con derivadas analiticas).
  // `gate` (0..1) atenua solo la parte de redondez.
  const kAj = {mu: 0.06,       // amortiguacion (mas alto = pasos mas cortos)
    fide: 0.2,                // ancla suave a los angulos de los landmarks
    contacto: 400,             // 1 mm de hueco ~ 0.4 rad de curvatura
    choque: 400,
    temp: 3};                // ancla al resultado del cuadro anterior (estabilidad)
  function pasoRedondez(modelo, T, F, gate, contacto, grupos) {
    const V = lazoPuntos(modelo, T, F);
    const base = residuosLazo(V).r.map((x) => x * gate);
    const mR = base.length;
    const h = 5e-3;
    const cols = [];
    for (const K of [T, F]) for (let m = 0; m < 6; m++) cols.push([K, m]);
    const N = cols.length;
    const J = cols.map(() => []);      // J[col][fila]
    // columnas de redondez (diferencias finitas sobre los vertices)
    cols.forEach(([K, m], ci) => {
      const esT = K === T;
      const k = K.eK[m];
      const w = K.eW[m], piv = K.pts[k];
      const dp = (j) => cross(w, sub(K.pts[j], piv));
      const V2 = V.slice();
      if (esT) {
        if (k < 1) V2[1] = add(V[1], mul(dp(1), h));
        if (k < 2) V2[2] = add(V[2], mul(dp(2), h));
      } else {
        if (k < 2) V2[4] = add(V[4], mul(dp(2), h));
        if (k < 1) V2[5] = add(V[5], mul(dp(1), h));
      }
      V2[3] = add(V[3], mul(dp(3), 0.5 * h));
      const r2 = residuosLazo(V2).r;
      for (let q = 0; q < mR; q++) J[ci].push((gate * r2[q] - base[q]) / h);
    });
    // filas de contacto y choques que involucran a T o F
    const filas = [];   // residuos
    const agregar = (rc, peso) => {
      const {A, B, i, j} = rc;
      const enA = A === T || A === F, enB = B === T || B === F;
      if (!enA && !enB) return;
      estadoCadena(modelo, A); estadoCadena(modelo, B);
      const sa = A.segs[i], sb = B.segs[j];
      const c = puntoMasCercano(sa[0], sa[1], sb[0], sb[1]);
      const R = A.rad[i] + B.rad[j];
      const g = c.d - R - rc.obj;
      if (rc.modo === 'min' && g > 0.0005) return;
      let n;
      if (c.d > 1e-6) {
        n = mul(sub(c.ca, c.cb), 1 / c.d);
        if (rc.capa) {
          const w = smooth01((c.d / R - 0.25) / 0.35);
          n = unit(add(mul(n, w), mul(rc.capa, 1 - w))) || rc.capa;
        }
      } else n = rc.capa || [0, 1, 0];
      filas.push(peso * (rc.modo === 'min' ? Math.min(g, 0) : g));
      cols.forEach(([K, m], ci) => {
        let d = 0;
        const k = K.eK[m];
        if (K === A && k <= i) d += dot(n, cross(K.eW[m], sub(c.ca, K.pts[k])));
        if (K === B && k <= j) d -= dot(n, cross(K.eW[m], sub(c.cb, K.pts[k])));
        J[ci].push(peso * d);
      });
    };
    for (const rc of contacto) agregar(rc, kAj.contacto * (rc.relax == null ? 1 : rc.relax));
    for (const g of grupos) {
      estadoCadena(modelo, g.A); estadoCadena(modelo, g.B);
      if (!cercanas(g.A, g.B, g.margen)) continue;
      for (const rc of g.lista) agregar(rc, kAj.choque);
    }
    const res = base.concat(filas);
    const M0 = res.length;
    const A = [], b = new Array(N);
    for (let a = 0; a < N; a++) {
      const fila = new Array(N);
      for (let c = 0; c < N; c++) {
        let s = 0;
        for (let q = 0; q < M0; q++) s += J[a][q] * J[c][q];
        fila[c] = s;
      }
      const [K, m] = cols[a];
      fila[a] += kAj.mu / K.mov[m] + kAj.fide * kAj.fide;
      let g = 0;
      for (let q = 0; q < M0; q++) g += J[a][q] * res[q];
      b[a] = -g - kAj.fide * kAj.fide * (K.th[m] - K.th0[m]);
      if (K.thPrev) {
        fila[a] += kAj.temp * kAj.temp;
        b[a] -= kAj.temp * kAj.temp * (K.th[m] - K.thPrev[m]);
      }
      A.push(fila);
    }
    const x = resolverLineal(A, b, N);
    if (!x) return 0;
    let mayor = 0;
    for (let a = 0; a < N; a++) {
      const [K, m] = cols[a];
      const dlt = clamp(x[a], -0.35, 0.35);
      K.th[m] += dlt;
      mayor = Math.max(mayor, Math.abs(dlt));
    }
    limitarCadena(T); limitarCadena(F);
    return mayor;
  }

  /**
   * `contactos`: {Index: {w, vl}, ...} con el peso de contacto del pulgar con
   * la yema de cada dedo (de los landmarks) y la distancia entre yemas.
   */
  function refinarMano(modelo, out, P, estado, contactos, opciones) {
    const cad = cadenasDe(modelo, out);
    const porNombre = {};
    for (const c of cad) porNombre[c.nombre] = c;
    if (cad.length < 2) return null;
    const cruce = (estado && (estado.cruce = estado.cruce || {})) || {};
    // Capa (dorso +Y / palma -Y) de cada par segun los landmarks, con histeresis
    const capaDe = (clave, a, b) => {
      let mejor = null;
      for (let i = 0; i < 3; i++) for (let j = 0; j < 3; j++) {
        const lc = puntoMasCercano(P[kIdx[a][i]], P[kIdx[a][i + 1]],
          P[kIdx[b][j]], P[kIdx[b][j + 1]]);
        if (!mejor || lc.d < mejor.d) mejor = lc;
      }
      const dy = mejor.ca[1] - mejor.cb[1];
      if (cruce[clave] == null) cruce[clave] = dy >= 0 ? 1 : -1;
      else if (Math.abs(dy) > 0.015 * (modelo.palma || kPalmaRef)) {
        cruce[clave] = dy > 0 ? 1 : -1;
      }
      return [0, cruce[clave], 0];
    };
    const claves = {'Index-Middle': 'IM', 'Middle-Ring': 'MR', 'Ring-Little': 'RL'};
    const contacto = [], grupos = [];
    const pul = porNombre.Thumb;
    // Dedo principal del contacto (el de mayor peso): el pulgar lo toca de
    // verdad; los demas dedos que tambien estan cerca solo lo intentan con
    // menos fuerza, si no los contactos se estorban entre si.
    let principal = null, wMax = 0.25;
    if (contactos) {
      for (const nb of kNombresLargos) {
        const ct = contactos[nb];
        if (ct && ct.w > wMax) { wMax = ct.w; principal = nb; }
      }
    }
    for (const [na, nb] of kParesLargos) {
      const A = porNombre[na], B = porNombre[nb];
      if (!A || !B) continue;
      const clave = claves[na + '-' + nb] || (na[0] + nb[0] + 'x');
      const capa = capaDe(clave, na, nb);
      const lista = [];
      for (let i = 0; i < 3; i++) for (let j = 0; j < 3; j++) {
        lista.push({A, i, B, j, obj: kHolguraDedos, modo: 'min', capa});
      }
      grupos.push({A, B, lista, margen: kHolguraDedos + 0.002});
    }
    if (pul) {
      for (const nb of kNombresLargos) {
        const B = porNombre[nb];
        if (!B) continue;
        const capa = capaDe('T' + nb[0], 'Thumb', nb);
        const ct = contactos && contactos[nb];
        const w = ct ? ct.w : 0;
        const enContacto = w > 0.25;
        const lista = [];
        for (let i = 1; i < 3; i++) for (let j = 0; j < 3; j++) {
          if (enContacto && i === 2 && j === 2) continue; // lo lleva el contacto
          lista.push({A: pul, i, B, j, obj: kHolguraPulgar, modo: 'min', capa});
        }
        grupos.push({A: pul, B, lista, margen: kHolguraPulgar + 0.002});
        if (enContacto) {
          const R = pul.rad[2] + B.rad[2];
          contacto.push({A: pul, i: 2, B, j: 2, modo: 'igual',
            obj: (1 - w) * Math.max(0, ct.vl - R), capa: null,
            relax: clamp((w - 0.25) / 0.35, 0, 1) * (nb === principal ? 1 : kContactoSecundario)});
        }
      }
    }
    // Solo se trabaja si hay contacto o alguna falange demasiado cerca
    const hayContacto = contacto.length > 0;
    let hayChoque = false;
    for (const g of grupos) {
      estadoCadena(modelo, g.A); estadoCadena(modelo, g.B);
      if (!cercanas(g.A, g.B, g.margen)) continue;
      for (const rc of g.lista) {
        const sa = rc.A.segs[rc.i], sb = rc.B.segs[rc.j];
        const c = puntoMasCercano(sa[0], sa[1], sb[0], sb[1]);
        if (c.d - rc.A.rad[rc.i] - rc.B.rad[rc.j] < rc.obj - 2e-5) {
          hayChoque = true; break;
        }
      }
      if (hayChoque) break;
    }
    if (!hayContacto && !hayChoque) return {iter: 0, peor: 0};
    const maxPas = opciones.pasadasRefinar ?? 10;
    let iter = 0, peor = 0;
    for (; iter < maxPas; iter++) {
      peor = pasadaRestricciones(modelo, contacto, grupos);
      if (opciones.trazas) opciones.trazas.push(peor);
      if (peor < 5e-5) { iter++; break; }
    }
    // Redondear el lazo pulgar-dedo cuando hay un contacto claro
    let redondez = null;
    if (principal && pul && porNombre[principal] && opciones.redondear !== false) {
      const F = porNombre[principal];
      const r0 = redondezLazo(lazoPuntos(modelo, pul, F));
      const wP = contactos[principal].w;
      // solo si el lazo deja un hueco (no un puño apretado)
      const gate = smooth01((wP - 0.4) / 0.4) * smooth01((r0.q - 0.015) / 0.03);
      if (gate > 0.02) {
        // Continuidad: si el cuadro anterior ya redondeo este mismo lazo, se
        // parte de su resultado y se ancla a el (sin esto, el lazo salta
        // entre soluciones parecidas de un cuadro a otro).
        const prev = estado && estado.prevLazo;
        if (prev && prev.dedo === principal && prev.pulgar && prev.dedoTh) {
          pul.thPrev = prev.pulgar; F.thPrev = prev.dedoTh;
          pul.th = prev.pulgar.slice(); F.th = prev.dedoTh.slice();
          limitarCadena(pul); limitarCadena(F);
        }
        const rondas = opciones.rondasRedondez ?? 5;
        let ro = 0;
        for (; ro < rondas; ro++) {
          const mayor = pasoRedondez(modelo, pul, F, gate, contacto, grupos);
          for (let p = 0; p < (opciones.pasadasRonda ?? 2); p++) {
            pasadaRestricciones(modelo, contacto, grupos);
          }
          if (mayor < 0.004) break;
        }
        // cierre final: contacto y choques, sin redondear mas
        for (let p = 0; p < (opciones.pasadasFinal ?? 4); p++) {
          if (pasadaRestricciones(modelo, contacto, grupos) < 5e-5) break;
        }
        const r1 = redondezLazo(lazoPuntos(modelo, pul, F));
        redondez = {gate, antes: r0, despues: r1, rondas: ro};
        if (estado) estado.prevLazo = {dedo: principal, pulgar: pul.th.slice(), dedoTh: F.th.slice()};
      } else if (estado) estado.prevLazo = null;
    } else if (estado) estado.prevLazo = null;
    // Niveles tras el contacto. El dedo que toca el pulgar se baja (o sube)
    // hasta la yema del pulgar, que en el avatar queda mas lejos que en los
    // landmarks; si los dedos vecinos estaban al mismo nivel que el, deben
    // acompanarlo con el mismo cambio, no quedarse a otra altura (en la D el
    // medio llegaba al pulgar y el anular y el menique se quedaban 3 cm mas
    // cerca de la palma). Cada seguidor parte de lo que vio la camara y recibe
    // el cambio del dedo principal, ponderado por lo parecido que era su nivel.
    let seguidores = null;
    if (principal && pul && porNombre[principal] && opciones.nivelar !== 0) {
      const Pr = porNombre[principal];
      const sg = modelo.signoFlex;
      const nivel0 = (c) => sg * (c.th0[0] + c.th0[1] + c.th0[2]);
      const cambio = [0, 1, 2].map((k) => Pr.th[k] - Pr.th0[k]);
      const fuerza = opciones.nivelar ?? 1;
      for (const nb of kNombresLargos) {
        if (nb === principal) continue;
        const F = porNombre[nb];
        if (!F) continue;
        const w = fuerza * smooth01((kNivelLejos - Math.abs(nivel0(F) - nivel0(Pr))) /
          (kNivelLejos - kNivelCerca));
        if (w <= 0.001) continue;
        for (let k = 0; k < 3; k++) F.th[k] = F.th0[k] + w * cambio[k];
        limitarCadena(F);
        (seguidores = seguidores || {})[nb] = w;
      }
      if (seguidores) {
        for (let p = 0; p < (opciones.pasadasNivel ?? 6); p++) {
          if (pasadaRestricciones(modelo, contacto, grupos) < 5e-5) break;
        }
      }
    }
    if (opciones.dep) {
      for (const g of grupos) for (const rc of contacto.concat(g.lista)) {
        estadoCadena(modelo, rc.A); estadoCadena(modelo, rc.B);
        const sa = rc.A.segs[rc.i], sb = rc.B.segs[rc.j];
        const c = puntoMasCercano(sa[0], sa[1], sb[0], sb[1]);
        const C = c.d - rc.A.rad[rc.i] - rc.B.rad[rc.j] - rc.obj;
        if (rc.modo === 'igual' || C < 0) {
          opciones.dep.push(`${rc.modo} ${rc.A.nombre}${rc.i}-${rc.B.nombre}${rc.j} C=${(C * 1000).toFixed(2)} obj=${(rc.obj * 1000).toFixed(1)} relax=${rc.relax}`);
        }
      }
    }
    // volcar a la salida
    const signo = modelo.signoFlex;
    for (const c of cad) {
      if (c.pulgar) {
        const giros = girosDeParams(c.base, c.th);
        const fk = fkPulgar(modelo, giros);
        out.pulgar.params = c.th.slice();
        out.pulgar.giros = giros;
        out.pulgar.quats = giros.map(aCuaternion);
        out.pulgar.pts = fk.pts;
      } else {
        const r = out.dedos[c.nombre];
        for (let k = 0; k < 3; k++) {
          r[k].f = c.th[k]; r[k].a = c.th[3 + k]; r[k].flex = signo * c.th[k];
        }
      }
    }
    return {iter, peor, redondez, seguidores};
  }

  // ----------------------------- Mano completa -----------------------------
  /**
   * `P`: 20 puntos [x,y,z] en el marco local de la mano, en metros del
   * avatar. Devuelve {dedos:{Index:[{f,a,flex}x3],...}, pulgar:{params,...},
   * contacto}. `opciones.estado` guarda la capa (dorso/palma) de cada cruce.
   */
  // Un dedo solo se dobla hacia la palma. Si los landmarks de una mano traen
  // las articulaciones doblandose hacia el dorso en conjunto, la mano esta
  // "al reves" (el detector la asigno al lado contrario: pasa en senas con
  // las manos juntas, como PERDON o GRACIAS). Se refleja contra el plano de
  // la palma para que el avatar doble los dedos hacia su palma, que es lo que
  // hacia el metodo anterior al medir solo el valor absoluto del angulo.
  function evidenciaEspejo(modelo, P) {
    let suma = 0;
    for (const nombre of kNombresLargos) {
      const M = kIdx[nombre].map((i) => P[i]);
      const t = [unit(sub(M[1], M[0])), unit(sub(M[2], M[1])),
        unit(sub(M[3], M[2]))];
      if (!t[0] || !t[1] || !t[2]) continue;
      const d = modelo.dedos[nombre];
      let Q = I3();
      for (let k = 0; k < 3; k++) {
        const u = mv(tr(Q), t[k]);
        const e = dosEjes(d.r[k], u, Math.PI / 2);
        Q = mm(Q, mm(rotZ(e.f), rotY(e.a)));
        if (k > 0) suma += clamp(modelo.signoFlex * e.f, -1.5, 1.5);
      }
    }
    return suma;
  }

  // ------------------------------ Niveles de los dedos ------------------------------
  // Cuando varios dedos estan en el MISMO estado (varios doblados, varios
  // estirados) la mano se ve ordenada si los dedos de ese estado quedan al
  // mismo nivel, y no cada uno con la flexion suelta que dejo la camara (uno
  // curvado en el nudillo, otro doblado hasta el tope en la articulacion
  // media). Los dedos en estados distintos conservan niveles distintos.
  //   - Nivel de un dedo = suma de la flexion de sus 3 articulaciones.
  //   - Dos dedos comparten nivel si sus niveles se parecen (peso suave, sin
  //     saltos entre cuadros): total hasta kNivelCerca, nada desde kNivelLejos.
  //   - El dedo que toca la yema del pulgar (D, O, F...) hace de ancla: es el
  //     que forma el circulo, asi que los demas toman SU forma y no al reves.
  //   - Solo cambia la flexion; la separacion lateral de cada dedo se queda.
  const kNivelCerca = 0.7;     // rad de flexion total
  const kNivelLejos = 1.3;
  const kAnclaContacto = 8;

  function nivelarDedos(modelo, dedos, P, opciones = {}) {
    const fuerza = opciones.nivelar ?? 1;
    if (!(fuerza > 0)) return;
    const nombres = kNombresLargos.filter((n) => dedos[n]);
    if (nombres.length < 2) return;
    const palma = modelo.palma || kPalmaRef;
    const cerca = opciones.contactoCerca ?? 0.15;
    const lejos = opciones.contactoLejos ?? 0.32;
    const info = nombres.map((n) => {
      const fl = dedos[n].map((r) => r.flex);
      const vl = largo(sub(P[3], P[kIdx[n][3]]));
      const wC = 1 - smooth01((vl / palma - cerca) / (lejos - cerca));
      return {n, fl, nivel: fl[0] + fl[1] + fl[2], ancla: 1 + kAnclaContacto * wC};
    });
    const signo = modelo.signoFlex;
    const nuevos = info.map((a) => {
      let den = 0;
      const num = [0, 0, 0];
      for (const b of info) {
        const w = a === b ? 1
          : smooth01((kNivelLejos - Math.abs(a.nivel - b.nivel)) / (kNivelLejos - kNivelCerca));
        if (w <= 0) continue;
        const peso = w * b.ancla;
        den += peso;
        for (let k = 0; k < 3; k++) num[k] += peso * b.fl[k];
      }
      return a.fl.map((v, k) => v + fuerza * (num[k] / den - v));
    });
    info.forEach((a, i) => {
      for (let k = 0; k < 3; k++) {
        const flex = clamp(nuevos[i][k], kFlexMin[k], kFlexMax[k]);
        dedos[a.n][k].flex = flex;
        dedos[a.n][k].f = signo * flex;
      }
    });
  }

  // ------------------------ Pulgar sobre la palma (B, 5...) ------------------------
  // Con el pulgar cruzado sobre la palma la camara lo ve de canto y suele
  // darle la ultima falange apuntando hacia adelante, junto al indice, como
  // si el pulgar estuviera a un lado. Para que se lea "va dentro de la palma"
  // se gira un poco esa ultima falange hacia el centro de la mano (a lo
  // ancho, sin mandar la punta hacia atras). El giro es pequeno (hasta
  // kPulgarPalmaMax) y solo cuando la punta ya esta sobre la palma y cerca de
  // su plano; si el pulgar toca otro dedo (O, F, D...) no se toca.
  const kPulgarPalmaMax = 0.45;   // rad (~26 deg)
  function pulgarHaciaPalma(modelo, P, pesoContacto, dedos, opciones = {}) {
    const maxGiro = opciones.pulgarPalma ?? kPulgarPalmaMax;
    if (!(maxGiro > 0)) return P;
    const q = kIdx.Thumb.map((i) => P[i]);
    const dist = sub(q[3], q[2]);
    const largoFal = largo(dist);
    const u = unit(dist);
    if (!u) return P;
    let c = [0, 0, 0];
    for (const n of kNombresLargos) c = add(c, P[kIdx[n][0]]);
    c = mul(c, 1 / 5);               // muneca (origen) + 4 nudillos
    const palma = modelo.palma || kPalmaRef;
    const dTip = largo(sub(q[3], c)) / palma;
    const wPos = 1 - smooth01((dTip - 0.6) / 0.4);
    const wPlano = 1 - smooth01((Math.abs(q[3][1] - c[1]) / palma - 0.2) / 0.3);
    // Solo con la palma al descubierto: si los dedos estan doblados (T, A,
    // S...) el pulgar queda debajo o entre ellos y girarlo lo atravesaria.
    let suma = 0, cuenta = 0;
    for (const n of kNombresLargos) {
      if (!dedos || !dedos[n]) continue;
      suma += dedos[n][0].flex + dedos[n][1].flex + dedos[n][2].flex;
      cuenta++;
    }
    const wDedos = cuenta ? 1 - smooth01((suma / cuenta - 0.5) / 0.8) : 1;
    const w = wPos * wPlano * wDedos * (1 - clamp(pesoContacto, 0, 1));
    if (w < 0.01) return P;
    const lado = (c[2] - q[2][2]) >= 0 ? 1 : -1;
    const obj = [0, 0, lado];
    const ang = Math.acos(clamp(dot(u, obj), -1, 1));
    const giro = Math.min(maxGiro * w, ang);
    if (giro < 1e-4) return P;
    const eje = unit(cross(u, obj));
    if (!eje) return P;
    const u2 = mv(rotEje(eje, giro), u);
    const P2 = P.slice();
    P2[3] = add(q[2], mul(u2, largoFal));
    return P2;
  }

  const kCurvaContactoMin = 0.7;   // flexion total (rad) bajo la cual el contacto no cuenta
  const kCurvaContactoPaso = 0.8;

  function resolverMano(modelo, P, opciones = {}) {
    if (!modelo || !P || P.length < 20 || P.some((p) => !p || !finito(p))) {
      return null;
    }
    let espejo = false;
    if (opciones.espejo !== false) {
      const ev = evidenciaEspejo(modelo, P);
      const est = opciones.estado;
      const previo = est ? est.espejo === true : false;
      // histeresis: cambiar de estado solo con evidencia clara
      espejo = ev < -0.9 || (previo && ev < 0.9);
      if (est) est.espejo = espejo;
    }
    if (espejo) P = P.map((p) => [p[0], -p[1], p[2]]);
    const out = {dedos: {}, pulgar: null};
    const sens = opciones.sensibilidad ?? 1;
    for (const nombre of kNombresLargos) {
      const M = kIdx[nombre].map((i) => P[i]);
      const r = resolverDedoLargo(modelo, nombre, M, sens);
      if (r) out.dedos[nombre] = r;
    }
    if (opciones.nivelar !== 0) nivelarDedos(modelo, out.dedos, P, opciones);
    if (opciones.separar !== false) {
      separarDedos(modelo, out.dedos, P, opciones.estado);
    }
    const largos = {};
    for (const nombre of Object.keys(out.dedos)) {
      largos[nombre] = fkDedoLargo(modelo, nombre, out.dedos[nombre]);
    }
    // Contacto del pulgar: promedio ponderado de las yemas que, en los
    // landmarks, estan al alcance de la punta del pulgar.
    const tipPulgar = P[3];
    const palma = modelo.palma || 0.067;
    const cerca = opciones.contactoCerca ?? 0.15;   // en palmas
    const lejos = opciones.contactoLejos ?? 0.32;
    const sepMin = opciones.separacionMin ?? 0.009;
    let sumaW = 0, sumaB = [0, 0, 0], peso = 0, mejor = null, dMejor = Infinity;
    const pesosContacto = {};
    for (const nombre of kNombresLargos) {
      if (!largos[nombre]) continue;
      const v = sub(tipPulgar, P[kIdx[nombre][3]]);
      const vl = largo(v);
      if (vl < dMejor) { dMejor = vl; mejor = nombre; }
      // El contacto del pulgar con un dedo recto (K, P: el pulgar toca el
      // medio por el lado) no debe doblar ese dedo hasta la yema del pulgar:
      // solo cuenta cuando el dedo ya viene curvado (D, O, F, U...).
      const rd = out.dedos[nombre];
      const curva = rd ? rd[0].flex + rd[1].flex + rd[2].flex : 3;
      const w = (1 - smooth01((vl / palma - cerca) / (lejos - cerca))) *
        smooth01((curva - kCurvaContactoMin) / kCurvaContactoPaso);
      pesosContacto[nombre] = {w, vl};
      if (w <= 0.001) continue;
      const dir = vl > 1e-9 ? mul(v, 1 / vl) : [0, 0, 0];
      const b = add(largos[nombre][3], mul(dir, Math.max(vl, sepMin)));
      sumaW += w; sumaB = add(sumaB, mul(b, w));
      peso = Math.max(peso, w);
    }
    const blanco = sumaW > 0 ? mul(sumaB, 1 / sumaW) : null;
    const Ppul = pulgarHaciaPalma(modelo, P, peso, out.dedos, opciones);
    out.pulgar = resolverPulgar(modelo, Ppul, blanco, peso);
    out.contacto = {dedo: mejor, distancia: dMejor / palma, peso};
    out.espejo = espejo;
    if (opciones.refinar !== false && out.pulgar) {
      out.refinado = refinarMano(modelo, out, P, opciones.estado || {},
        pesosContacto, opciones);
    }
    return out;
  }

  // Cuaterniones [x,y,z,w] del dedo largo (R = Rz(f)·Ry(a)) y del pulgar
  const cuaternionDedo = (f, a) => aCuaternion(mm(rotZ(f), rotY(a)));
  function cuaternionesPulgar(modelo, params) {
    const base = modelo.dedos.Thumb.r.map(baseTangente);
    return girosDeParams(base, params).map(aCuaternion);
  }

  return {
    crearModelo, resolverMano, resolverDedoLargo, resolverPulgar,
    fkDedoLargo, fkPulgar, dosEjes, aCuaternion, rotZ, rotY, mm, mv, tr, I3,
    cuaternionDedo, cuaternionesPulgar, separarDedos, nivelarDedos, pulgarHaciaPalma, marcoMano, aMarcoLocal, giroMinimo, kIdx, kNombresLargos, kFlexMin, kFlexMax, kSepMax,
  };
})();
