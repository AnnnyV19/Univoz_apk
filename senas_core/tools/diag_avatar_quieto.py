#!/usr/bin/env python3
"""Diagnostico (SOLO LEE): en que palabras el avatar casi no se mueve.

El avatar dibuja la PRIMERA plantilla de cada glosa del plantillas.json que usa la app (PantallaAvatar._buscar y
ControladorVisor._leerSecuencias hacen lo mismo). Para cada glosa mide esa primera toma:
  - pres:   fraccion de cuadros con mano detectada (la mayor de las dos manos)
  - brazo:  cuanto se mueven codos y munecas del cuerpo (dims 6..17 y 24..29), en anchos de hombro
  - codos:  lo que se mueven los codos (< 0.01 = esqueleto neutro de los videos sin hombros: el brazo del avatar
            no sigue ningun movimiento real)
  - forma:  cuanto cambia la forma de la mano (dedos) entre cuadros
Y busca, dentro de la misma glosa, si hay otra toma que se mueva mucho mas.

NO cambia ningun archivo, ni la base, ni alturas de muneca. Deja datasets_lsm/diag_avatar_quieto.csv y .txt.

USO (desde senas_core)
    python tools/diag_avatar_quieto.py
    python tools/diag_avatar_quieto.py --json D:\\UNIVOZ_APK\\univoz\\assets\\plantillas.json
"""

import argparse
import csv
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RAIZ = os.path.abspath(os.path.join(HERE, ".."))
JSON_DEFECTO = r"D:\UNIVOZ_APK\univoz\assets\plantillas.json"

OFF_LOC_L, OFF_LOC_R = 24, 27
OFF_PRES_L, OFF_PRES_R = 30, 31
OFF_SHAPE_L, OFF_SHAPE_R = 32, 92
DIMS_CODOS = list(range(6, 12))                 # codo izq, codo der
DIMS_BRAZO = list(range(6, 18)) + list(range(24, 30))   # codos + munecas del cuerpo + munecas en marco del cuerpo
DIMS_FORMA_L = list(range(OFF_SHAPE_L, OFF_SHAPE_L + 60))
DIMS_FORMA_R = list(range(OFF_SHAPE_R, OFF_SHAPE_R + 60))


def rango(seq, dims):
    return max(max(fr[d] for fr in seq) - min(fr[d] for fr in seq) for d in dims)


def desv_forma(seq, off_pres, dims):
    """Desviacion tipica media de la forma de una mano, solo en cuadros con esa mano presente."""
    cuadros = [fr for fr in seq if fr[off_pres] > 0.5]
    if len(cuadros) < 3:
        return 0.0
    tot = 0.0
    for d in dims:
        vals = [fr[d] for fr in cuadros]
        m = sum(vals) / len(vals)
        tot += math.sqrt(sum((v - m) ** 2 for v in vals) / len(vals))
    return tot / len(dims)


def medir(seq):
    n = len(seq)
    pl = sum(1 for fr in seq if fr[OFF_PRES_L] > 0.5) / n
    pr = sum(1 for fr in seq if fr[OFF_PRES_R] > 0.5) / n
    malo = any(not math.isfinite(x) for fr in seq for x in fr)
    codos = rango(seq, DIMS_CODOS)
    return {
        "cuadros": n,
        "pres": max(pl, pr),
        "pres_l": pl, "pres_r": pr,
        "brazo": rango(seq, DIMS_BRAZO),
        "codos": codos,
        "modo": "mano" if codos < 0.01 else "cuerpo",
        "forma": max(desv_forma(seq, OFF_PRES_L, DIMS_FORMA_L), desv_forma(seq, OFF_PRES_R, DIMS_FORMA_R)),
        "malo": malo,
    }


