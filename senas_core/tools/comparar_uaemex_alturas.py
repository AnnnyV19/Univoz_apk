#!/usr/bin/env python3
"""Compara las ALTURAS de muneca de las tomas de UAEMex con las que ya estan aprobadas (otros origenes).

SOLO LEE la base: no cambia nada, no aprueba nada, no toca plantillas.json.

Por que: el reconocedor (dtw.py / dtw.dart) usa la ALTURA de la muneca (W_LOC = 1.5) y la regla del
proyecto es no normalizar ni mover esa altura. Las tomas en modo "solo mano" (cuando no se ven los
hombros) NO tienen altura real: importar_dataset_lsm.a_solo_mano pone un esqueleto neutro y la muneca
arranca siempre a la misma altura de pecho; solo cuenta el movimiento. Este script lo mide:

  - clasifica cada toma de UAEMex como 'cuerpo' o 'mano' (en modo mano los codos son constantes e iguales
    al esqueleto neutro);
  - saca la altura mediana de la muneca (en anchos de hombro, eje arriba+) de cada toma;
  - por glosa compara UAEMex 'cuerpo' y UAEMex 'mano' contra las muestras ya aprobadas de otros origenes.

Uso (desde la carpeta senas_core):
    python tools\\comparar_uaemex_alturas.py
Escribe datasets_lsm\\comparar_uaemex_alturas.csv
"""

import argparse
import csv
import os
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import sign_norm as sn  # noqa: E402

PREFIJO = "mendeley:6rj76z6y3n/"
OFF_Y_L = sn.OFF_LOC_L + 1
OFF_Y_R = sn.OFF_LOC_R + 1
# codos dentro del bloque de cuerpo: POSE_BODY_IDX = [hombro_i, hombro_d, codo_i, codo_d, ...]
DIMS_CODOS = list(range(6, 12))
UMBRAL_CONSTANTE = 0.01     # rango maximo de los codos para decir "es el esqueleto neutro"
REPOSO = -0.9               # muneca mas abajo de esto (anchos de hombro) = brazo colgando


def resumen(seq):
    """seq (t x 152) -> dict con modo ('cuerpo'/'mano'), alt (mediana de la altura de la muneca con
    mano presente, en anchos de hombro), x, y presencia (fraccion de cuadros con alguna mano)."""
    if not seq:
        return None
    rango_codos = max(max(fr[d] for fr in seq) - min(fr[d] for fr in seq) for d in DIMS_CODOS)
    modo = "mano" if rango_codos < UMBRAL_CONSTANTE else "cuerpo"
    ys, xs, con_mano = [], [], 0
    for fr in seq:
        hay = False
        for off_pres, off_loc in ((sn.OFF_PRES_L, sn.OFF_LOC_L), (sn.OFF_PRES_R, sn.OFF_LOC_R)):
            if fr[off_pres] > 0.5:
                hay = True
                xs.append(fr[off_loc])
                ys.append(fr[off_loc + 1])
        con_mano += 1 if hay else 0
    if not ys:
        return {"modo": modo, "alt": None, "pico": None, "reposo": None, "x": None, "pres": 0.0}
    ordenado = sorted(ys)
    pico = ordenado[min(len(ordenado) - 1, int(0.9 * len(ordenado)))]      # percentil 90: la fase de la sena
    reposo = sum(1 for y in ys if y < REPOSO) / len(ys)                      # muneca colgando a los lados
    return {"modo": modo, "alt": statistics.median(ys), "pico": pico, "reposo": reposo,
            "x": statistics.median(xs), "pres": con_mano / len(seq)}


def leer(conn, sql, params):
    cur = conn.cursor()
    cur.execute(sql, params)
    salida = []
    for gloss, uri, data, dim in cur.fetchall():
        r = resumen(sn.unpack_f16(bytes(data), dim=int(dim)))
        if r:
            r.update({"gloss": gloss, "uri": uri or ""})
            salida.append(r)
    return salida


