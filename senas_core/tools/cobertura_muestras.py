#!/usr/bin/env python3
"""Cuantas grabaciones DISTINTAS tiene cada sena y cuantas faltan para llegar a N (10).

Lee el plantillas.json que usa la app (el mismo que carga el telefono) y, con --base, tambien la
base de datos para decir cuantas muestras PENDIENTES hay por sena y de que dataset vienen. Asi se ve
de un vistazo:

  - que senas ya llegan al objetivo,
  - cuales llegarian con solo APROBAR lo que ya esta en la base (aprobar_dataset.py --por-glosa N),
  - cuales necesitan datos nuevos (un dataset que falta bajar, o grabarlas).

Cuenta GRABACIONES DISTINTAS, no plantillas: la app guarda cada toma y ademas su espejo (mano
izquierda), y una plantilla y su espejo son la misma grabacion. Tambien resta las identicas.

USO (desde senas_core)
    python tools/cobertura_muestras.py                     # solo plantillas.json
    python tools/cobertura_muestras.py --base              # + pendientes de la base, por dataset
    python tools/cobertura_muestras.py --base --objetivo 10 --csv datasets_lsm/cobertura.csv
    python tools/cobertura_muestras.py --solo-letras --base

No cambia nada (ni la base ni plantillas.json).
"""

import argparse
import csv
import datetime
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import sign_norm as sn  # noqa: E402
import moderar_senas as mod  # noqa: E402
from moderar_senas import log  # noqa: E402

LETRAS = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "LL", "M", "N", "NN", "O",
          "P", "Q", "R", "RR", "S", "T", "U", "V", "W", "X", "Y", "Z"]

# como empieza el video_uri de cada dataset -> nombre corto para el informe
FUENTES = {
    "zenodo:18330565": "medico",
    "zenodo:14689869": "alfabeto-dinamico",
    "zenodo:10067509": "alfabeto-estatico",
    "mendeley:g45jkzys4f": "ITESO",
    "mendeley:6rj76z6y3n": "UAEMex",
    "wikisigns:lsm": "Wikisigns",
}
TOL_IGUAL = 2e-3          # diferencia maxima por coordenada para llamar "identicas" a dos plantillas


def _igual(a, b):
    for fa, fb in zip(a, b):
        for x, y in zip(fa, fb):
            if abs(x - y) > TOL_IGUAL:
                return False
    return len(a) == len(b)


def grabaciones_distintas(plantillas):
    """{gloss: n} contando cada toma una sola vez: una plantilla, su espejo y las copias exactas
    cuentan como una. plantillas: lista de dicts con 'gloss' y 'seq'."""
    por = {}
    for p in plantillas:
        por.setdefault(p["gloss"], []).append(p["seq"])
    out = {}
    for g, seqs in por.items():
        unicas = []
        for s in seqs:
            m = None
            repetida = False
            for u in unicas:
                if _igual(s, u):
                    repetida = True
                    break
                if m is None:
                    m = sn.mirror_sequence(s)
                if _igual(m, u):
                    repetida = True
                    break
            if not repetida:
                unicas.append(s)
        out[g] = len(unicas)
    return out


def leer_json(rutas):
    for r in rutas:
        if r and os.path.exists(r):
            with open(r, encoding="utf-8") as f:
                d = json.load(f)
            if d.get("frame_dim") == sn.FRAME_DIM:
                return r, d["plantillas"]
    raise SystemExit("no encuentro un plantillas.json valido; pasalo con --json RUTA")


def fuente_de(uri):
    if not uri:
        return "propias"
    for pref, nombre in FUENTES.items():
        if uri.startswith(pref + "/") or uri.startswith(pref + ":"):
            return nombre
    m = re.match(r"^([a-z0-9_]+:[A-Za-z0-9_.-]+)/", uri)
    return m.group(1) if m else "propias"


def leer_base(reglas):
    """({gloss: {'espanol':..., 'aprobadas': n, 'pendientes': {fuente: n}}}, bloqueadas_o_a_revisar)."""
    conn = mod.conectar()
    try:
        cur = conn.cursor()
        cur.execute(
            """SELECT s.gloss, s.espanol, ss.estado, ss.video_uri
               FROM sign_samples ss JOIN signs s ON s.id = ss.sign_id
               WHERE ss.origen <> 'espejo' AND ss.estado IN ('aprobada', 'pendiente')""")
        filas = cur.fetchall()
    finally:
        conn.close()
    por = {}
    apartadas = set()
    for gloss, espanol, estado, uri in filas:
        d = por.setdefault(gloss, {"espanol": espanol or "", "aprobadas": 0, "pendientes": {}})
        if estado == "aprobada":
            d["aprobadas"] += 1
        else:
            v = mod.evaluar(reglas, gloss, espanol or "")
            if v and v[0] in ("bloquear", "revisar"):
                apartadas.add(gloss)
                continue
            f = fuente_de(uri)
            d["pendientes"][f] = d["pendientes"].get(f, 0) + 1
    return por, apartadas


