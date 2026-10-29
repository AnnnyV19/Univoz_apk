#!/usr/bin/env python3
"""Lo que el recolector nocturno aprende de las revisiones de la dueña.

El recolector (recolector_nocturno.py) deja una línea por video en
datasets_lsm/recolector/eventos.jsonl con lo que midió: qué seña dijo el
reconocedor, la distancia, el margen, la calidad, de qué canal salió...
El panel (panel_recolector.py) guarda en revisiones.jsonl lo que la dueña
decidió de cada muestra: aprobar o rechazar, por qué la rechazó
(MOTIVOS) y si la aprobó suavizada.

Con esas dos cosas este módulo arma aprendizaje.json, que el recolector lee
la noche siguiente:

  - modelo:  una regresión logística pequeña que estima la probabilidad de
             que la dueña apruebe una muestra a partir de lo que mide el
             reconocedor. Solo se usa cuando ya hay al menos MIN_REVISIONES
             revisiones con aprobadas y rechazadas, y con un umbral elegido
             para que, en sus propias revisiones, casi nada de lo que se
             aprobaría solo lo hubiera rechazado ella (PRECISION_OBJETIVO).
  - canales_bloqueados:   canales de YouTube con varios rechazos y ninguna
                          aprobada: no se vuelven a bajar.
  - glosas_sin_youtube:   señas para las que YouTube trae otra cosa.
  - calidad_min:          sube si rechaza por manos mal detectadas.
  - suavizar:             se enciende si suele aprobar suavizado o rechaza
                          por temblor (filtro de mediana de 3 cuadros, que
                          quita brincos de un cuadro sin mover las alturas).
  - max_segundos:         baja si los videos traen varias señas.
  - lecciones:            lo mismo, en frases, para mostrarlo en el panel.

Todo es Python puro (sin numpy) para correr igual en la PC y en pruebas.
"""
import json
import math
import os
import time

MOTIVOS = {
    "otra_sena": "Es otra seña",
    "varias": "Trae varias señas",
    "cortada": "Está cortada",
    "mano_mal": "Manos mal detectadas",
    "temblor": "Tiembla o brinca",
    "palma": "Palma volteada",
    "video_malo": "Video malo (oscuro, lejos o de lado)",
    "no_lsm": "No es LSM",
}

MIN_REVISIONES = 20          # para usar el modelo
PRECISION_OBJETIVO = 0.95    # de lo que aprobaría solo, cuánto aprobó ella
CALIDAD_BASE = 0.85
MAX_SEGUNDOS_BASE = 30

NOMBRES_RASGOS = ["sesgo", "distancia", "margen", "calidad", "misma seña",
                  "aceptada", "de YouTube", "cuadros perdidos"]


# ------------------------------------------------------------------ lectura

def leer_jsonl(ruta):
    out = []
    if not os.path.exists(ruta):
        return out
    with open(ruta, encoding="utf-8") as f:
        for linea in f:
            linea = linea.strip()
            if not linea:
                continue
            try:
                out.append(json.loads(linea))
            except ValueError:
                continue                     # una línea a medio escribir
    return out


def agregar_jsonl(ruta, dato):
    os.makedirs(os.path.dirname(ruta), exist_ok=True)
    with open(ruta, "a", encoding="utf-8") as f:
        f.write(json.dumps(dato, ensure_ascii=False) + "\n")


def ultima_revision(revisiones):
    """sample_id -> la revisión más reciente (la dueña puede cambiar de idea)."""
    out = {}
    for r in revisiones:
        sid = r.get("sample_id")
        if sid:
            out[sid] = r
    return out


def ejemplos(eventos, revisiones):
    """[(evento, 1 si la aprobó / 0 si la rechazó, revisión)] de lo revisado."""
    rev = ultima_revision(revisiones)
    out = []
    for e in eventos:
        r = rev.get(e.get("sample_id"))
        if not r or e.get("decision") == "fallo":
            continue
        if r.get("decision") == "aprobar":
            out.append((e, 1, r))
        elif r.get("decision") == "rechazar":
            out.append((e, 0, r))
    return out


# ------------------------------------------------------------------ rasgos