def med(vs):
    vs = [v for v in vs if v is not None]
    return statistics.median(vs) if vs else None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--salida", default=None, help="CSV de salida (defecto: datasets_lsm\\comparar_uaemex_alturas.csv)")
    args = ap.parse_args()
    salida = args.salida or os.path.join(HERE, "..", "datasets_lsm", "comparar_uaemex_alturas.csv")

    import moderar_senas as mod
    conn = mod.conectar()
    try:
        uae = leer(conn,
                   """SELECT s.gloss, ss.video_uri, sl.data, sl.frame_dim
                      FROM sign_samples ss JOIN signs s ON s.id = ss.sign_id
                      JOIN sample_landmarks sl ON sl.sample_id = ss.id
                      WHERE ss.video_uri LIKE %s AND ss.estado <> 'rechazada' AND ss.origen = 'video'
                        AND sl.norm_version = %s""",
                   (PREFIJO + "w%", sn.NORM_VERSION))
        glosas = sorted({r["gloss"] for r in uae})
        otras = leer(conn,
                     """SELECT s.gloss, ss.video_uri, sl.data, sl.frame_dim
                        FROM sign_samples ss JOIN signs s ON s.id = ss.sign_id
                        JOIN sample_landmarks sl ON sl.sample_id = ss.id
                        WHERE ss.estado = 'aprobada' AND ss.origen <> 'espejo'
                          AND (ss.video_uri IS NULL OR ss.video_uri NOT LIKE %s)
                          AND s.gloss = ANY(%s) AND sl.norm_version = %s""",
                     (PREFIJO + "%", glosas, sn.NORM_VERSION))
    finally:
        conn.close()

    print(f"tomas UAEMex (no rechazadas): {len(uae)}   glosas: {len(glosas)}")
    print(f"muestras aprobadas de otros origenes en esas glosas: {len(otras)}")
    n_c = sum(1 for r in uae if r["modo"] == "cuerpo")
    n_m = sum(1 for r in uae if r["modo"] == "mano")
    print(f"UAEMex con cuerpo (altura real): {n_c}   solo mano (altura sintetica): {n_m}")
    alt_m = [r["alt"] for r in uae if r["modo"] == "mano" and r["alt"] is not None]
    alt_c = [r["alt"] for r in uae if r["modo"] == "cuerpo" and r["alt"] is not None]
    if alt_m:
        q = statistics.quantiles(alt_m, n=10) if len(alt_m) >= 10 else [min(alt_m), max(alt_m)]
        print(f"altura mediana de muneca, solo mano: {statistics.median(alt_m):+.2f} "
              f"(deciles extremos {q[0]:+.2f} .. {q[-1]:+.2f})  <- casi constante = sintetica")
    if alt_c:
        q = statistics.quantiles(alt_c, n=10) if len(alt_c) >= 10 else [min(alt_c), max(alt_c)]
        print(f"altura mediana de muneca, con cuerpo: {statistics.median(alt_c):+.2f} "
              f"(deciles extremos {q[0]:+.2f} .. {q[-1]:+.2f})")

    rc = [r["reposo"] for r in uae if r["modo"] == "cuerpo" and r["reposo"] is not None]
    pc = [r["pico"] for r in uae if r["modo"] == "cuerpo" and r["pico"] is not None]
    ro = [r["reposo"] for r in otras if r["modo"] == "cuerpo" and r["reposo"] is not None]
    po = [r["pico"] for r in otras if r["modo"] == "cuerpo" and r["pico"] is not None]
    if rc and ro:
        print(f"fraccion de cuadros con el brazo colgando (muneca < {REPOSO}): UAEMex con cuerpo {statistics.median(rc):.0%} "
              f"(mediana por toma)  vs  ya aprobado {statistics.median(ro):.0%}")
    if pc and po:
        print(f"altura PICO (percentil 90) de la muneca: UAEMex con cuerpo {statistics.median(pc):+.2f}  vs  ya aprobado "
              f"{statistics.median(po):+.2f}")

    por = {}
    for r in uae:
        por.setdefault(r["gloss"], {"c": [], "m": [], "pc": [], "rc": []})
        d = por[r["gloss"]]
        d["c" if r["modo"] == "cuerpo" else "m"].append(r["alt"])
        if r["modo"] == "cuerpo":
            d["pc"].append(r["pico"])
            d["rc"].append(r["reposo"])
    ex, ex_pico = {}, {}
    for r in otras:
        if r["alt"] is not None and r["modo"] == "cuerpo":
            ex.setdefault(r["gloss"], []).append(r["alt"])
            ex_pico.setdefault(r["gloss"], []).append(r["pico"])
    n_ex_mano = sum(1 for r in otras if r["modo"] == "mano")

    filas, dc, dm, dp = [], [], [], []
    for g in glosas:
        a_ex = med(ex.get(g, []))
        a_c, a_m = med(por[g]["c"]), med(por[g]["m"])
        d_c = (a_c - a_ex) if (a_c is not None and a_ex is not None) else None
        d_m = (a_m - a_ex) if (a_m is not None and a_ex is not None) else None
        p_c, p_ex = med(por[g]["pc"]), med(ex_pico.get(g, []))
        d_p = (p_c - p_ex) if (p_c is not None and p_ex is not None) else None
        if d_c is not None:
            dc.append(d_c)
        if d_m is not None:
            dm.append(d_m)
        if d_p is not None:
            dp.append(d_p)
        filas.append([g, len(ex.get(g, [])), a_ex, len(por[g]["c"]), a_c, d_c, len(por[g]["m"]), a_m, d_m,
                      p_ex, p_c, d_p, med(por[g]["rc"])])

    def f(v):
        return "" if v is None else f"{v:.3f}"

    os.makedirs(os.path.dirname(os.path.abspath(salida)), exist_ok=True)
    with open(salida, "w", newline="", encoding="utf-8-sig") as fh:
        w = csv.writer(fh)
        w.writerow(["gloss", "n_otros", "alt_otros", "n_uaemex_cuerpo", "alt_uaemex_cuerpo", "delta_cuerpo",
                    "n_uaemex_mano", "alt_uaemex_mano", "delta_mano", "pico_otros", "pico_uaemex_cuerpo",
                    "delta_pico", "reposo_uaemex_cuerpo"])
        for fila in filas:
            w.writerow([fila[0], fila[1], f(fila[2]), fila[3], f(fila[4]), f(fila[5]), fila[6], f(fila[7]),
                        f(fila[8]), f(fila[9]), f(fila[10]), f(fila[11]), f(fila[12])])
    print(f"\nglosas de UAEMex que ya tenian muestras aprobadas de otro origen (con cuerpo): {len(dc) or 0} "
          f"(de las de modo mano ya aprobadas se ignoran {n_ex_mano})")
    if dc:
        mal = sum(1 for v in dc if abs(v) > 0.3)
        print(f"  UAEMex CON CUERPO vs lo ya aprobado: diferencia de altura mediana {statistics.median(dc):+.2f}, "
              f"|dif| mediana {statistics.median([abs(v) for v in dc]):.2f}; "
              f"{mal} de {len(dc)} glosas difieren mas de 0.3 anchos de hombro")
    if dp:
        mal = sum(1 for v in dp if abs(v) > 0.3)
        print(f"  ALTURA PICO, UAEMex con cuerpo vs lo ya aprobado: diferencia mediana {statistics.median(dp):+.2f}, "
              f"|dif| mediana {statistics.median([abs(v) for v in dp]):.2f}; "
              f"{mal} de {len(dp)} glosas difieren mas de 0.3")
    if dm:
        mal = sum(1 for v in dm if abs(v) > 0.3)
        print(f"  UAEMex SOLO MANO vs lo ya aprobado: diferencia de altura mediana {statistics.median(dm):+.2f}, "
              f"|dif| mediana {statistics.median([abs(v) for v in dm]):.2f}; "
              f"{mal} de {len(dm)} glosas difieren mas de 0.3")
    peores = sorted([x for x in filas if x[5] is not None], key=lambda x: -abs(x[5]))[:12]
    if peores:
        print("\nLas 12 glosas con mas diferencia (UAEMex con cuerpo vs ya aprobado):")
        for x in peores:
            print(f"  {x[0]:<24} otros n={x[1]:<3} alt {f(x[2]):>7}   UAEMex n={x[3]:<3} alt {f(x[4]):>7}   dif {x[5]:+.2f}")
    print(f"\nCSV: {os.path.abspath(salida)}")


if __name__ == "__main__":
    main()
