#!/usr/bin/env python3
"""SOLO LEE: cuenta muestras de la base por estado, origen y dataset, y cuantas tienen landmarks de la norma vigente.
Uso (desde senas_core):  python tools\\diag_base.py"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sign_norm as sn  # noqa: E402
import moderar_senas as mod  # noqa: E402


def prefijo(uri):
    if not uri:
        return "(sin video_uri: propias/captura)"
    m = re.match(r"^([a-z]+:[^/]*/?)", uri)
    return m.group(1) if m else uri[:20]


def main():
    conn = mod.conectar()
    cur = conn.cursor()
    print("norma vigente:", sn.NORM_VERSION)
    cur.execute("SELECT count(*) FROM signs")
    print("senas en la base:", cur.fetchone()[0])
    cur.execute("SELECT ss.estado, ss.origen, ss.video_uri, "
                "EXISTS (SELECT 1 FROM sample_landmarks sl WHERE sl.sample_id = ss.id AND sl.norm_version = %s) "
                "FROM sign_samples ss", (sn.NORM_VERSION,))
    tabla = {}
    for estado, origen, uri, con_lm in cur.fetchall():
        k = (prefijo(uri), estado, origen, "con landmarks" if con_lm else "SIN landmarks de esta norma")
        tabla[k] = tabla.get(k, 0) + 1
    print(f"\n{'dataset':36} {'estado':10} {'origen':10} {'landmarks':30} n")
    for k in sorted(tabla):
        print(f"{k[0]:36} {k[1]:10} {k[2] or '':10} {k[3]:30} {tabla[k]}")
    cur.execute("SELECT count(*) FROM sign_samples ss JOIN sample_landmarks sl ON sl.sample_id = ss.id "
                "WHERE ss.estado = 'aprobada' AND sl.norm_version = %s", (sn.NORM_VERSION,))
    print("\naprobadas con landmarks de la norma vigente (lo que exporta plantillas.json):", cur.fetchone()[0])
    cur.execute("SELECT count(*) FROM sign_samples WHERE estado = 'aprobada'")
    print("aprobadas en total (con o sin landmarks):", cur.fetchone()[0])
    cur.execute("SELECT s.gloss, ss.estado, ss.video_uri FROM sign_samples ss JOIN signs s ON s.id = ss.sign_id "
                "WHERE ss.video_uri LIKE 'wikisigns:%' AND s.gloss IN ('ACABAR','ACAPULCO','AUTO','BARCO','CAJA')")
    print("\nejemplos que estaban en el plantillas.json anterior (ACABAR, ACAPULCO, AUTO, BARCO, CAJA):")
    for g, e, u in cur.fetchall():
        print(f"  {g:10} {e:10} {u}")
    conn.close()


if __name__ == "__main__":
    main()