def rasgos(e):
    """Vector de rasgos de un evento. Todo relativo a los umbrales del
    reconocedor, para que no dependa de cómo estén calibrados."""
    maxd = float(e.get("max_distancia") or 0.55) or 0.55
    minm = float(e.get("min_margen") or 0.12) or 0.12
    d = e.get("distancia")
    m = e.get("margen")
    d_rel = min(float(d) / maxd, 3.0) if d is not None and math.isfinite(float(d)) else 3.0
    m_rel = min(float(m) / minm, 5.0) if m is not None else 0.0
    n = float(e.get("n_frames") or 0)
    perdidos = float(e.get("frames_invalidos") or 0) / n if n else 0.0
    return [
        1.0,
        d_rel,
        m_rel,
        float(e.get("calidad") or 0.0),
        1.0 if e.get("prediccion") == e.get("gloss") else 0.0,
        1.0 if e.get("aceptada") else 0.0,
        1.0 if e.get("fuente") == "youtube" else 0.0,
        perdidos,
    ]


# --------------------------------------------------- regresión logística

def _sigmoide(z):
    if z >= 0:
        return 1.0 / (1.0 + math.exp(-z))
    ez = math.exp(z)
    return ez / (1.0 + ez)


def _resolver(a, b):
    """Resuelve a x = b (Gauss con pivoteo). a: n x n, b: n."""
    n = len(b)
    m = [list(a[i]) + [b[i]] for i in range(n)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(m[r][c]))
        if abs(m[p][c]) < 1e-12:
            continue
        m[c], m[p] = m[p], m[c]
        for r in range(n):
            if r != c:
                f = m[r][c] / m[c][c]
                if f:
                    for k in range(c, n + 1):
                        m[r][k] -= f * m[c][k]
    return [m[i][n] / m[i][i] if abs(m[i][i]) > 1e-12 else 0.0 for i in range(n)]


def entrenar(xs, ys, l2=1.0, iteraciones=25):
    """Regresión logística por Newton con regularización L2 (sin el sesgo)."""
    d = len(xs[0])
    w = [0.0] * d
    for _ in range(iteraciones):
        g = [0.0] * d
        h = [[0.0] * d for _ in range(d)]
        for x, y in zip(xs, ys):
            p = _sigmoide(sum(wi * xi for wi, xi in zip(w, x)))
            r = p - y
            s = p * (1 - p)
            for i in range(d):
                g[i] += r * x[i]
                xi_s = x[i] * s
                hi = h[i]
                for j in range(d):
                    hi[j] += xi_s * x[j]
        for i in range(1, d):
            g[i] += l2 * w[i]
            h[i][i] += l2
        h[0][0] += 1e-6
        paso = _resolver(h, g)
        w = [wi - pi for wi, pi in zip(w, paso)]
        if max(abs(p) for p in paso) < 1e-6:
            break
    return w


def probabilidad(w, x):
    return _sigmoide(sum(wi * xi for wi, xi in zip(w, x)))


def probabilidades_validadas(xs, ys, pliegues=5):
    """Probabilidad de cada ejemplo con un modelo que NO lo vio (k pliegues),
    para elegir el umbral sin engañarse."""
    n = len(xs)
    out = [None] * n
    k = min(pliegues, n)
    for f in range(k):
        prueba = [i for i in range(n) if i % k == f]
        entreno = [i for i in range(n) if i % k != f]
        ye = [ys[i] for i in entreno]
        if not entreno or min(ye) == max(ye):
            for i in prueba:
                out[i] = sum(ye) / len(ye) if ye else 0.5
            continue
        w = entrenar([xs[i] for i in entreno], ye)
        for i in prueba:
            out[i] = probabilidad(w, xs[i])
    return out


def elegir_umbral(probs, ys, precision=PRECISION_OBJETIVO, minimo=3):
    """El umbral más bajo con el que, de lo que se aprobaría solo, al menos
    `precision` lo aprobó ella. None si ninguno lo logra."""
    mejor = None
    for t in sorted(set(round(p, 3) for p in probs), reverse=True):
        sel = [y for p, y in zip(probs, ys) if p >= t]
        if len(sel) < minimo:
            continue
        if sum(sel) / len(sel) >= precision:
            mejor = t
        else:
            break
    return mejor


# ------------------------------------------------------------- aprendizaje