def movimiento(m):
    """Una sola cifra de 'cuanto se ve moverse': brazo (anchos de hombro) + forma de mano (x10), con la mano presente."""
    return (m["brazo"] + 10.0 * m["forma"]) * min(1.0, m["pres"] / 0.8)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--json", default=JSON_DEFECTO)
    ap.add_argument("--salida", default=os.path.join(RAIZ, "datasets_lsm"))
    args = ap.parse_args()

    with open(args.json, encoding="utf-8") as f:
        datos = json.load(f)
    plantillas = datos["plantillas"] if isinstance(datos, dict) else datos
    por_glosa = {}
    for t in plantillas:
        por_glosa.setdefault(t["gloss"], []).append(t)

    filas = []
    for g, lista in por_glosa.items():
        ms = [medir(t["seq"]) for t in lista]
        primera = ms[0]
        mejor_i = max(range(len(ms)), key=lambda i: movimiento(ms[i]))
        mejor = ms[mejor_i]
        filas.append({
            "gloss": g, "espanol": lista[0].get("espanol", ""), "tomas": len(lista),
            "pres": primera["pres"], "brazo": primera["brazo"], "codos": primera["codos"],
            "modo": primera["modo"], "forma": primera["forma"], "malo": primera["malo"],
            "mov": movimiento(primera), "mejor_i": mejor_i, "mejor_mov": movimiento(mejor),
            "mejor_modo": mejor["modo"], "mejor_pres": mejor["pres"],
        })

    # Cuatro motivos de "el avatar no hace nada", de mas a menos grave
    def sin_mano(r): return r["pres"] < 0.2
    def cuerpo_neutro(r): return r["modo"] == "mano" and r["forma"] < 0.02
    def casi_quieta(r): return r["mov"] < 0.35
    def pocos_cuadros_mano(r): return 0.2 <= r["pres"] < 0.6

    quietas = [r for r in filas if sin_mano(r) or casi_quieta(r) or r["malo"]]
    mejorables = [r for r in quietas if r["mejor_i"] != 0 and r["mejor_mov"] >= max(0.5, r["mov"] * 2)]

    os.makedirs(args.salida, exist_ok=True)
    ruta_csv = os.path.join(args.salida, "diag_avatar_quieto.csv")
    with open(ruta_csv, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        w.writerow(["gloss", "espanol", "tomas", "pres", "brazo", "codos", "modo", "forma", "movimiento",
                    "NaN", "mejor_toma", "mejor_movimiento", "mejor_modo", "mejor_pres", "motivo"])
        for r in sorted(filas, key=lambda r: r["mov"]):
            motivo = ("sin mano" if sin_mano(r) else "casi no se mueve" if casi_quieta(r)
                      else "pocos cuadros con mano" if pocos_cuadros_mano(r) else "")
            w.writerow([r["gloss"], r["espanol"], r["tomas"], f"{r['pres']:.2f}", f"{r['brazo']:.2f}",
                        f"{r['codos']:.3f}", r["modo"], f"{r['forma']:.3f}", f"{r['mov']:.2f}",
                        "SI" if r["malo"] else "", r["mejor_i"], f"{r['mejor_mov']:.2f}", r["mejor_modo"],
                        f"{r['mejor_pres']:.2f}", motivo])

    L = []
    L.append(f"plantillas.json: {args.json}")
    L.append(f"{len(plantillas):,} plantillas, {len(filas):,} glosas (el avatar usa la PRIMERA toma de cada glosa)\n")
    L.append(f"glosas cuya primera toma:")
    L.append(f"  no tiene mano detectada (pres < 20 %)        : {sum(1 for r in filas if sin_mano(r))}")
    L.append(f"  casi no se mueve (movimiento < 0.35)          : {sum(1 for r in filas if casi_quieta(r))}")
    L.append(f"  esqueleto neutro (codos fijos) y dedos quietos: {sum(1 for r in filas if cuerpo_neutro(r))}")
    L.append(f"  con NaN/inf                                   : {sum(1 for r in filas if r['malo'])}")
    L.append(f"  mano en < 60 % de los cuadros                 : {sum(1 for r in filas if r['pres'] < 0.6)}")
    L.append(f"  en modo 'solo mano' (codos fijos)             : {sum(1 for r in filas if r['modo'] == 'mano')}")
    L.append(f"\nEL AVATAR 'NO HACE NADA' (sin mano o casi quieta): {len(quietas)} glosas; en {len(mejorables)} de ellas")
    L.append("hay OTRA toma de la misma glosa que se mueve claramente mas (basta ponerla primera).\n")
    L.append("Las 60 que menos se mueven (gloss  tomas  pres  brazo  forma  modo  | mejor toma #: movimiento):")
    for r in sorted(filas, key=lambda r: r["mov"])[:60]:
        L.append(f"  {r['gloss']:28s} {r['tomas']:3d}  {r['pres']:.2f}  {r['brazo']:.2f}  {r['forma']:.3f}  {r['modo']:6s}"
                 f" | #{r['mejor_i']}: {r['mejor_mov']:.2f} ({r['mejor_modo']})")
    L.append(f"\nCSV completo: {ruta_csv}")
    texto = "\n".join(L)
    with open(os.path.join(args.salida, "diag_avatar_quieto.txt"), "w", encoding="utf-8") as f:
        f.write(texto + "\n")
    print(texto)
    return 0


if __name__ == "__main__":
    sys.exit(main())
