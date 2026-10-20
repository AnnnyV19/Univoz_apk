#!/usr/bin/env python3
"""Deshace la APROBACION MASIVA que quedo en la base (una sola transaccion que paso a 'aprobada' todas las
pendientes de ITESO, Wikisigns y las letras) para que la base vuelva a coincidir con tu plantillas.json.

Como la reconoce: Postgres guarda en cada fila (xmin) la transaccion que la escribio por ultima vez. Todas
las filas aprobadas por esa transaccion comparten el mismo xmin (el diagnostico diag_aprobadas lo mostro:
4176). Las aprobaciones de verdad (etapa 5, etapa 6, tus tandas del 9 de octubre, el SEP, tus capturas)
tienen otro xmin y NO se tocan.

Por defecto SOLO MIRA (--seco implicito): dice cuantas filas son y de que datasets. Para cambiar la base:
    python tools\\revertir_aprobacion_masiva.py --xmin 4176 --aplicar
Antes de cambiar guarda datasets_lsm\\reaprobar_masiva_<fecha>.sql (los id, para volver a aprobarlas con un
clic si quisieras) y solo confirma si no queda ninguna fila inesperada. NO exporta plantillas.json.
Uso:  python tools\\revertir_aprobacion_masiva.py [--xmin N] [--aplicar]"""
import argparse
import datetime
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sign_norm as sn  # noqa: E402
import moderar_senas as mod  # noqa: E402

PERMITIDOS = ("mendeley:g45jkzys4f/", "wikisigns:lsm/", "zenodo:10067509/", "zenodo:14689869/")


def prefijo(uri):
    if not uri:
        return "(sin video_uri)"
    m = re.match(r"^([a-z]+:[^/]*/?)", uri)
    return m.group(1) if m else uri[:20]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--xmin", type=int, default=4176, help="transaccion de la aprobacion masiva (diag_aprobadas)")
    ap.add_argument("--aplicar", action="store_true", help="de verdad vuelve esas muestras a 'pendiente'")
    args = ap.parse_args()

    conn = mod.conectar()
    cur = conn.cursor()
    cur.execute("SELECT ss.id, ss.video_uri FROM sign_samples ss "
                "WHERE ss.estado = 'aprobada' AND ss.xmin::text::bigint = %s", (args.xmin,))
    filas = cur.fetchall()
    por = {}
    for _id, uri in filas:
        por[prefijo(uri)] = por.get(prefijo(uri), 0) + 1
    print(f"muestras 'aprobada' escritas por la transaccion {args.xmin}: {len(filas)}")
    for k in sorted(por):
        print(f"   {k:28} {por[k]:>6}" + ("" if k in PERMITIDOS else "   <-- INESPERADO"))
    cur.execute("SELECT count(*) FROM sign_samples ss JOIN sample_landmarks sl ON sl.sample_id = ss.id "
                "WHERE ss.estado = 'aprobada' AND sl.norm_version = %s", (sn.NORM_VERSION,))
    hoy = cur.fetchone()[0]
    cur.execute("SELECT count(*) FROM sign_samples ss JOIN sample_landmarks sl ON sl.sample_id = ss.id "
                "WHERE ss.estado = 'aprobada' AND sl.norm_version = %s AND ss.xmin::text::bigint <> %s",
                (sn.NORM_VERSION, args.xmin))
    despues = cur.fetchone()[0]
    print(f"\naprobadas con landmarks vigentes: hoy {hoy}  ->  despues de revertir {despues}")
    print("(tu plantillas.json se exporto con ~1,268 muestras aprobadas el 10 de octubre a las 18:00)")

    inesperados = [k for k in por if k not in PERMITIDOS]
    if not filas:
        print("\nno hay nada que revertir con ese xmin.")
        conn.close()
        return 0
    if inesperados:
        print("\nHay filas de datasets que no deberian estar en esa transaccion: NO se cambia nada.")
        conn.close()
        return 2
    if not args.aplicar:
        print("\n(solo mire: no se cambio nada. Para aplicar:  python tools\\revertir_aprobacion_masiva.py "
              f"--xmin {args.xmin} --aplicar)")
        conn.close()
        return 0

    estampa = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    ruta = os.path.join(HERE, "..", "datasets_lsm", f"reaprobar_masiva_{estampa}.sql")
    ids = [str(i) for i, _ in filas]
    with open(ruta, "w", encoding="utf-8") as f:
        f.write(f"-- Vuelve a 'aprobada' las {len(ids)} muestras que revertir_aprobacion_masiva.py paso a 'pendiente' ({estampa}).\n")
        f.write("UPDATE sign_samples SET estado = 'aprobada'\nWHERE estado = 'pendiente' AND id IN (\n  ")
        f.write(",\n  ".join(f"'{i}'" for i in ids))
        f.write("\n);\n")
    print("guardado:", os.path.abspath(ruta))
    cur.execute("UPDATE sign_samples SET estado = 'pendiente' WHERE id = ANY(%s::uuid[]) AND estado = 'aprobada'", (ids,))
    n = cur.rowcount
    cur.execute("SELECT count(*) FROM sign_samples ss JOIN sample_landmarks sl ON sl.sample_id = ss.id "
                "WHERE ss.estado = 'aprobada' AND sl.norm_version = %s", (sn.NORM_VERSION,))
    nuevo = cur.fetchone()[0]
    if n != len(ids) or nuevo != despues:
        conn.rollback()
        print(f"algo no cuadra (cambiadas {n} de {len(ids)}, aprobadas {nuevo} en vez de {despues}): SE DESHIZO, no se cambio nada.")
        conn.close()
        return 3
    conn.commit()
    print(f"\nListo: {n} muestras volvieron a 'pendiente'. Aprobadas con landmarks vigentes: {nuevo}.")
    print("plantillas.json NO se toco (ya coincidia con este estado). Para volver a aprobarlas: corre el .sql guardado.")
    conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