def aprender(eventos, revisiones):
    """Arma el dict de aprendizaje.json a partir de eventos y revisiones."""
    ej = ejemplos(eventos, revisiones)
    n_apr = sum(y for _, y, _ in ej)
    n_rec = len(ej) - n_apr
    out = {
        "actualizado": time.strftime("%Y-%m-%d %H:%M"),
        "revisadas": len(ej), "aprobadas": n_apr, "rechazadas": n_rec,
        "modelo": None, "umbral": None,
        "canales_bloqueados": [], "glosas_sin_youtube": [],
        "calidad_min": CALIDAD_BASE, "suavizar": False,
        "max_segundos": MAX_SEGUNDOS_BASE,
        "motivos": {}, "lecciones": [], "pesos": [],
        "simulacion": None,
    }
    lec = out["lecciones"]
    if not ej:
        lec.append("Todavía no hay revisiones: el recolector usa las reglas fijas "
                   "(misma seña, distancia y margen holgados, calidad ≥ 85 %).")
        return out

    # Motivos de rechazo.
    motivos = {}
    for _, y, r in ej:
        if y == 0:
            for m in r.get("motivos") or ["sin_motivo"]:
                motivos[m] = motivos.get(m, 0) + 1
    out["motivos"] = motivos

    # Canales y glosas.
    por_canal, por_glosa = {}, {}
    for e, y, r in ej:
        c = e.get("canal")
        if e.get("fuente") == "youtube" and c:
            a = por_canal.setdefault(c, [0, 0])
            a[y] += 1
        if e.get("fuente") == "youtube":
            g = por_glosa.setdefault(e.get("gloss"), [0, 0])
            if y == 1:
                g[1] += 1
            elif set(r.get("motivos") or []) & {"otra_sena", "no_lsm"}:
                g[0] += 1
    out["canales_bloqueados"] = sorted(c for c, (rec, apr) in por_canal.items()
                                       if rec >= 3 and apr == 0)
    out["glosas_sin_youtube"] = sorted(g for g, (mal, bien) in por_glosa.items()
                                       if g and mal >= 2 and bien == 0)
    for c in out["canales_bloqueados"]:
        lec.append(f"El canal «{c}» ya no se baja: {por_canal[c][0]} rechazadas y ninguna aprobada.")
    for g in out["glosas_sin_youtube"]:
        lec.append(f"{g}: en YouTube sale otra cosa; esa seña solo se busca en Wikisigns.")

    # Calidad mínima: el corte que deja fuera más rechazos por manos/video y
    # menos aprobadas.
    malas = [e for e, y, r in ej if y == 0 and
             set(r.get("motivos") or []) & {"mano_mal", "video_malo"}]
    if len(malas) >= 3:
        mejor, mejor_puntos = CALIDAD_BASE, 0
        for t in [0.85, 0.88, 0.9, 0.92, 0.94, 0.96, 0.98]:
            fuera_malas = sum(1 for e in malas if (e.get("calidad") or 0) < t)
            fuera_buenas = sum(1 for e, y, _ in ej if y == 1 and (e.get("calidad") or 0) < t)
            puntos = fuera_malas - 2 * fuera_buenas
            if puntos > mejor_puntos:
                mejor, mejor_puntos = t, puntos
        out["calidad_min"] = mejor
        if mejor > CALIDAD_BASE:
            lec.append(f"Calidad mínima subió a {mejor:.0%}: por debajo solías rechazar "
                       f"por manos mal detectadas o video malo.")

    # Suavizado.
    suavizadas = sum(1 for _, y, r in ej if y == 1 and "suavizado" in (r.get("acciones") or []))
    temblor = motivos.get("temblor", 0)
    if suavizadas + temblor >= 5 and (suavizadas + temblor) >= 0.3 * len(ej):
        out["suavizar"] = True
        lec.append(f"Las muestras nuevas se suavizan solas (filtro de mediana de 3 cuadros): "
                   f"{suavizadas} las aprobaste suavizadas y {temblor} las rechazaste por temblor.")

    # Varias señas en un video: videos más cortos.
    if motivos.get("varias", 0) >= 3:
        out["max_segundos"] = 15
        lec.append(f"Solo videos de 15 s o menos: {motivos['varias']} traían varias señas.")
    if motivos.get("cortada", 0) >= 3:
        lec.append(f"{motivos['cortada']} estaban cortadas: usa «Recortar y volver a sacar» "
                   "con el tramo bueno en lugar de rechazarlas.")
    if motivos.get("palma", 0) >= 3:
        lec.append(f"{motivos['palma']} tenían la palma volteada: suelen ser videos grabados en "
                   "espejo; revisa la opción «espejo» al subirlos a mano.")

    # Modelo.
    xs = [rasgos(e) for e, _, _ in ej]
    ys = [y for _, y, _ in ej]
    if len(ej) >= MIN_REVISIONES and 0 < n_apr < len(ej):
        probs = probabilidades_validadas(xs, ys)
        umbral = elegir_umbral(probs, ys)
        w = entrenar(xs, ys)
        out["modelo"] = {"rasgos": NOMBRES_RASGOS, "pesos": [round(v, 5) for v in w]}
        out["umbral"] = umbral
        out["pesos"] = sorted(
            ({"rasgo": n, "peso": round(v, 3)} for n, v in zip(NOMBRES_RASGOS[1:], w[1:])),
            key=lambda d: -abs(d["peso"]))
        aciertos = sum(1 for p, y in zip(probs, ys) if (p >= 0.5) == (y == 1))
        if umbral is not None:
            sel = [y for p, y in zip(probs, ys) if p >= umbral]
            out["simulacion"] = {
                "aprobaria_solo": len(sel), "de_esas_aprobaste": sum(sel),
                "aciertos_validados": aciertos, "total": len(ys)}
            lec.append(f"Aprobación automática con la IA: cuando cree ≥ {umbral:.0%} que la "
                       f"aprobarías. En tus {len(ys)} revisiones habría aprobado {len(sel)} "
                       f"y tú aprobaste {sum(sel)} de esas.")
        else:
            out["simulacion"] = {"aprobaria_solo": 0, "de_esas_aprobaste": 0,
                                 "aciertos_validados": aciertos, "total": len(ys)}
            lec.append("La IA todavía no distingue con seguridad: sigue aprobando solo con "
                       "las reglas fijas. Más revisiones la afinan.")
        lec.append(f"La IA atina {aciertos} de {len(ys)} ({aciertos / len(ys):.0%}) en revisiones "
                   "que no vio al aprender.")
    else:
        faltan = max(0, MIN_REVISIONES - len(ej))
        lec.append(f"La IA empieza a decidir con {MIN_REVISIONES} revisiones que tengan aprobadas "
                   f"y rechazadas (faltan {faltan}). Mientras, se usan las reglas fijas.")
    return out