def main():
    mod._consola_tolerante()
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--objetivo", type=int, default=10, metavar="N",
                    help="grabaciones distintas que se quieren por sena (10)")
    ap.add_argument("--json", nargs="+", default=mod.DESTINOS_DEFECTO,
                    help="plantillas.json a leer (usa el primero que exista)")
    ap.add_argument("--base", action="store_true",
                    help="tambien lee la base: pendientes por sena y por dataset (lo que aprobar_dataset.py "
                         "--por-glosa podria sumar)")
    ap.add_argument("--solo-letras", action="store_true", help="solo A-Z, LL, RR, N~")
    ap.add_argument("--mostrar", type=int, default=30, metavar="K",
                    help="cuantas senas listar en cada seccion (30)")
    ap.add_argument("--lista", default=mod.LISTA_DEFECTO)
    ap.add_argument("--csv", help="donde dejar el detalle (por defecto datasets_lsm/cobertura_<fecha>.csv)")
    args = ap.parse_args()
    N = args.objetivo

    ruta, plantillas = leer_json(args.json)
    glosas_json = {}
    for p in plantillas:
        glosas_json.setdefault(p["gloss"], p.get("espanol", ""))
    n_json = grabaciones_distintas(plantillas)
    log(f"plantillas.json: {ruta}")
    log(f"  {len(plantillas):,} plantillas de {len(n_json):,} senas = "
        f"{sum(n_json.values()):,} grabaciones distintas (el resto son espejos y copias)")

    base, apartadas = ({}, set())
    if args.base:
        reglas = mod.cargar_reglas(args.lista)
        base, apartadas = leer_base(reglas)

    glosas = sorted(set(n_json) | set(base))
    if args.solo_letras:
        glosas = [g for g in LETRAS if g in glosas]

    filas = []
    for g in glosas:
        ya = n_json.get(g, 0)
        pend = base.get(g, {}).get("pendientes", {}) if base else {}
        n_pend = sum(pend.values())
        # aprobadas en la base de una sena que NO esta en plantillas.json: entrarian al exportar
        sin_exportar = base.get(g, {}).get("aprobadas", 0) if (base and g not in n_json) else 0
        filas.append({
            "gloss": g, "espanol": glosas_json.get(g) or base.get(g, {}).get("espanol", ""),
            "ahora": ya, "pendientes": n_pend, "por_fuente": pend, "sin_exportar": sin_exportar,
            "alcanzaria": ya + sin_exportar + n_pend, "falta_hoy": max(0, N - ya),
            "falta_con_pendientes": max(0, N - ya - sin_exportar - n_pend),
        })

    def hist(clave):
        h = {}
        for f in filas:
            k = min(f[clave], N)
            h[k] = h.get(k, 0) + 1
        return h

    en_app = [f for f in filas if f["gloss"] in n_json]
    fuera = [f for f in filas if f["gloss"] not in n_json]
    log(f"\nObjetivo: {N} grabaciones distintas por sena.   Senas en la app: {len(en_app):,}"
        + (f"   (y {len(fuera):,} que solo estan en la base, sin plantilla en la app)" if fuera else ""))
    h = {}
    for f in en_app:
        h[min(f["ahora"], N)] = h.get(min(f["ahora"], N), 0) + 1
    log("\nHOY en plantillas.json (grabaciones distintas por sena -> cuantas senas):")
    log("   " + "  ".join(f"{k}{'+' if k == N else ''}: {h.get(k, 0)}" for k in range(1, N + 1) if h.get(k, 0)))
    llegan = sum(1 for f in en_app if f["ahora"] >= N)
    log(f"   llegan a {N}: {llegan:,}   |   con 1 sola: {sum(1 for f in en_app if f['ahora'] == 1):,}"
        f"   |   con 3 o mas: {sum(1 for f in en_app if f['ahora'] >= 3):,}")

    if base:
        sx = [f for f in filas if f["sin_exportar"]]
        if sx:
            log(f"\nOJO: {len(sx):,} senas tienen muestras APROBADAS en la base que no estan en plantillas.json "
                f"({sum(f['sin_exportar'] for f in sx):,} muestras): falta exportar "
                "(python tools/moderar_senas.py --exportar) o la base no corresponde a tu archivo.")
        log(f"\nCON LO QUE YA ESTA EN LA BASE (si se aprobara todo lo pendiente no bloqueado):")
        h2 = hist("alcanzaria")
        log("   " + "  ".join(f"{k}{'+' if k == N else ''}: {h2.get(k, 0)}" for k in range(1, N + 1) if h2.get(k, 0)))
        llegarian = [f for f in filas if f["ahora"] < N <= f["alcanzaria"]]
        sin_remedio = [f for f in filas if f["alcanzaria"] < N]
        log(f"   ya llegan: {llegan:,}   |   llegarian solo aprobando pendientes: {len(llegarian):,}"
            f"   |   les faltan DATOS NUEVOS: {len(sin_remedio):,}")
        por_fuente = {}
        for f in filas:
            for fu, n in f["por_fuente"].items():
                por_fuente[fu] = por_fuente.get(fu, 0) + n
        if por_fuente:
            log("   pendientes en la base por origen: " + ", ".join(
                f"{k} {v:,}" for k, v in sorted(por_fuente.items(), key=lambda x: -x[1])))
        if apartadas:
            log(f"   ({len(apartadas)} senas con pendientes bloqueadas o a revisar por palabras_prohibidas.txt no se cuentan)")
        if llegarian:
            llegarian.sort(key=lambda f: (-f["alcanzaria"], f["gloss"]))
            log(f"\nLlegarian a {N} aprobando (python tools/aprobar_dataset.py --dataset <ds> --por-glosa {N}):")
            for f in llegarian[:args.mostrar]:
                log(f"   {f['gloss']:<16} hoy {f['ahora']:>2}  + pendientes {f['pendientes']:>3} "
                    f"({', '.join(f'{k} {v}' for k, v in sorted(f['por_fuente'].items()))})")
            if len(llegarian) > args.mostrar:
                log(f"   ... y {len(llegarian) - args.mostrar} mas (estan en el CSV)")

    cerca = sorted([f for f in en_app if f["ahora"] < N], key=lambda f: (f["falta_hoy"], f["gloss"]))
    log(f"\nMAS CERCA DE {N} (las que menos faltan):")
    for f in cerca[:args.mostrar]:
        extra = f"  (+{f['pendientes']} pendientes)" if base and f["pendientes"] else ""
        log(f"   {f['gloss']:<16} hoy {f['ahora']:>2}  faltan {f['falta_hoy']:>2}{extra}")

    letras = [f for f in filas if f["gloss"] in LETRAS]
    if letras:
        log("\nABECEDARIO:")
        letras.sort(key=lambda f: LETRAS.index(f["gloss"]))
        for f in letras:
            extra = ""
            if base:
                extra = f"  pendientes {f['pendientes']:>3}" + (
                    f" ({', '.join(f'{k} {v}' for k, v in sorted(f['por_fuente'].items()))})" if f["por_fuente"] else "")
            marca = "ok" if f["ahora"] >= N else ("aprobando" if base and f["alcanzaria"] >= N else "faltan datos")
            log(f"   {f['gloss']:<3} hoy {f['ahora']:>2}{extra}   -> {marca}")

    ruta_csv = args.csv or os.path.join(mod.DATOS_DEFECTO, "cobertura_%s.csv" % datetime.datetime.now().strftime("%Y%m%d_%H%M%S"))
    os.makedirs(os.path.dirname(os.path.abspath(ruta_csv)), exist_ok=True)
    with open(ruta_csv, "w", encoding="utf-8-sig", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["gloss", "espanol", "grabaciones_hoy", "pendientes_en_base", "alcanzaria_aprobando",
                    "faltan_hoy", "faltan_aun_aprobando", "pendientes_por_origen"])
        for f in sorted(filas, key=lambda x: (x["ahora"], x["gloss"])):
            w.writerow([f["gloss"], f["espanol"], f["ahora"], f["pendientes"] if base else "",
                        f["alcanzaria"] if base else "", f["falta_hoy"],
                        f["falta_con_pendientes"] if base else "",
                        "; ".join(f"{k}={v}" for k, v in sorted(f["por_fuente"].items()))])
    log(f"\ndetalle por sena: {ruta_csv}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        log("\ninterrumpido")
        sys.exit(130)
