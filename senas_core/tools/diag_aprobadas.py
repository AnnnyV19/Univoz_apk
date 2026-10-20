#!/usr/bin/env python3
"""SOLO LEE. Averigua CUANDO y COMO quedaron 'aprobadas' tantas muestras en la base:
cuenta por dataset/estado, el orden de escritura (xmin de Postgres), fechas de creacion y contadores
de la tabla. No cambia nada.
Uso (desde senas_core):  python tools\\diag_aprobadas.py"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sign_norm as sn  # noqa: E402
import moderar_senas as mod  # noqa: E402


def prefijo(uri):
    if not uri:
        return "(sin video_uri)"
    m = re.match(r"^([a-z]+:[^/]*/?)", uri)
    return m.group(1) if m else uri[:20]


def main():
    conn = mod.conectar()
    cur = conn.cursor()
    cur.execute("SHOW track_commit_timestamp")
    tct = cur.fetchone()[0]
    print("track_commit_timestamp:", tct)
    cur.execute("SELECT now(), version()")
    ahora, ver = cur.fetchone()
    print("hora del servidor:", ahora)
    print(ver[:80])
    cur.execute("SELECT n_tup_ins, n_tup_upd, n_tup_del, n_live_tup, last_autoanalyze, last_analyze "
                "FROM pg_stat_user_tables WHERE relname = 'sign_samples'")
    print("pg_stat sign_samples (ins, upd, del, vivas, ult.autoanalyze, ult.analyze):", cur.fetchone())

    cols = "ss.estado, ss.video_uri, ss.creado_en, ss.revisada_por, ss.xmin::text::bigint"
    if tct == "on":
        cols += ", pg_xact_commit_timestamp(ss.xmin)"
    else:
        cols += ", NULL"
    cur.execute(f"SELECT {cols} FROM sign_samples ss")
    g = {}
    for estado, uri, creado, rev, xmin, ts in cur.fetchall():
        k = (prefijo(uri), estado)
        d = g.setdefault(k, {"n": 0, "xmin": [], "creado": [], "rev": 0, "ts": []})
        d["n"] += 1
        d["xmin"].append(xmin)
        d["creado"].append(creado)
        if rev:
            d["rev"] += 1
        if ts:
            d["ts"].append(ts)
    print(f"\n{'dataset':28} {'estado':10} {'n':>6} {'xmin min':>10} {'xmin max':>10} {'creado min':20} {'creado max':20} rev  escrito(min..max)")
    for k in sorted(g):
        d = g[k]
        ts = f"{min(d['ts']):%m-%d %H:%M}..{max(d['ts']):%m-%d %H:%M}" if d["ts"] else ""
        print(f"{k[0]:28} {k[1]:10} {d['n']:>6} {min(d['xmin']):>10} {max(d['xmin']):>10} "
              f"{min(d['creado']):%m-%d %H:%M:%S}  {max(d['creado']):%m-%d %H:%M:%S}  {d['rev']:>4} {ts}")
    cur.execute("SELECT txid_current()")
    print("\ntxid actual (para comparar con xmin):", cur.fetchone()[0])

    # ITESO: cuantas aprobadas por sena
    cur.execute("SELECT s.gloss, count(*) FROM sign_samples ss JOIN signs s ON s.id = ss.sign_id "
                "WHERE ss.video_uri LIKE 'mendeley:g45jkzys4f/%' AND ss.estado = 'aprobada' GROUP BY 1")
    por = [n for _, n in cur.fetchall()]
    if por:
        print(f"\nITESO aprobadas: {sum(por)} en {len(por)} senas; por sena min {min(por)}, max {max(por)}, "
              f"con mas de 10: {sum(1 for n in por if n > 10)}")
    # total aprobadas por sena (todas las fuentes)
    cur.execute("SELECT s.gloss, count(*) FROM sign_samples ss JOIN signs s ON s.id = ss.sign_id "
                "JOIN sample_landmarks sl ON sl.sample_id = ss.id AND sl.norm_version = %s "
                "WHERE ss.estado = 'aprobada' GROUP BY 1", (sn.NORM_VERSION,))
    tot = [n for _, n in cur.fetchall()]
    print(f"\nAprobadas con landmarks vigentes: {sum(tot)} en {len(tot)} senas; por sena min {min(tot)}, "
          f"mediana {sorted(tot)[len(tot)//2]}, max {max(tot)}; senas con mas de 10: {sum(1 for n in tot if n > 10)}")
    conn.close()


if __name__ == "__main__":
    main()