def probabilidad_evento(aprendizaje, evento):
    """Probabilidad de que la dueña apruebe `evento`, o None sin modelo."""
    m = (aprendizaje or {}).get("modelo")
    if not m:
        return None
    return probabilidad(m["pesos"], rasgos(evento))


def decidir_aprendido(evento, aprendizaje, regla_fija):
    """Decisión final del recolector: ('aprobar' | 'pendiente', motivo).

    `regla_fija` es la decisión de recolector_nocturno.decidir(). Lo
    aprendido solo puede ser MÁS estricto con lo básico: nunca aprueba una
    seña sin aprobadas ni una que el reconocedor dice que es otra."""
    apr = aprendizaje or {}
    if not evento.get("hay_aprobadas"):
        return "pendiente", "la seña aún no tiene muestras aprobadas"
    if evento.get("prediccion") != evento.get("gloss"):
        return "pendiente", f"el reconocedor dice {evento.get('prediccion') or 'nada'}"
    cmin = apr.get("calidad_min", CALIDAD_BASE)
    if (evento.get("calidad") or 0) < cmin:
        return "pendiente", f"calidad {evento.get('calidad', 0):.0%} < {cmin:.0%} (aprendido)"
    p = probabilidad_evento(apr, evento)
    if p is not None and apr.get("umbral") is not None:
        if p >= apr["umbral"]:
            return "aprobar", f"la IA cree {p:.0%} que la aprobarías"
        return "pendiente", f"la IA cree {p:.0%} que la aprobarías (pide {apr['umbral']:.0%})"
    return regla_fija


# ----------------------------------------------------------------- suavizado

def suavizar_mediana(seq):
    """Mediana de 3 cuadros por dimensión. Quita brincos de un solo cuadro y
    respeta subidas, bajadas y mesetas: no aplana alturas ni las mueve. El
    primer y el último cuadro quedan igual."""
    n = len(seq)
    if n < 3:
        return [list(f) for f in seq]
    out = [list(seq[0])]
    for i in range(1, n - 1):
        a, b, c = seq[i - 1], seq[i], seq[i + 1]
        out.append([sorted((x, y, z))[1] for x, y, z in zip(a, b, c)])
    out.append(list(seq[-1]))
    return out


# --------------------------------------------------------------------- CLI

def main():
    import argparse
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--datos", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "datasets_lsm", "recolector"))
    args = ap.parse_args()
    ev = leer_jsonl(os.path.join(args.datos, "eventos.jsonl"))
    rv = leer_jsonl(os.path.join(args.datos, "revisiones.jsonl"))
    apr = aprender(ev, rv)
    guardar(args.datos, apr)
    for l in apr["lecciones"]:
        print("-", l)


def guardar(carpeta, apr):
    os.makedirs(carpeta, exist_ok=True)
    p = os.path.join(carpeta, "aprendizaje.json")
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(apr, f, ensure_ascii=False, indent=1)
    os.replace(tmp, p)


def cargar(carpeta):
    p = os.path.join(carpeta, "aprendizaje.json")
    if not os.path.exists(p):
        return {}
    try:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    except ValueError:
        return {}


if __name__ == "__main__":
    main()
